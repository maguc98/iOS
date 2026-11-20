import AVFoundation
import CoreImage
import QuartzCore
import CoreGraphics

final class LivePreviewProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context = CIContext()
    private let lock = NSLock()
    private var activeFilter: CameraFilter = .pop
    private var lastFrameTime: CFTimeInterval = 0
    private var lastAutofocusAnalysisTime: CFTimeInterval = 0
    private var autofocusVisualizationEnabled = false
    private let autofocusDetector = MultiPointAutofocusDetector()
    var onFrame: ((CGImage) -> Void)?
    var onAutofocusPoints: (([CGPoint]) -> Void)?

    var isAutofocusVisualizationEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return autofocusVisualizationEnabled
        }
        set {
            lock.lock()
            autofocusVisualizationEnabled = newValue
            lock.unlock()
        }
    }

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

        if isAutofocusVisualizationEnabled,
           now - lastAutofocusAnalysisTime >= 0.18 {
            lastAutofocusAnalysisTime = now
            onAutofocusPoints?(autofocusDetector.detect(in: frame))
        }
    }
}

/// Finds spatially separated high-detail regions in a downsized preview frame.
/// These are visual focus-area estimates, not hardware PDAF coordinates.
private final class MultiPointAutofocusDetector {
    private let analysisWidth = 192
    private let analysisHeight = 256
    private let columns = 8
    private let rows = 10
    private var previousPoints: [CGPoint] = []

    func detect(in image: CGImage) -> [CGPoint] {
        var gray = [UInt8](repeating: 0, count: analysisWidth * analysisHeight)
        let rendered = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: analysisWidth,
                    height: analysisHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: analysisWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: analysisWidth, height: analysisHeight))
            return true
        }
        guard rendered else { return [] }

        let cellWidth = analysisWidth / columns
        let cellHeight = analysisHeight / rows
        var scores = [Double](repeating: 0, count: columns * rows)

        for row in 0..<rows {
            for column in 0..<columns {
                let minX = column * cellWidth
                let minY = row * cellHeight
                let maxX = min(analysisWidth - 1, minX + cellWidth)
                let maxY = min(analysisHeight - 1, minY + cellHeight)
                var energy = 0.0
                var samples = 0

                for y in (minY + 1)..<(maxY - 1) {
                    for x in (minX + 1)..<(maxX - 1) {
                        let p = y * analysisWidth + x
                        let gx =
                            -Int(gray[p - analysisWidth - 1]) + Int(gray[p - analysisWidth + 1])
                            - 2 * Int(gray[p - 1]) + 2 * Int(gray[p + 1])
                            - Int(gray[p + analysisWidth - 1]) + Int(gray[p + analysisWidth + 1])
                        let gy =
                            -Int(gray[p - analysisWidth - 1]) - 2 * Int(gray[p - analysisWidth]) - Int(gray[p - analysisWidth + 1])
                            + Int(gray[p + analysisWidth - 1]) + 2 * Int(gray[p + analysisWidth]) + Int(gray[p + analysisWidth + 1])
                        energy += Double(abs(gx) + abs(gy))
                        samples += 1
                    }
                }
                scores[row * columns + column] = samples > 0 ? energy / Double(samples) : 0
            }
        }

        guard let strongest = scores.max(), strongest >= 34 else {
            previousPoints = []
            return []
        }
        let average = scores.reduce(0, +) / Double(scores.count)
        let threshold = max(25.0, average * 1.42, strongest * 0.34)

        var candidates: [(point: CGPoint, score: Double)] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let score = scores[row * columns + column]
                guard score >= threshold else { continue }

                var isLocalMaximum = true
                for neighborRow in max(0, row - 1)...min(rows - 1, row + 1) {
                    for neighborColumn in max(0, column - 1)...min(columns - 1, column + 1) {
                        if scores[neighborRow * columns + neighborColumn] > score * 1.04 {
                            isLocalMaximum = false
                        }
                    }
                }
                guard isLocalMaximum else { continue }

                candidates.append((
                    CGPoint(
                        x: (Double(column) + 0.5) / Double(columns),
                        y: (Double(row) + 0.5) / Double(rows)
                    ),
                    score
                ))
            }
        }

        candidates.sort { $0.score > $1.score }
        var selected: [CGPoint] = []
        for candidate in candidates {
            let separated = selected.allSatisfy {
                hypot($0.x - candidate.point.x, $0.y - candidate.point.y) >= 0.105
            }
            if separated {
                selected.append(candidate.point)
                if selected.count == 12 { break }
            }
        }

        let smoothed = selected.map { point -> CGPoint in
            guard let previous = previousPoints.min(by: {
                hypot($0.x - point.x, $0.y - point.y) < hypot($1.x - point.x, $1.y - point.y)
            }), hypot(previous.x - point.x, previous.y - point.y) < 0.16 else {
                return point
            }
            return CGPoint(
                x: previous.x * 0.28 + point.x * 0.72,
                y: previous.y * 0.28 + point.y * 0.72
            )
        }
        previousPoints = smoothed
        return smoothed
    }
}