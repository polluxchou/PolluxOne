import AVFoundation
import SwiftUI

/// Thin UIKit bridge for AVCaptureVideoPreviewLayer — SwiftUI has no native
/// camera preview, so this is the one place UIKit interop is unavoidable
/// (per the architecture note: use AVFoundation directly, keep the native
/// interaction model). Tap-to-focus is the only gesture handled here; every
/// other control lives in the HUD.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// `(devicePoint, layerPoint)` — the first is normalized for
    /// AVCaptureDevice's focus API, the second is where to draw the reticle.
    let onTapToFocus: (CGPoint, CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapToFocus: onTapToFocus)
    }

    final class Coordinator: NSObject {
        let onTapToFocus: (CGPoint, CGPoint) -> Void
        weak var view: PreviewUIView?

        init(onTapToFocus: @escaping (CGPoint, CGPoint) -> Void) {
            self.onTapToFocus = onTapToFocus
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view else { return }
            let location = gesture.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: location)
            onTapToFocus(devicePoint, location)
        }
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
