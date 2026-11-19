import AVFoundation
import CoreImage

final class LivePreviewProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context = CIContext()
    private let queue = DispatchQueue(label: "com.maguc98.popcam.preview.render")
    private let lock = NSLock()
    private var activeFilter: CameraFilter = .pop
    var onFrame: ((CGImage) -> Void)?

    var selectedFilter: CameraFilter {
        get {
            lock.lock()
            defer { lock.unlock() }
            return activeFilter
        }
        set {
            lock.lock()
            activeFilter = newValue
            lock.unlock()
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let filter = selectedFilter
        let image = filter.apply(to: CIImage(cvPixelBuffer: pixelBuffer))
        guard let frame = context.createCGImage(image, from: image.extent) else { return }
        onFrame?(frame)
    }
}