import SwiftUI

/// The whole point of Pollux One. Camera Preview is the hero; everything else
/// is a thin HUD layered on top.
///
/// Positions come straight from "04 · Recording — HUD" in the Claude Design
/// spec, which expresses the whole screen as absolute offsets inside a
/// 393×852 frame — so this view does the same (a flow layout would drift).
/// The HUD deliberately ignores safe areas: the REC row is meant to flank the
/// Dynamic Island, and the shutter row sits 24pt off the physical bottom,
/// both of which land inside the safe-area insets.
struct RecordingView: View {
    @State private var viewModel: RecordingViewModel
    let script: Script

    @State private var focusPoint: CGPoint?
    @State private var focusHideTask: Task<Void, Never>?
    @State private var previewProxy = CameraPreviewProxy()

    /// Spec offsets, named so the intent survives a redesign.
    private enum Offset {
        static let statusRowTop: CGFloat = 16
        static let teleprompterTop: CGFloat = 60
        static let teleprompterLeading: CGFloat = 20
        /// Not a competing padding — subtracted from the space the Width
        /// slider's fraction is taken *of*, alongside the leading inset. The
        /// fraction still governs the column on its own; this only says how
        /// much room there is to take a fraction of.
        ///
        /// It exists because Width = 1.0 otherwise puts the block's right edge
        /// exactly on the screen's, which on a rounded display is under the
        /// corner curvature and reads as broken next to a 20pt left inset.
        /// 12 is the figure the pre-branch layout used, when it was a padding.
        static let teleprompterTrailing: CGFloat = 12
        static let exposureSliderBottom: CGFloat = 210
        static let paramsRowBottom: CGFloat = 162
        static let lensSelectorBottom: CGFloat = 112
        static let shutterRowBottom: CGFloat = 24
        /// Above every bottom control, inside the bottom scrim. NOT in the top
        /// HUD: that row is placed to flank the Dynamic Island, which swallows
        /// anything spanning the middle of it.
        static let archiveStatusBottom: CGFloat = 245
        /// 330, not 300: at the 28pt type-size ceiling a six-row Latin window
        /// reaches 312pt from the top, and the rows past the gradient's end
        /// lose their backing and sit straight on the picture.
        static let topScrimHeight: CGFloat = 330
        static let bottomScrimHeight: CGFloat = 270
    }

    init(script: Script, syncService: ScriptSyncService, takeArchiver: TakeArchiver) {
        self.script = script
        let sessionManager = SessionManager(
            syncService: syncService,
            alignmentEngine: SlidingWindowAlignmentEngine(),
            takeArchiver: takeArchiver
        )
        _viewModel = State(initialValue: RecordingViewModel(sessionManager: sessionManager))
    }

