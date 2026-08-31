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
        static let teleprompterTrailing: CGFloat = 12
        static let exposureSliderBottom: CGFloat = 210
        static let paramsRowBottom: CGFloat = 162
        static let lensSelectorBottom: CGFloat = 112
        static let shutterRowBottom: CGFloat = 24
        /// Above every bottom control, inside the bottom scrim. NOT in the top
        /// HUD: that row is placed to flank the Dynamic Island, which swallows
        /// anything spanning the middle of it.
        static let archiveStatusBottom: CGFloat = 245
        static let topScrimHeight: CGFloat = 300
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

            TeleprompterOverlayView(
                state: viewModel.sessionManager.teleprompterEngine.displayState,
                textSize: viewModel.teleprompterSettings.textSize,
                micLevel: viewModel.sessionManager.audioLevelMonitor.recentLevels.last ?? 0,
                cameraFacing: viewModel.sessionManager.cameraEngine.configuration.facing,
                onTap: { viewModel.openTeleprompterAdjust() }
            )
            .opacity(viewModel.teleprompterSettings.opacity)
            .offset(y: viewModel.teleprompterSettings.verticalOffset)
            .padding(.leading, Offset.teleprompterLeading)
            .padding(.trailing, Offset.teleprompterTrailing)
            .topAnchored(Offset.teleprompterTop)
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
    func topAnchored(_ inset: CGFloat) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
