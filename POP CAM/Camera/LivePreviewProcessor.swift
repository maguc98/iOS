import AVFoundation
import CoreImage
import QuartzCore

final class LivePreviewProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context = CIContext()
    private let lock = NSLock()
    private var activeFilter: CameraFilter = .pop
    private var lastFrameTime: CFTimeInterval = 0
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
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= (1.0 / 60.0) else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let input = CIImage(cvPixelBuffer: pixelBuffer)
        let filtered = selectedFilter.apply(to: input).cropped(to: input.extent)

        // Keep the on-screen preview lightweight; the still-photo output stays full resolution.
        let longestSide = max(filtered.extent.width, filtered.extent.height)
        let scale = min(1, 1280 / longestSide)
        let preview = scale < 1
            ? filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : filtered

        guard let frame = context.createCGImage(preview, from: preview.extent) else { return }
        onFrame?(frame)
    }
}