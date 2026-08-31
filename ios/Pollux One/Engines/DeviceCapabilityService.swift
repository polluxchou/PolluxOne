import AVFoundation
import Foundation

/// The single source of truth for "does this device/mode actually support X".
/// Every HUD control (Feature 3) asks this before rendering, so we never show
/// a parameter the hardware can't back up.
final class DeviceCapabilityService {
    struct FrontCameraCapabilities {
        let availableLensPositions: [CameraLensPosition]
        let maxZoomFactor: Double
        let minExposureBiasEV: Double
        let maxExposureBiasEV: Double
        let supportsDepth: Bool
        let apertureF: Double?
        let availableResolutions: [RecordingResolution]
        let availableFrameRates: [RecordingFrameRate]
    }

    /// TrueDepth front cameras report an aperture but iPhones do not expose a
    /// variable one, so this is descriptive, not user-adjustable.
    func frontCameraCapabilities(for device: AVCaptureDevice) -> FrontCameraCapabilities {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .front
        )
        let lensPositions: [CameraLensPosition] = discovery.devices.compactMap { device in
            switch device.deviceType {
            case .builtInUltraWideCamera: return .ultraWide
            case .builtInWideAngleCamera: return .wide
            case .builtInTelephotoCamera: return .telephoto
            default: return nil
            }
        }

        let supportsDepth = !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTrueDepthCamera],
            mediaType: .depthData,
            position: .front
        ).devices.isEmpty

        var frameRates: [RecordingFrameRate] = [.fps24, .fps30]
        if let maxFrameRateRange = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }),
           maxFrameRateRange.maxFrameRate >= 60 {
            frameRates.append(.fps60)
        }

        return FrontCameraCapabilities(
            availableLensPositions: lensPositions.isEmpty ? [.wide] : lensPositions,
            maxZoomFactor: min(device.activeFormat.videoMaxZoomFactor, 8),
            minExposureBiasEV: Double(device.minExposureTargetBias),
            maxExposureBiasEV: Double(device.maxExposureTargetBias),
            supportsDepth: supportsDepth,
            apertureF: supportsDepth ? 1.9 : nil,
            availableResolutions: [.hd1080, .uhd4K],
            availableFrameRates: frameRates
        )
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
