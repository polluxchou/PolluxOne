import Foundation

// Offline exercise of the front/back camera pill maths.
//
// AVFoundation anchors a virtual multi-camera device's zoom scale at its
// *widest* constituent, so on a Pro's back camera `videoZoomFactor == 1.0` is
// the ultra-wide and the lens users call "1×" is device zoom 2.0. Every number
// the HUD prints — the pill's `.5 · 1× · 5`, which button is lit, the mm
// readout — rides on getting that conversion right, and it is wrong in a way
// no compiler catches: the app runs, the pill just says the wrong thing.
//
// These scenarios feed in the constituent lists and hand-off factors real
// iPhones report, so a regression shows up here rather than as "the zoom
// buttons are labelled oddly on my 15 Pro".

/// A configuration shaped like a real camera, for exercising the column rule.
@MainActor
func makeConfiguration(
    facing: CameraFacing,
    lenses: [CameraLensOption],
    supportsFocusControl: Bool,
    apertureF: Double? = 1.78
) -> CameraConfiguration {
    var configuration = CameraConfiguration.unknown
    configuration.facing = facing
    configuration.availableFacings = [.front, .back]
    configuration.availableLenses = lenses
    configuration.supportsFocusControl = supportsFocusControl
    configuration.apertureF = apertureF
    configuration.minExposureBiasEV = -8
    configuration.maxExposureBiasEV = 8
    return configuration
}

