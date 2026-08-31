import AVFoundation
import Foundation

/// The single source of truth for "does this device/mode actually support X".
/// Every HUD control (Feature 3) asks this before rendering, so we never show
/// a parameter the hardware can't back up — and, since the front and back
/// cameras answer differently, so the HUD changes when you flip.
final class DeviceCapabilityService {
    struct CameraCapabilities {
        let availableLenses: [CameraLensOption]
        let wideBaseZoomFactor: Double
        let minZoomFactor: Double
        let maxZoomFactor: Double
        let minExposureBiasEV: Double
        let maxExposureBiasEV: Double
        let supportsDepth: Bool
        let supportsFocusControl: Bool
        let apertureF: Double?
        let availableResolutions: [RecordingResolution]
        let availableFrameRates: [RecordingFrameRate]
    }

    // MARK: - Device selection

    /// Capture devices worth opening for each side, best first. The virtual
    /// multi-camera devices lead because they're what makes the `.5 · 1× · 5`
    /// pill hand capture to real optics instead of cropping pixels.
    func preferredDeviceTypes(for facing: CameraFacing) -> [AVCaptureDevice.DeviceType] {
        switch facing {
        case .front:
            return [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        case .back:
            return [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        }
    }

    func captureDevice(for facing: CameraFacing) -> AVCaptureDevice? {
        let types = preferredDeviceTypes(for: facing)
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: facing == .front ? .front : .back
        ).devices
        // DiscoverySession's ordering isn't contractual, so walk our own
        // preference order — a Pro must open the triple camera, not the bare
        // wide one that also matches.
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// Sides this hardware can actually shoot from. Drives whether the flip
    /// control appears at all.
    func availableFacings() -> [CameraFacing] {
        CameraFacing.allCases.filter { captureDevice(for: $0) != nil }
    }

    // MARK: - Capabilities

    func capabilities(for device: AVCaptureDevice) -> CameraCapabilities {
        let (lenses, wideBase) = lensOptions(for: device)

        let maxFrameRate = device.formats
            .flatMap(\.videoSupportedFrameRateRanges)
            .map(\.maxFrameRate)
            .max() ?? 30
        var frameRates: [RecordingFrameRate] = [.fps24, .fps30]
        if maxFrameRate >= 60 { frameRates.append(.fps60) }

        var resolutions: [RecordingResolution] = [.hd1080]
        if device.formats.contains(where: { videoHeight(of: $0) >= 2160 }) { resolutions.append(.uhd4K) }

        return CameraCapabilities(
            availableLenses: lenses,
            wideBaseZoomFactor: wideBase,
            minZoomFactor: Double(device.minAvailableVideoZoomFactor),
            // Cap at 8× *as displayed*, so the ceiling means the same thing on
            // a camera whose zoom scale starts at the ultra-wide.
            maxZoomFactor: min(Double(device.maxAvailableVideoZoomFactor), wideBase * 8),
            minExposureBiasEV: Double(device.minExposureTargetBias),
            maxExposureBiasEV: Double(device.maxExposureTargetBias),
            // Read off the active format instead of guessed from the device
            // type: TrueDepth, LiDAR and the dual cameras all answer here.
            supportsDepth: !device.activeFormat.supportedDepthDataFormats.isEmpty,
            // Asked, not assumed: iPhone front cameras were fixed-focus until
            // the 14 and answer false, while the 15 Pro's front camera answers
            // true — and even supports locking to a custom lens position,
            // which its triple back camera does not.
            supportsFocusControl: device.isFocusPointOfInterestSupported || device.isFocusModeSupported(.locked),
            apertureF: apertureF(for: device),
            availableResolutions: resolutions,
            availableFrameRates: frameRates
        )
    }

    /// The lenses a camera can switch between, with the device zoom factor
    /// that selects each one. This method's only job is to read the hardware;
    /// the arithmetic lives in `CameraLensOption.options` so it can be
    /// verified offline (see ios/EngineHarness/CameraScenarios.swift).
    private func lensOptions(for device: AVCaptureDevice) -> (lenses: [CameraLensOption], wideBase: Double) {
        let derived = CameraLensOption.options(
            forConstituentLenses: device.constituentDevices.map { lensPosition(for: $0) },
            switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        )
        guard let derived else {
            // Not a virtual device (the front camera, or a single-lens back
            // one): one lens, and the pill won't render for it at all.
            return (
                [CameraLensOption(position: lensPosition(for: device), displayZoom: 1, deviceZoomFactor: 1)],
                1.0
            )
        }
        return (derived.options, derived.wideBaseZoomFactor)
    }

    func lensPosition(for device: AVCaptureDevice) -> CameraLensPosition {
        switch device.deviceType {
        case .builtInUltraWideCamera: return .ultraWide
        case .builtInTelephotoCamera: return .telephoto
        default: return .wide
        }
    }

    /// Which physical lens a virtual device is using right now.
    func activeLensPosition(for device: AVCaptureDevice) -> CameraLensPosition {
        CameraLensOption.activeLens(
            atZoomFactor: Double(device.videoZoomFactor),
            constituentLenses: device.constituentDevices.map { lensPosition(for: $0) },
            switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        ) ?? lensPosition(for: device)
    }

    /// 35mm-equivalent focal length, derived from the live hardware's field of
    /// view. This is what makes the HUD read `24mm` on the front camera and
    /// `13mm` on the back ultra-wide; the constant it replaced read the same
    /// on both.
    ///
    /// A virtual device reports its *widest* constituent's field of view, so
    /// scaling that by the raw zoom overstates every other lens — on a 15 Pro
    /// the 1× lens came out at 26mm instead of 24mm, because the hand-off
    /// factor (2.0) isn't the focal-length ratio (24/13). Measure from the
    /// physical lens that's actually live and scale by the zoom *into* it.
    func equivalentFocalLengthMillimeters(for device: AVCaptureDevice) -> Double {
        let zoom = Double(device.videoZoomFactor)
        let constituents = device.constituentDevices
        let handOffs = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)

        guard let index = CameraLensOption.activeLensIndex(
            atZoomFactor: zoom,
            constituentCount: constituents.count,
            switchOverZoomFactors: handOffs
        ) else {
            return focalLength(forFieldOfView: Double(device.activeFormat.videoFieldOfView)) * zoom
        }

        let selectionFactor = ([1.0] + handOffs)[index]
        let zoomIntoLens = selectionFactor > 0 ? zoom / selectionFactor : zoom
        let lensFieldOfView = Double(constituents[index].activeFormat.videoFieldOfView)
        return focalLength(forFieldOfView: lensFieldOfView) * zoomIntoLens
    }

    /// The ƒ-number of the lens that's live right now. A virtual device reports
    /// only its wide lens's aperture, so without this the HUD's ƒ readout sat
    /// at ƒ1.78 across `.5 · 1× · 3` — a number that looked live and wasn't.
    func apertureF(for device: AVCaptureDevice) -> Double? {
        let constituents = device.constituentDevices
        let lens = CameraLensOption.activeLensIndex(
            atZoomFactor: Double(device.videoZoomFactor),
            constituentCount: constituents.count,
            switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        ).map { constituents[$0] } ?? device
        return lens.lensAperture > 0 ? Double(lens.lensAperture) : nil
    }

    /// 35mm film is 35.9mm across the frame; half of it over tan(half the
    /// horizontal field of view) is the equivalent focal length.
    private func focalLength(forFieldOfView degrees: Double) -> Double {
        guard degrees > 0, degrees < 180 else { return 24 }
        return (35.9 / 2) / tan((degrees / 2) * .pi / 180)
    }

    func activeResolution(for device: AVCaptureDevice) -> RecordingResolution {
        videoHeight(of: device.activeFormat) >= 2160 ? .uhd4K : .hd1080
    }

    func activeFrameRate(for device: AVCaptureDevice) -> RecordingFrameRate {
        // An untouched device leaves min frame duration at the format default
        // (or invalid); fall back rather than reporting a nonsense rate.
        let seconds = device.activeVideoMinFrameDuration.seconds
        guard seconds > 0 else { return .fps30 }
        return RecordingFrameRate(rawValue: Int((1 / seconds).rounded())) ?? .fps30
    }

    private func videoHeight(of format: AVCaptureDevice.Format) -> Int32 {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription).height
    }

    func isSimulator() -> Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Rough estimate for the top HUD's "LEFT 1h42m" — free storage divided
    /// by an approximate bitrate for the active format. Not exact (real
    /// encoders vary with scene complexity); good enough for "am I about to
    /// run out," which is all that HUD element needs to answer.
    func estimatedRecordingTimeRemaining(for configuration: CameraConfiguration) -> TimeInterval? {
        guard let freeBytes = freeDiskSpaceBytes() else { return nil }
        let megabitsPerSecond = approximateBitrateMbps(for: configuration)
        let bytesPerSecond = (megabitsPerSecond * 1_000_000) / 8
        guard bytesPerSecond > 0 else { return nil }
        return Double(freeBytes) / bytesPerSecond
    }

    private func approximateBitrateMbps(for configuration: CameraConfiguration) -> Double {
        switch (configuration.resolution, configuration.frameRate) {
        case (.uhd4K, .fps60): return 55
        case (.uhd4K, _): return 35
        case (.hd1080, .fps60): return 12
        case (.hd1080, _): return 8
        }
    }

    private func freeDiskSpaceBytes() -> Int64? {
        guard let path = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path) else { return nil }
        return (attributes[.systemFreeSize] as? NSNumber)?.int64Value
    }
}
