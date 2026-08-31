import AVFoundation
import SwiftUI

/// Turns a tap location into the normalized point AVCaptureDevice's focus API
/// wants, without handing the layer itself to the view layer.
///
/// This exists so the tap gesture can live in SwiftUI rather than on the
/// UIKit view: a `UITapGestureRecognizer` down here and the HUD's SwiftUI
/// buttons up there are two independent gesture systems, and a tap on the
/// shutter fires *both* — you'd start recording and refocus on the shutter
/// button at the same time. Owning the gesture in SwiftUI puts the ZStack's
/// z-order back in charge of who gets the tap.
@MainActor
final class CameraPreviewProxy {
    fileprivate weak var previewLayer: AVCaptureVideoPreviewLayer?

    func devicePoint(for layerPoint: CGPoint) -> CGPoint? {
        previewLayer?.captureDevicePointConverted(fromLayerPoint: layerPoint)
    }
}

/// Thin UIKit bridge for AVCaptureVideoPreviewLayer — SwiftUI has no native
/// camera preview, so this is the one place UIKit interop is unavoidable
/// (per the architecture note: use AVFoundation directly, keep the native
/// interaction model). It draws and nothing else; every gesture, including
/// tap-to-focus, belongs to the SwiftUI layer above.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let proxy: CameraPreviewProxy

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        proxy.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // The session outlives a camera flip, but the view can be rebuilt; keep
        // both pointers current rather than assuming makeUIView ran last.
        uiView.previewLayer.session = session
        proxy.previewLayer = uiView.previewLayer
    }

    final class PreviewUIView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
