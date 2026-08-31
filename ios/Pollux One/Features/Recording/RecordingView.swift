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
        static let topScrimHeight: CGFloat = 300
        static let bottomScrimHeight: CGFloat = 270
    }

    init(script: Script, syncService: ScriptSyncService) {
        self.script = script
        let sessionManager = SessionManager(syncService: syncService, alignmentEngine: SlidingWindowAlignmentEngine())
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
    }

    // MARK: - Layers

    @ViewBuilder
    private var cameraLayer: some View {
        if viewModel.sessionManager.cameraEngine.isSessionRunning {
            CameraPreviewView(
                session: viewModel.sessionManager.cameraEngine.session,
                onTapToFocus: { point, layerPoint in
                    viewModel.sessionManager.cameraEngine.focus(at: point)
                    showFocusReticle(at: layerPoint)
                }
            )
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
            }

            BottomCameraParamsView(
                configuration: viewModel.sessionManager.cameraEngine.configuration,
                activeParameter: viewModel.activeParameter,
                onSelect: { viewModel.selectParameter($0) }
            )
            .padding(.horizontal, 26)
            .bottomAnchored(Offset.paramsRowBottom)

            LensSelectorView(
                availableLenses: viewModel.sessionManager.cameraEngine.configuration.availableLensPositions,
                currentLens: viewModel.sessionManager.cameraEngine.configuration.lensPosition,
                onSelectLens: { viewModel.selectLens($0) }
            )
            .bottomAnchored(Offset.lensSelectorBottom)

            ShutterRowView(
                isRecording: viewModel.sessionManager.recordingEngine.isRecording,
                safeWordLevel: viewModel.sessionManager.audioLevelMonitor.recentLevels.last ?? 0,
                safeWord: "Pollux",
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