@MainActor
func runCameraSuite() -> (pass: Int, fail: Int) {
    let report = Report()
    report.suite("Camera — front/back lens mapping")

    // ── Back camera, triple (15 Pro Max: ultra-wide, wide, 5× tele) ────────
    report.section("triple camera reads as .5 · 1× · 5")
    let triple: [CameraLensPosition] = [.ultraWide, .wide, .telephoto]
    if let (options, wideBase) = CameraLensOption.options(
        forConstituentLenses: triple,
        switchOverZoomFactors: [2, 10]
    ) {
        report.check(options.map(\.displayZoom) == [0.5, 1, 5],
                     "pill shows the phone's real multipliers",
                     detail: "\(options.map(\.displayZoom))")
        report.check(options.map(\.deviceZoomFactor) == [1, 2, 10],
                     "each button sets the factor that hands over to that lens",
                     detail: "\(options.map(\.deviceZoomFactor))")
        report.check(wideBase == 2,
                     "1× is device zoom 2, not 1",
                     detail: "wideBase \(wideBase)")
    } else {
        report.check(false, "triple camera produced options")
    }

    // ── Back camera, triple (13 Pro: 3× tele rather than 5×) ───────────────
    report.section("a 3× tele phone is not hardcoded to 5×")
    if let (options, _) = CameraLensOption.options(
        forConstituentLenses: triple,
        switchOverZoomFactors: [2, 6]
    ) {
        report.check(options.map(\.displayZoom) == [0.5, 1, 3],
                     "reads the tele multiplier off the hardware",
                     detail: "\(options.map(\.displayZoom))")
    } else {
        report.check(false, "triple camera produced options")
    }

    // ── Back camera, dual wide (non-Pro: ultra-wide + wide) ────────────────
    report.section("dual-wide camera reads as .5 · 1×")
    if let (options, wideBase) = CameraLensOption.options(
        forConstituentLenses: [.ultraWide, .wide],
        switchOverZoomFactors: [2]
    ) {
        report.check(options.map(\.displayZoom) == [0.5, 1] && wideBase == 2,
                     "two lenses, still anchored at the wide",
                     detail: "\(options.map(\.displayZoom)) base \(wideBase)")
    } else {
        report.check(false, "dual-wide camera produced options")
    }

    // ── Back camera, dual (wide + tele, no ultra-wide) ─────────────────────
    report.section("a camera with no ultra-wide anchors at 1.0")
    if let (options, wideBase) = CameraLensOption.options(
        forConstituentLenses: [.wide, .telephoto],
        switchOverZoomFactors: [2]
    ) {
        report.check(options.map(\.displayZoom) == [1, 2] && wideBase == 1,
                     "the base lens already is 1×",
                     detail: "\(options.map(\.displayZoom)) base \(wideBase)")
    } else {
        report.check(false, "dual camera produced options")
    }

    // ── Front camera ───────────────────────────────────────────────────────
    report.section("front camera has nothing to switch between")
    report.check(CameraLensOption.options(forConstituentLenses: [.wide], switchOverZoomFactors: []) == nil,
                 "single lens yields no pill")
    report.check(CameraLensOption.options(forConstituentLenses: [], switchOverZoomFactors: []) == nil,
                 "a device that reports no constituents yields no pill")

    // ── Malformed input from a future device ───────────────────────────────
    report.section("inconsistent hardware data is refused, not guessed at")
    report.check(CameraLensOption.options(forConstituentLenses: triple, switchOverZoomFactors: [2]) == nil,
                 "too few hand-off factors falls back to single-lens")

    // ── Which lens is lit ──────────────────────────────────────────────────
    report.section("the lit button follows the zoom across hand-offs")
    let handOffs: [Double] = [2, 10]
    let expectations: [(zoom: Double, lens: CameraLensPosition)] = [
        (1.0, .ultraWide),   // the device's resting zoom is the ultra-wide
        (1.9, .ultraWide),
        (2.0, .wide),        // hand-off is inclusive: 2.0 is already the wide
        (9.9, .wide),
        (10.0, .telephoto),
        (24.0, .telephoto),  // past the last hand-off it stays on the tele
    ]
    for expectation in expectations {
        let got = CameraLensOption.activeLens(
            atZoomFactor: expectation.zoom,
            constituentLenses: triple,
            switchOverZoomFactors: handOffs
        )
        report.check(got == expectation.lens,
                     "zoom \(expectation.zoom) → \(expectation.lens)",
                     detail: "got \(got.map(\.rawValue) ?? "nil")")
    }

    report.check(CameraLensOption.activeLens(atZoomFactor: 1,
                                             constituentLenses: [.wide],
                                             switchOverZoomFactors: []) == nil,
                 "a single-lens camera has no hand-offs to consult")

    // ── The flip target ────────────────────────────────────────────────────
    report.section("flipping is a straight toggle")
    report.check(CameraFacing.front.opposite == .back && CameraFacing.back.opposite == .front,
                 "front ⇄ back")
    report.check(CameraFacing.front.displayName == "FRONT" && CameraFacing.back.displayName == "BACK",
                 "the HUD names the side rather than implying it")

    // ── Which parameter columns each side earns ────────────────────────────
    //
    // The counts here are the product requirement (five on the back, three on
    // the front), but they're reached by asking the hardware rather than by
    // branching on the side — so a phone that answers differently gets a
    // different, still-correct HUD instead of a wrong one.
    report.section("the parameter row is sized by capability, not by side")

    let backLenses = CameraLensOption.options(
        forConstituentLenses: triple, switchOverZoomFactors: [2, 6]
    )?.options ?? []
    let backConfiguration = makeConfiguration(facing: .back, lenses: backLenses, supportsFocusControl: true)
    report.check(backConfiguration.visibleParameters == [.lens, .exposure, .focus, .depth, .format],
                 "back camera shows five columns",
                 detail: "\(backConfiguration.visibleParameters.map(\.rawValue))")

    // A 15 Pro's front camera: one lens, but focus IS supported — verified on
    // device (isFocusPointOfInterestSupported and isFocusModeSupported(.locked)
    // both true, and it even supports a custom lens position, which the triple
    // back camera does not). So FOCUS stays; LENS and DEPTH are what go, since
    // a single lens can't change its focal length or its ƒ-number.
    let frontLenses = [CameraLensOption(position: .wide, displayZoom: 1, deviceZoomFactor: 1)]
    let frontConfiguration = makeConfiguration(facing: .front, lenses: frontLenses, supportsFocusControl: true, apertureF: 1.9)
    report.check(frontConfiguration.visibleParameters == [.exposure, .focus, .format],
                 "front camera shows three columns",
                 detail: "\(frontConfiguration.visibleParameters.map(\.rawValue))")
    report.check(frontConfiguration.visibleParameters.count == 3
                    && backConfiguration.visibleParameters.count == 5,
                 "three on the front, five on the back")

    // Pre-iPhone-14 front cameras are fixed focus and answer false, so the
    // column has to disappear rather than offer a control that does nothing.
    let fixedFocusFront = makeConfiguration(facing: .front, lenses: frontLenses, supportsFocusControl: false, apertureF: 2.2)
    report.check(fixedFocusFront.visibleParameters == [.exposure, .format],
                 "a fixed-focus front camera drops FOCUS too",
                 detail: "\(fixedFocusFront.visibleParameters.map(\.rawValue))")
    report.check(!frontConfiguration.hasSelectableLenses && backConfiguration.hasSelectableLenses,
                 "only the multi-lens side offers a lens choice")

    return (report.pass, report.fail)
}
