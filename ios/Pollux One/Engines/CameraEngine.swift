@preconcurrency import AVFoundation
import Foundation

/// Owns the AVCaptureSession and whichever camera — front or back — is
/// currently selected. CameraEngine knows nothing about scripts,
/// teleprompters, or recording state: it publishes a `CameraConfiguration`
/// snapshot and exposes the session/output that RecordingEngine attaches to.
/// Keeping it dumb like this is what lets us swap camera stacks later without
/// touching anything upstream.
@MainActor
@Observable
final class CameraEngine: NSObject {
    private(set) var configuration: CameraConfiguration = .unknown
    private(set) var isAuthorized = false
    private(set) var isSessionRunning = false
    private(set) var lastError: String?
    /// True while the capture input is being swapped. Callers use it to keep a
    /// double-tap on the flip control from queueing two reconfigurations.
    private(set) var isSwitchingCamera = false

    // Configured only from `sessionQueue` (AVFoundation's rule: one serial
    // queue owns session configuration), but read from the main actor by the
    // preview layer and RecordingEngine. `nonisolated(unsafe)` states that
    // invariant instead of leaving 20-odd actor-isolation warnings that would
    // become errors under full Swift 6 checking.
    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) let movieOutput = AVCaptureMovieFileOutput()

    private let sessionQueue = DispatchQueue(label: "one.pollux.camera.session")
    private let capabilityService = DeviceCapabilityService()
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    /// Which sides this hardware has, resolved once at configure time — the
    /// discovery session behind it is too costly to run on every HUD refresh.
    private var availableFacings: [CameraFacing] = [.front]

    private var isRunningObservation: NSKeyValueObservation?
    /// Held only so deinit can unregister them; NotificationCenter's
    /// block-based observers are not removed automatically.
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func requestAuthorizationAndConfigure() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
        }
        isAuthorized = granted
        guard granted else {
            lastError = "Camera access denied. Enable it in Settings to record."
            return
        }
        // Front by default: eye contact with the lens is the product.
        await configureSession(facing: .front)
    }

    private func configureSession(facing: CameraFacing) async {
        guard !capabilityService.isSimulator() else {
            lastError = "Camera preview is unavailable in Simulator. Run on a device to see it live."
            return
        }
        availableFacings = capabilityService.availableFacings()
        observeSessionState()
        guard let device = capabilityService.captureDevice(for: facing) else {
            lastError = "No \(facing == .front ? "front" : "back") camera found on this device."
            return
        }
        videoDevice = device

        // The capture session carries an audio input, and
        // `automaticallyConfiguresApplicationAudioSession` is off (below) so
        // AVFoundation won't set the audio session up for us. Left in the
        // default category the app is not permitted to record, and the capture
        // session starts only to be interrupted immediately — which looks like
        // a black rectangle under a live HUD, with nothing saying why. So the
        // audio session is configured here, when the camera comes up, not when
        // recording starts.
        do {
            try AudioSessionController.activateForRecording()
        } catch {
            lastError = "Audio unavailable, recording would be silent: \(error.localizedDescription)"
        }

        let input: AVCaptureDeviceInput? = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                // AudioSessionController is the single owner of category/mode;
                // left on, AVCaptureSession would reconfigure the session
                // behind SpeechRecognitionService's back.
                self.session.automaticallyConfiguresApplicationAudioSession = false
                self.session.beginConfiguration()
                self.session.sessionPreset = .high

                var videoInput: AVCaptureDeviceInput?
                do {
                    let candidate = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(candidate) {
                        self.session.addInput(candidate)
                        videoInput = candidate
                    }
                } catch {
                    Task { @MainActor in self.lastError = "Failed to open camera: \(error.localizedDescription)" }
                }

                // Without an audio input the take records silently — a
                // talking-head video with no voice on it.
                if let microphone = AVCaptureDevice.default(for: .audio) {
                    do {
                        let audioInput = try AVCaptureDeviceInput(device: microphone)
                        if self.session.canAddInput(audioInput) {
                            self.session.addInput(audioInput)
                            Task { @MainActor in self.audioInput = audioInput }
                        }
                    } catch {
                        Task { @MainActor in
                            self.lastError = "Recording will have no sound: \(error.localizedDescription)"
                        }
                    }
                }

                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }

                self.session.commitConfiguration()
                self.session.startRunning()
                continuation.resume(returning: videoInput)
            }
        }

        videoInput = input
        if input == nil {
            lastError = lastError ?? "The camera could not be attached to the capture session."
        }
        // isSessionRunning is maintained by the KVO observation, not read once
        // here: a session that later gets interrupted (a call, another app
        // taking the camera, thermal pressure) has to take the preview down
        // and put it back, which a snapshot could never do.
        startAtWideLens()
        refreshConfiguration()
    }

    // MARK: - Session state

    /// AVCaptureSession fails asynchronously and out of band. Without these,
    /// every failure mode — interrupted, errored, never actually started —
    /// looks identical on screen: a black rectangle under a live HUD.
    private func observeSessionState() {
        guard isRunningObservation == nil else { return }

        isRunningObservation = session.observe(\.isRunning, options: [.initial, .new]) { captureSession, _ in
            let running = captureSession.isRunning
            Task { @MainActor [weak self] in self?.isSessionRunning = running }
        }

        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { notification in
                let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription
                    ?? "unknown capture error"
                Task { @MainActor [weak self] in self?.handleRuntimeError(message) }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { notification in
                let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                Task { @MainActor [weak self] in self?.handleInterruption(reason) }
            }
        )
        notificationObservers.append(
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { _ in
                Task { @MainActor [weak self] in self?.lastError = nil }
            }
        )
    }

    private func handleRuntimeError(_ message: String) {
        lastError = "Camera stopped: \(message)"
        // A runtime error leaves the session stopped. One restart attempt is
        // what Apple's own sample does, and it recovers the transient cases
        // (a media-services reset) without the user backing out of the screen.
        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func handleInterruption(_ reasonValue: Int?) {
        switch reasonValue.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)) {
        case .videoDeviceNotAvailableInBackground:
            lastError = "Camera paused while Pollux One is in the background."
        case .videoDeviceInUseByAnotherClient:
            lastError = "Another app is using the camera."
        case .audioDeviceInUseByAnotherClient:
            lastError = "Another app is using the microphone."
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            lastError = "The camera isn't available while sharing the screen with another app."
        case .videoDeviceNotAvailableDueToSystemPressure:
            lastError = "The camera paused to cool down."
        default:
            lastError = "The camera was interrupted."
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    // MARK: - Front / back

    /// Swaps the capture input to the other side. The session keeps running
    /// through the reconfiguration, so the preview cuts rather than blanking.
    ///
    /// Callers are responsible for not calling this mid-take: removing the
    /// video input while `movieOutput` is recording ends the file early.
    func flipCamera() async {
        guard !isSwitchingCamera else { return }
        let target = configuration.facing.opposite
        guard let device = capabilityService.captureDevice(for: target) else {
            lastError = "This device has no \(target == .front ? "front" : "back") camera."
            return
        }

        isSwitchingCamera = true
        defer { isSwitchingCamera = false }

        let previousInput = videoInput
        let swappedInput: AVCaptureDeviceInput? = await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(returning: nil); return }
                self.session.beginConfiguration()
                if let previousInput { self.session.removeInput(previousInput) }

                var swapped: AVCaptureDeviceInput?
                do {
                    let candidate = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(candidate) {
                        self.session.addInput(candidate)
                        swapped = candidate
                    }
                } catch {
                    Task { @MainActor in self.lastError = "Failed to switch camera: \(error.localizedDescription)" }
                }

                // Never leave the session without a video input: a failed swap
                // has to put the old camera back or the preview goes black
                // with no way out.
                if swapped == nil, let previousInput, self.session.canAddInput(previousInput) {
                    self.session.addInput(previousInput)
                }

                self.session.commitConfiguration()
                continuation.resume(returning: swapped)
            }
        }

        if let swappedInput {
            videoInput = swappedInput
            videoDevice = device
            lastError = nil
        }
        startAtWideLens()
        refreshConfiguration()
    }

    /// A virtual multi-camera device wakes up at zoom 1.0, which on the back
    /// camera of a Pro is the *ultra-wide* — so without this, flipping lands
    /// on 0.5× and reads as a bug. Start where the system Camera starts.
    private func startAtWideLens() {
        guard let device = videoDevice else { return }
        let wideBase = capabilityService.capabilities(for: device).wideBaseZoomFactor
        guard wideBase > 1 else { return }
        setDevice(device) { $0.videoZoomFactor = CGFloat(wideBase) }
    }

    // MARK: - Controls (current value = control entry point, per HUD spec)

    /// Selecting a lens *is* a zoom change: on a virtual device the hand-off
    /// factor is the lens, so setting it hands capture to that physical
    /// camera instead of cropping into the current one.
    func setLens(_ lens: CameraLensOption) {
        setZoomFactor(lens.deviceZoomFactor)
    }

    func setZoomFactor(_ factor: Double) {
        guard let device = videoDevice else { return }
        let clamped = min(max(factor, configuration.minZoomFactor), configuration.maxZoomFactor)
        setDevice(device) { $0.videoZoomFactor = clamped }
        refreshConfiguration()
    }

    func setExposureBias(_ ev: Double) {
        guard let device = videoDevice else { return }
        let clamped = Float(min(max(ev, configuration.minExposureBiasEV), configuration.maxExposureBiasEV))
        setDevice(device) { [weak self] device in
            // Bias is an offset from the metered target, so a locked exposure
            // has nothing to offset and the slider would move while the image
            // didn't. Hand metering back before applying it.
            if device.exposureMode == .locked, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.setExposureTargetBias(clamped) { _ in
                Task { @MainActor in self?.refreshConfiguration() }
            }
        }
        // The device *ramps* to the new bias, so reading it straight back
        // reports the value we just replaced. ExposureSliderView is driven
        // entirely by this number, so that made the knob snap back under the
        // user's finger for the length of a drag. Publish what was asked for;
        // the completion handler corrects it once the ramp lands.
        configuration.exposureBiasEV = Double(clamped)
    }

    /// Point the camera at a spot: focus there and meter there.
    ///
    /// Both halves use the *continuous* modes on purpose. `.autoFocus` and
    /// `.autoExpose` are one-shots that leave the device `.locked` when they
    /// finish, and a locked exposure ignores `setExposureTargetBias` — so the
    /// EV control went dead the moment you tapped the frame. That breaks the
    /// ordinary way a video shot gets set up: tap the brightest or darkest
    /// part of the frame, then ride EV against it. Continuous keeps metering
    /// at the chosen point with bias applied on top, so the two coexist.
    ///
    /// The two halves are also guarded separately, because they're separate
    /// capabilities: a fixed-focus front camera (pre-iPhone-14) can still be
    /// told where to meter, and the old single guard threw that away with it.
    func focusAndMeter(at devicePoint: CGPoint) {
        guard let device = videoDevice else { return }
        setDevice(device) {
            // An explicit FOCUS · LOCK is the user's decision and a tap
            // shouldn't quietly undo it — but metering still moves, which is
            // the point of tapping in the first place.
            if $0.focusMode != .locked,
               $0.isFocusPointOfInterestSupported,
               $0.isFocusModeSupported(.continuousAutoFocus) {
                $0.focusPointOfInterest = devicePoint
                $0.focusMode = .continuousAutoFocus
            }
            if $0.isExposurePointOfInterestSupported,
               $0.isExposureModeSupported(.continuousAutoExposure) {
                $0.exposurePointOfInterest = devicePoint
                $0.exposureMode = .continuousAutoExposure
            }
        }
        refreshConfiguration()
    }

    /// The FOCUS column's two states are its control, so this is what tapping
    /// the value does. Focus only — exposure has its own column, and locking
    /// both from one tap would freeze a reading the user didn't ask to freeze.
    func setFocusLocked(_ locked: Bool) {
        guard let device = videoDevice else { return }
        let mode: AVCaptureDevice.FocusMode = locked ? .locked : .continuousAutoFocus
        guard device.isFocusModeSupported(mode) else { return }
        setDevice(device) { $0.focusMode = mode }
        refreshConfiguration()
    }

    func lockAutoExposureAndFocus() {
        guard let device = videoDevice else { return }
        setDevice(device) {
            if $0.isFocusModeSupported(.locked) { $0.focusMode = .locked }
            if $0.isExposureModeSupported(.locked) { $0.exposureMode = .locked }
        }
        refreshConfiguration()
    }

    func unlockAutoExposureAndFocus() {
        guard let device = videoDevice else { return }
        setDevice(device) {
            if $0.isFocusModeSupported(.continuousAutoFocus) { $0.focusMode = .continuousAutoFocus }
            if $0.isExposureModeSupported(.continuousAutoExposure) { $0.exposureMode = .continuousAutoExposure }
        }
        refreshConfiguration()
    }

    func setFormat(resolution: RecordingResolution, frameRate: RecordingFrameRate) {
        guard let device = videoDevice else { return }
        let target = device.formats.first { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let matchesResolution: Bool
            switch resolution {
            case .hd1080: matchesResolution = dims.height == 1080
            case .uhd4K: matchesResolution = dims.height == 2160
            }
            let supportsFrameRate = format.videoSupportedFrameRateRanges.contains {
                $0.maxFrameRate >= Double(frameRate.rawValue)
            }
            return matchesResolution && supportsFrameRate
        }
        guard let format = target else { return }
        setDevice(device) {
            $0.activeFormat = format
            $0.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
            $0.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate.rawValue))
        }
        refreshConfiguration()
    }

    private func setDevice(_ device: AVCaptureDevice, _ mutate: (AVCaptureDevice) -> Void) {
        do {
            try device.lockForConfiguration()
            mutate(device)
            device.unlockForConfiguration()
        } catch {
            lastError = "Camera control failed: \(error.localizedDescription)"
        }
    }

    private func refreshConfiguration() {
        guard let device = videoDevice else { return }
        let capabilities = capabilityService.capabilities(for: device)
        configuration = CameraConfiguration(
            facing: device.position == .front ? .front : .back,
            availableFacings: availableFacings,
            lensPosition: capabilityService.activeLensPosition(for: device),
            focalLengthMillimeters: capabilityService.equivalentFocalLengthMillimeters(for: device),
            availableLenses: capabilities.availableLenses,
            zoomFactor: Double(device.videoZoomFactor),
            minZoomFactor: capabilities.minZoomFactor,
            maxZoomFactor: capabilities.maxZoomFactor,
            wideBaseZoomFactor: capabilities.wideBaseZoomFactor,
            exposureBiasEV: Double(device.exposureTargetBias),
            minExposureBiasEV: capabilities.minExposureBiasEV,
            maxExposureBiasEV: capabilities.maxExposureBiasEV,
            focusMode: focusMode(for: device),
            isAutoExposureLocked: device.exposureMode == .locked,
            supportsFocusControl: capabilities.supportsFocusControl,
            apertureF: capabilities.apertureF,
            supportsDepth: capabilities.supportsDepth,
            // Read back from the device, not from what setFormat was asked
            // for: flipping to a camera that can't do 4K60 has to show what
            // it's really shooting.
            resolution: capabilityService.activeResolution(for: device),
            frameRate: capabilityService.activeFrameRate(for: device),
            availableResolutions: capabilities.availableResolutions,
            availableFrameRates: capabilities.availableFrameRates
        )
    }

    private func focusMode(for device: AVCaptureDevice) -> FocusMode {
        switch device.focusMode {
        case .locked: return .locked
        case .autoFocus: return .manual
        case .continuousAutoFocus: return .auto
        @unknown default: return .auto
        }
    }
}
