import AVFoundation
import SwiftUI
import UIKit

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()

        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        return view
    }

    func updateUIView(
        _ uiView: CameraPreviewView,
        context: Context
    ) {
        uiView.previewLayer.session = session
        uiView.updateOrientation()
    }
}

final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let previewLayer =
                layer as? AVCaptureVideoPreviewLayer else {
            fatalError(
                "The view did not create an AVCaptureVideoPreviewLayer."
            )
        }

        return previewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        previewLayer.frame = bounds
        updateOrientation()
    }

    func updateOrientation() {
        guard let connection = previewLayer.connection else {
            return
        }

        let orientation =
            window?.windowScene?.interfaceOrientation ?? .portrait

        let rotationAngle: CGFloat

        switch orientation {
        case .portrait:
            rotationAngle = 90

        case .portraitUpsideDown:
            rotationAngle = 270

        case .landscapeLeft:
            rotationAngle = 180

        case .landscapeRight:
            rotationAngle = 0

        default:
            rotationAngle = 90
        }

        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
    }
}