    var body: some View {
        ZStack {
            Color.black

            cameraLayer

            // Soft legibility scrims rather than solid plates, per the
            // "画面优先" direction — the face band stays clear.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: Offset.topScrimHeight)
                Spacer(minLength: 0)
                LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                    .frame(height: Offset.bottomScrimHeight)
            }
            .allowsHitTesting(false)

            if let focusPoint {
                FocusReticleView()
                    .position(focusPoint)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            topGroup
            bottomGroup

            if let speechError = viewModel.sessionManager.speechError {
                // A prompter that never moves looks identical to a broken
                // algorithm, so say which it is.
                Text(speechError)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(HUDColor.recRed.opacity(0.85), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .allowsHitTesting(false)
            }

            if let command = viewModel.sessionManager.pendingVoiceCommand {
                VoiceCommandConfirmationView(
                    command: command,
                    onConfirm: { viewModel.sessionManager.confirmPendingVoiceCommand() },
                    onReject: { viewModel.sessionManager.rejectPendingVoiceCommand() }
                )
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        // Record mode is fullscreen camera: no nav bar, no status bar, so
        // nothing competes with the preview or crowds the prompter near the
        // lens. Edge-swipe still returns to the script list.
        .toolbar(.hidden, for: .navigationBar)
        .task { await viewModel.start(script: script) }
        .onChange(of: viewModel.activeParameter) { _, _ in scheduleFocusReticleHide() }
        .onDisappear { viewModel.sessionManager.teardown() }
    }

    // MARK: - Layers

    @ViewBuilder
    private var cameraLayer: some View {
        if viewModel.sessionManager.cameraEngine.isSessionRunning {
            CameraPreviewView(
                session: viewModel.sessionManager.cameraEngine.session,
                proxy: previewProxy
            )
            // Tap-to-focus belongs to SwiftUI so the HUD's buttons, which sit
            // above the preview in this ZStack, consume their own taps instead
            // of also refocusing the camera wherever they happen to be.
            .onTapGesture { location in
                guard let devicePoint = previewProxy.devicePoint(for: location) else { return }
                viewModel.sessionManager.cameraEngine.focusAndMeter(at: devicePoint)
                showFocusReticle(at: location)
            }
        } else {
            CameraUnavailablePlaceholder(message: viewModel.sessionManager.cameraEngine.lastError)
        }
    }

    private var topGroup: some View {
        ZStack {
            TopHUDView(
                isRecording: viewModel.sessionManager.recordingEngine.isRecording,
                elapsedSeconds: viewModel.sessionManager.recordingEngine.elapsedSeconds,
                remainingRecordingTime: viewModel.remainingRecordingTime
            )
            .padding(.horizontal, 18)
            .topAnchored(Offset.statusRowTop)

            // The engine, not values read off it. `@Observable` registers a
            // dependency against whichever body performed the read, so reading
            // `inLineProgress` and `readingProgress` here made two 30Hz
            // properties invalidate all of this body — and with it the overlay,
            // which carries closures and so cannot be equated away, and with
            // that the whole-script ForEach inside it. Measured: 10 changes to
            // `inLineProgress` produced 10 runs of this body and 10 of the
            // overlay's. The engine splits those two out from `displayState`
            // precisely so they invalidate only the fill and the rail; passing
            // pre-read values handed that split straight back.
            //
            // `teleprompterEngine` and `sessionManager` are both `let`, which
            // `@Observable` does not track, so naming them here costs nothing.
            TeleprompterOverlayView(
                engine: viewModel.sessionManager.teleprompterEngine,
                textSize: viewModel.teleprompterSettings.textSize,
                micLevel: viewModel.sessionManager.audioLevelMonitor.recentLevels.last ?? 0,
                cameraFacing: viewModel.sessionManager.cameraEngine.configuration.facing,
                onTap: { viewModel.openTeleprompterAdjust() },
                onLayoutChange: { width, measurer in
                    viewModel.sessionManager.teleprompterEngine.setLayout(width: width, measurer: measurer)
                }
            )
            // The Width slider had never been wired to anything: this is the
            // first thing that reads textWidthFraction. It has to be applied
            // here rather than inside the overlay, because the fraction is of
            // the screen, and it is what decides where lines break.
            //
            // The fraction is of the space that is *left* once both insets are
            // taken out, not of the whole screen. Taking it of the whole screen
            // and then adding a leading padding makes the padded block
            // `width × fraction + 20` wide, which at Width = 1.0 is wider than
            // the screen — and an oversized child is centred by the anchor
            // below whatever its alignment says, so the block hung 10pt off
            // *both* edges. Subtracting first keeps the fraction as the single
            // master of the column's width while making the left inset exactly
            // 20 at every slider position.
            .containerRelativeFrame(.horizontal, alignment: .leading) { width, _ in
                (width - Offset.teleprompterLeading - Offset.teleprompterTrailing)
                    * viewModel.teleprompterSettings.textWidthFraction
            }
            .opacity(viewModel.teleprompterSettings.opacity)
            .offset(y: viewModel.teleprompterSettings.verticalOffset)
            .padding(.leading, Offset.teleprompterLeading)
            // `.topLeading`, not the default `.top`: `.top`'s horizontal
            // component is `.center`, which was a no-op while the overlay
            // filled the offered width and started sliding the whole block
            // sideways the moment containerRelativeFrame made it narrower.
            // Measured in a 393pt container, the default fraction put the left
            // edge at 37.51 instead of 20, and dragging the slider moved it.
            .topAnchored(Offset.teleprompterTop, alignment: .topLeading)
        }
    }

    private var bottomGroup: some View {
        ZStack {
            if viewModel.isAdjustingTeleprompter {
                TeleprompterAdjustView(
                    settings: $viewModel.teleprompterSettings,
                    onDone: { viewModel.closeTeleprompterAdjust() }
                )
                .bottomAnchored(Offset.exposureSliderBottom)
            } else if viewModel.activeParameter == .exposure {
                ExposureSliderView(
                    valueEV: viewModel.sessionManager.cameraEngine.configuration.exposureBiasEV,
                    minEV: viewModel.sessionManager.cameraEngine.configuration.minExposureBiasEV,
                    maxEV: viewModel.sessionManager.cameraEngine.configuration.maxExposureBiasEV,
                    onChange: { viewModel.sessionManager.cameraEngine.setExposureBias($0) }
                )
                .bottomAnchored(Offset.exposureSliderBottom)
            } else if viewModel.activeParameter == .format {
                FormatPickerView(
                    resolution: viewModel.sessionManager.cameraEngine.configuration.resolution,
                    frameRate: viewModel.sessionManager.cameraEngine.configuration.frameRate,
                    availableResolutions: viewModel.sessionManager.cameraEngine.configuration.availableResolutions,
                    availableFrameRates: viewModel.sessionManager.cameraEngine.configuration.availableFrameRates,
                    isEnabled: viewModel.canChangeFormat,
                    onSelect: { viewModel.selectFormat(resolution: $0, frameRate: $1) }
                )
                .bottomAnchored(Offset.exposureSliderBottom)
            }

            BottomCameraParamsView(
                configuration: viewModel.sessionManager.cameraEngine.configuration,
                activeParameter: viewModel.activeParameter,
                onSelect: { viewModel.selectParameter($0) }
            )
            .padding(.horizontal, 26)
            .bottomAnchored(Offset.paramsRowBottom)

            LensSelectorView(
                lenses: viewModel.sessionManager.cameraEngine.configuration.availableLenses,
                currentLens: viewModel.sessionManager.cameraEngine.configuration.lensPosition,
                onSelectLens: { viewModel.selectLens($0) }
            )
            .bottomAnchored(Offset.lensSelectorBottom)

            if let archiveMessage = viewModel.archiveMessage {
                Text(archiveMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
                    .padding(.horizontal, 32)
                    .bottomAnchored(Offset.archiveStatusBottom)
            }

            ShutterRowView(
                isRecording: viewModel.sessionManager.recordingEngine.isRecording,
                safeWordLevel: viewModel.sessionManager.audioLevelMonitor.recentLevels.last ?? 0,
                safeWord: "Pollux",
                facing: viewModel.sessionManager.cameraEngine.configuration.facing,
                canFlip: viewModel.canFlipCamera,
                onToggleRecording: { viewModel.toggleRecording() },
                onFlip: { viewModel.flipCamera() }
            )
            .padding(.horizontal, 32)
            .bottomAnchored(Offset.shutterRowBottom)
        }
    }

    private func showFocusReticle(at point: CGPoint) {
        focusHideTask?.cancel()
        withAnimation { focusPoint = point }
        scheduleFocusReticleHide()
    }

    /// While the EV control is open the reticle marks the spot the camera is
    /// metering, which is the thing the slider is working against — so it
    /// stays put until that control closes. Setting the point and then riding
    /// exposure against it is one continuous action, not two.
    private func scheduleFocusReticleHide() {
        focusHideTask?.cancel()
        guard viewModel.activeParameter != .exposure else { return }
        focusHideTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation { focusPoint = nil }
        }
    }
}

private extension View {
    /// Pins to the bottom of the container at a fixed inset, mirroring the
    /// spec's `position:absolute; bottom:Npx`.
    func bottomAnchored(_ inset: CGFloat) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, inset)
    }

    /// The `top:Npx` counterpart.
    ///
    /// `alignment` defaults to `.top` — whose *horizontal* component is
    /// `.center` — because that is what both callers wanted while both filled
    /// the offered width. Anything narrower than the container has to say
    /// `.topLeading` explicitly or it drifts to the middle. Left as a
    /// parameter rather than a changed default so `TopHUDView`, which still
    /// fills its width via an `HStack` with a `Spacer`, keeps the behaviour it
    /// was written against.
    func topAnchored(_ inset: CGFloat, alignment: Alignment = .top) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .padding(.top, inset)
    }
}

private struct CameraUnavailablePlaceholder: View {
    let message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.4))
            Text(message ?? "Preparing camera…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

private struct VoiceCommandConfirmationView: View {
    let command: VoiceCommand
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("Replace this paragraph with:")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(proposedText)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                Button("Cancel", role: .cancel, action: onReject)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Confirm", action: onConfirm)
                    .foregroundStyle(HUDColor.iosYellow)
                    .fontWeight(.semibold)
            }
        }
        .padding(20)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 32)
    }

    private var proposedText: String {
        if case .replaceParagraph(_, let newText) = command.kind { return newText }
        return command.transcript
    }
}
