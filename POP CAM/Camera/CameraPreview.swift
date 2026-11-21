import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let stabilizationEnabled: Bool

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        configure(view)
        return view
    }

    func updateUIView(_ uiView: PreviewSurface, context: Context) {
        configure(uiView)
    }

    private func configure(_ view: PreviewSurface) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        view.previewLayer.videoGravity = .resizeAspectFill
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        // Keep the fallback native preview consistent with the stabilized
        // video-data and movie-output connections.
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = stabilizationEnabled ? .standard : .off
        }
    }
}

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}