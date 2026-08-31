@preconcurrency import AVFoundation
import Foundation

/// Owns the AVCaptureSession and the front camera only. CameraEngine knows
/// nothing about scripts, teleprompters, or recording state — it publishes a
/// `CameraConfiguration` snapshot and exposes the session/output that
/// RecordingEngine attaches to. Keeping it dumb like this is what lets us
/// swap camera stacks later without touching anything upstream.
@MainActor
@Observable
final class CameraEngine: NSObject {
    private(set) var configuration: CameraConfiguration = .unknown
    private(set) var isAuthorized = false
    private(set) var isSessionRunning = false
    private(set) var lastError: String?

    let session = AVCaptureSession()
    let movieOutput = AVCaptureMovieFileOutput()

    private let sessionQueue = DispatchQueue(label: "one.pollux.camera.session")
    private let capabilityService = DeviceCapabilityService()
    private var videoDevice: AVCaptureDevice?
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?

    func requestAuthorizationAndConfigure() async {
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
        }
        isAuthorized = granted
        guard granted else {
            lastError = "Camera access denied. Enable it in Settings to record."
            return
        }
        await configureSession()
    }

    private func configureSession() async {
        guard !capabilityService.isSimulator() else {
            lastError = "Camera preview is unavailable in Simulator. Run on a device to see it live."
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            lastError = "No front camera found on this device."
            return
        }
        videoDevice = device

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                // AudioSessionController is the single owner of category/mode;
                // left on, AVCaptureSession would reconfigure the session
                // behind SpeechRecognitionService's back.
                self.session.automaticallyConfiguresApplicationAudioSession = false
                self.session.beginConfiguration()
                self.session.sessionPreset = .high

                do {
                    let input = try AVCaptureDeviceInput(device: device)
                    if self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.videoInput = input
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
                            self.audioInput = audioInput
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
                continuation.resume()
            }
        }

        isSessionRunning = session.isRunning
        refreshConfiguration()
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
        isSessionRunning = false
    }

    // MARK: - Controls (current value = control entry point, per HUD spec)

    func setZoomFactor(_ factor: Double) {
        guard let device = videoDevice else { return }
        let clamped = min(max(factor, configuration.minZoomFactor), configuration.maxZoomFactor)
        setDevice(device) { $0.videoZoomFactor = clamped }
        refreshConfiguration()
    }

    func setExposureBias(_ ev: Double) {
        guard let device = videoDevice else { return }
        let clamped = Float(min(max(ev, configuration.minExposureBiasEV), configuration.maxExposureBiasEV))
        setDevice(device) { $0.setExposureTargetBias(clamped, completionHandler: nil) }
        refreshConfiguration()
    }

    func focus(at devicePoint: CGPoint) {
        guard let device = videoDevice, device.isFocusPointOfInterestSupported else { return }
        setDevice(device) {
            $0.focusPointOfInterest = devicePoint
            $0.focusMode = .autoFocus
            if $0.isExposurePointOfInterestSupported {
                $0.exposurePointOfInterest = devicePoint
                $0.exposureMode = .autoExpose
            }
        }
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
        let capabilities = capabilityService.frontCameraCapabilities(for: device)
        configuration = CameraConfiguration(
            lensPosition: lensPosition(for: device),
            focalLengthMillimeters: Double(device.activeFormat.videoFieldOfView > 0 ? 24 : 24),
            availableLensPositions: capabilities.availableLensPositions,
            zoomFactor: Double(device.videoZoomFactor),
            minZoomFactor: 1,
            maxZoomFactor: capabilities.maxZoomFactor,
            exposureBiasEV: Double(device.exposureTargetBias),
            minExposureBiasEV: capabilities.minExposureBiasEV,
            maxExposureBiasEV: capabilities.maxExposureBiasEV,
            focusMode: focusMode(for: device),
            isAutoExposureLocked: device.exposureMode == .locked,
            apertureF: capabilities.apertureF,
            supportsDepth: capabilities.supportsDepth,
            resolution: .hd1080,
            frameRate: .fps30,
            availableResolutions: capabilities.availableResolutions,
            availableFrameRates: capabilities.availableFrameRates
        )
    }

    private func lensPosition(for device: AVCaptureDevice) -> CameraLensPosition {
        switch device.deviceType {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInTelephotoCamera: return .telephoto
        default: return .wide
        }
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
