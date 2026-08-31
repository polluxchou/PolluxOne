import Foundation

enum CameraLensPosition: String, Codable, CaseIterable {
    case ultraWide
    case wide
    case telephoto
}

enum RecordingResolution: String, Codable, CaseIterable {
    case hd1080 = "1080p"
    case uhd4K = "4K"
}

enum RecordingFrameRate: Int, Codable, CaseIterable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60
}

enum FocusMode: String, Codable {
    case auto
    case locked
    case manual
}

/// The current, user-visible state of the camera. This is a plain value type
/// so the HUD can render it without knowing about AVFoundation; CameraEngine
/// is the only thing that produces one, from live AVCaptureDevice state.
struct CameraConfiguration: Codable, Equatable {
    var lensPosition: CameraLensPosition
    var focalLengthMillimeters: Double
    var availableLensPositions: [CameraLensPosition]

    var zoomFactor: Double
    var minZoomFactor: Double
    var maxZoomFactor: Double

    var exposureBiasEV: Double
    var minExposureBiasEV: Double
    var maxExposureBiasEV: Double

    var focusMode: FocusMode
    var isAutoExposureLocked: Bool

    var apertureF: Double?
    var supportsDepth: Bool

    var resolution: RecordingResolution
    var frameRate: RecordingFrameRate
    var availableResolutions: [RecordingResolution]
    var availableFrameRates: [RecordingFrameRate]

    static let unknown = CameraConfiguration(
        lensPosition: .wide,
        focalLengthMillimeters: 24,
        availableLensPositions: [.wide],
        zoomFactor: 1,
        minZoomFactor: 1,
        maxZoomFactor: 1,
        exposureBiasEV: 0,
        minExposureBiasEV: -2,
        maxExposureBiasEV: 2,
        focusMode: .auto,
        isAutoExposureLocked: false,
        apertureF: nil,
        supportsDepth: false,
        resolution: .hd1080,
        frameRate: .fps30,
        availableResolutions: [.hd1080],
        availableFrameRates: [.fps30]
    )
}
