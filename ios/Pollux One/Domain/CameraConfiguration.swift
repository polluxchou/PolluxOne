import Foundation

/// Which side of the phone the active camera looks out of. Not a cosmetic
/// distinction: the entire teleprompter premise is that the prompt sits next
/// to the lens you're looking into, and that only holds for `.front`.
enum CameraFacing: String, Codable, CaseIterable {
    case front
    case back

    var displayName: String {
        switch self {
        case .front: return "FRONT"
        case .back: return "BACK"
        }
    }

    var opposite: CameraFacing { self == .front ? .back : .front }
}

enum CameraLensPosition: String, Codable, CaseIterable {
    case ultraWide
    case wide
    case telephoto
}

/// One physically distinct lens the active camera can hand capture to.
///
/// `displayZoom` and `deviceZoomFactor` are deliberately two numbers. On a
/// virtual multi-camera device — the back camera on a Pro — AVFoundation
/// anchors its zoom scale at the *ultra-wide*, so the lens a user calls "1×"
/// is device zoom 2.0. Carrying both keeps that conversion in one place
/// instead of scattering magic numbers through the HUD.
struct CameraLensOption: Codable, Equatable, Hashable, Identifiable {
    let position: CameraLensPosition
    /// Multiplier as the user reads it on the pill: 0.5, 1, 2, 5.
    let displayZoom: Double
    /// The AVCaptureDevice zoom factor that actually selects this lens.
    let deviceZoomFactor: Double

    var id: CameraLensPosition { position }
}

extension CameraLensOption {
    /// The pill's options for a virtual multi-camera device, derived from its
    /// constituent lenses (shortest focal length first) and the zoom factors
    /// at which it hands capture from one lens to the next.
    ///
    /// Kept here as pure arithmetic, separate from AVCaptureDevice, so it can
    /// be checked without a phone: the ultra-wide anchoring is exactly the
    /// kind of off-by-one that otherwise only ever surfaces as a wrong number
    /// on someone's Pro. Returns nil when the inputs don't line up, so the
    /// caller falls back to treating the camera as single-lens rather than
    /// rendering a pill built on a guess.
    static func options(
        forConstituentLenses lenses: [CameraLensPosition],
        switchOverZoomFactors handOffs: [Double]
    ) -> (options: [CameraLensOption], wideBaseZoomFactor: Double)? {
        guard lenses.count > 1, handOffs.count == lenses.count - 1 else { return nil }

        // The zoom factor that selects lens *i*: 1.0 for the base lens, then
        // the hand-off that ended the lens before it.
        let selectionFactors = [1.0] + handOffs
        let wideIndex = lenses.firstIndex(of: .wide) ?? 0
        let wideBase = selectionFactors[wideIndex]
        guard wideBase > 0 else { return nil }

        let options = lenses.indices.map { index in
            CameraLensOption(
                position: lenses[index],
                displayZoom: selectionFactors[index] / wideBase,
                deviceZoomFactor: selectionFactors[index]
            )
        }
        return (options, wideBase)
    }

    /// Which constituent is live at a given zoom. AVFoundation never reports
    /// it, so it's derived from the hand-off points the same way the system
    /// Camera's own pill decides which number to light up.
    static func activeLensIndex(
        atZoomFactor zoom: Double,
        constituentCount count: Int,
        switchOverZoomFactors handOffs: [Double]
    ) -> Int? {
        guard count > 1, handOffs.count == count - 1 else { return nil }
        var index = 0
        for (offset, factor) in handOffs.enumerated() where zoom >= factor {
            index = offset + 1
        }
        return index
    }

    static func activeLens(
        atZoomFactor zoom: Double,
        constituentLenses lenses: [CameraLensPosition],
        switchOverZoomFactors handOffs: [Double]
    ) -> CameraLensPosition? {
        activeLensIndex(
            atZoomFactor: zoom,
            constituentCount: lenses.count,
            switchOverZoomFactors: handOffs
        ).map { lenses[$0] }
    }
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

/// The HUD's bottom parameter columns. Lives in Domain rather than beside the
/// view because which of them a camera supports is a hardware question, and
/// answering it is checked offline.
enum CameraParameter: String, Codable, Equatable, CaseIterable {
    case lens, exposure, focus, depth, format
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
    var facing: CameraFacing
    /// Sides this device actually has a camera on. A phone missing one (or a
    /// Simulator with none) gets no flip control rather than a dead button.
    var availableFacings: [CameraFacing]

    var lensPosition: CameraLensPosition
    var focalLengthMillimeters: Double
    var availableLenses: [CameraLensOption]

    var zoomFactor: Double
    var minZoomFactor: Double
    var maxZoomFactor: Double
    /// Device zoom factor that reads as "1×" — see `CameraLensOption`.
    var wideBaseZoomFactor: Double

    var exposureBiasEV: Double
    var minExposureBiasEV: Double
    var maxExposureBiasEV: Double

    var focusMode: FocusMode
    var isAutoExposureLocked: Bool
    /// Whether this camera can be focused at all. Not a given: iPhone front
    /// cameras were fixed-focus until the 14, and report false here.
    var supportsFocusControl: Bool

    var apertureF: Double?
    var supportsDepth: Bool

    var resolution: RecordingResolution
    var frameRate: RecordingFrameRate
    var availableResolutions: [RecordingResolution]
    var availableFrameRates: [RecordingFrameRate]

    /// Zoom the way the pill states it, rather than the device's own scale.
    var displayZoomFactor: Double {
        wideBaseZoomFactor > 0 ? zoomFactor / wideBaseZoomFactor : zoomFactor
    }

    /// A single-lens camera has no lens to pick, and its focal length and
    /// aperture are constants — the HUD would be spending two of five columns
    /// on numbers that can never move.
    var hasSelectableLenses: Bool { availableLenses.count > 1 }

    /// Which parameter columns this camera can actually back up, in HUD order.
    ///
    /// The front/back difference falls out of the hardware rather than being
    /// hardcoded per side: the back camera earns LENS and DEPTH because its
    /// focal length and ƒ-number change as you switch between `.5 · 1× · 3`,
    /// and the single-lens front camera doesn't. FOCUS is a real query, not an
    /// assumption — a pre-iPhone-14 front camera is fixed-focus and drops it.
    var visibleParameters: [CameraParameter] {
        var parameters: [CameraParameter] = []
        if hasSelectableLenses { parameters.append(.lens) }
        if maxExposureBiasEV > minExposureBiasEV { parameters.append(.exposure) }
        if supportsFocusControl { parameters.append(.focus) }
        if hasSelectableLenses, apertureF != nil { parameters.append(.depth) }
        parameters.append(.format)
        return parameters
    }

    static let unknown = CameraConfiguration(
        facing: .front,
        availableFacings: [.front],
        lensPosition: .wide,
        focalLengthMillimeters: 24,
        availableLenses: [CameraLensOption(position: .wide, displayZoom: 1, deviceZoomFactor: 1)],
        zoomFactor: 1,
        minZoomFactor: 1,
        maxZoomFactor: 1,
        wideBaseZoomFactor: 1,
        exposureBiasEV: 0,
        minExposureBiasEV: -2,
        maxExposureBiasEV: 2,
        focusMode: .auto,
        isAutoExposureLocked: false,
        supportsFocusControl: false,
        apertureF: nil,
        supportsDepth: false,
        resolution: .hd1080,
        frameRate: .fps30,
        availableResolutions: [.hd1080],
        availableFrameRates: [.fps30]
    )
}
