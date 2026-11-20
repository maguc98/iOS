import AVFoundation
import CoreImage
import QuartzCore
import CoreGraphics

struct AutofocusPoint: Identifiable, Equatable {
    let id: Int
    var location: CGPoint
    var strength: CGFloat
}

final class LivePreviewProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let context = CIContext()
    private let lock = NSLock()
    private var activeFilter: CameraFilter = .pop
    private var lastFrameTime: CFTimeInterval = 0
    private var lastAutofocusAnalysisTime: CFTimeInterval = 0
    private var autofocusVisualizationEnabled = false
    private let autofocusDetector = MultiPointAutofocusDetector()
    var onFrame: ((CGImage) -> Void)?
    var onAutofocusPoints: (([AutofocusPoint]) -> Void)?

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
    private let analysisWidth = 240
    private let analysisHeight = 320
    private let columns = 12
    private let rows = 16
    private let minimumEdgeScore = 9.0
    private let minimumSpacing = 0.105
    private let edgeInsetX = 0.085
    private let edgeInsetY = 0.075
    private var filteredScores = [Double](repeating: 0, count: 12 * 16)
    private var previousLocations: [Int: CGPoint] = [:]

    func detect(in image: CGImage) -> [AutofocusPoint] {
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

            context.interpolationQuality = .high
            // Use top-left coordinates so AF markers align with SwiftUI's displayed preview.
            context.translateBy(x: 0, y: CGFloat(analysisHeight))
            context.scaleBy(x: 1, y: -1)
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: CGFloat(analysisWidth), height: CGFloat(analysisHeight))
            )
            return true
        }
        guard rendered else { return [] }

        let cellWidth = analysisWidth / columns
        let cellHeight = analysisHeight / rows
        var rawScores = [Double](repeating: 0, count: columns * rows)

        // Tenengrad (Sobel energy) is combined with local contrast. This favors
        // textured, well-defined regions over isolated high-contrast boundaries.
        for row in 0..<rows {
            for column in 0..<columns {
                let originX = column * cellWidth
                let originY = row * cellHeight
                let minX = originX + 1
                let minY = originY + 1
                let maxX = min(analysisWidth - 1, originX + cellWidth - 1)
                let maxY = min(analysisHeight - 1, originY + cellHeight - 1)

                var sum = 0.0
                var sumSquared = 0.0
                var gradientEnergy = 0.0
                var samples = 0

                for y in minY..<maxY {
                    for x in minX..<maxX {
                        let p = y * analysisWidth + x
                        let value = Double(gray[p])
                        sum += value
                        sumSquared += value * value

                        let gx =
                            -Int(gray[p - analysisWidth - 1]) + Int(gray[p - analysisWidth + 1])
                            - 2 * Int(gray[p - 1]) + 2 * Int(gray[p + 1])
                            - Int(gray[p + analysisWidth - 1]) + Int(gray[p + analysisWidth + 1])
                        let gy =
                            -Int(gray[p - analysisWidth - 1]) - 2 * Int(gray[p - analysisWidth]) - Int(gray[p - analysisWidth + 1])
                            + Int(gray[p + analysisWidth - 1]) + 2 * Int(gray[p + analysisWidth]) + Int(gray[p + analysisWidth + 1])

                        gradientEnergy += Double(gx * gx + gy * gy)
                        samples += 1
                    }
                }

                guard samples > 0 else { continue }
                let count = Double(samples)
                let mean = sum / count
                let variance = max(0, sumSquared / count - mean * mean)
                let localContrast = sqrt(variance)
                let edgeSharpness = sqrt(gradientEnergy / count) / 4.0

                // Suppress flat regions and lift genuine fine texture without
                // letting one hard edge dominate the entire candidate ranking.
                let contrastWeight = 0.42 + 0.58 * min(1, localContrast / 48.0)
                let brightnessWeight = (mean < 12 || mean > 246) ? 0.72 : 1.0
                rawScores[row * columns + column] =
                    edgeSharpness * contrastWeight * brightnessWeight
            }
        }

        // Temporal score filtering dampens one-frame exposure/noise spikes.
        for index in rawScores.indices {
            filteredScores[index] = filteredScores[index] * 0.42 + rawScores[index] * 0.58
        }

        let sortedScores = filteredScores.sorted()
        let strongest = sortedScores.last ?? 0
        guard strongest >= minimumEdgeScore else {
            previousLocations.removeAll(keepingCapacity: true)
            return []
        }

        let positiveScores = filteredScores.filter { $0 > 0 }
        let average = positiveScores.isEmpty ? 0 : positiveScores.reduce(0, +) / Double(positiveScores.count)
        let variance = positiveScores.reduce(0) { $0 + pow($1 - average, 2) } / Double(max(1, positiveScores.count))
        let deviation = sqrt(variance)
        let threshold = max(minimumEdgeScore, max(average + deviation * 0.42, strongest * 0.28))

        var candidates: [(id: Int, location: CGPoint, score: Double)] = []
        for row in 1..<(rows - 1) {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                let score = filteredScores[index]
                guard score >= threshold else { continue }

                let location = CGPoint(
                    x: CGFloat(column) + 0.5,
                    y: CGFloat(row) + 0.5
                )
                let normalizedX = location.x / CGFloat(columns)
                let normalizedY = location.y / CGFloat(rows)

                // Avoid rounded corners and controls near the viewfinder boundary.
                guard normalizedX >= edgeInsetX,
                      normalizedX <= 1 - edgeInsetX,
                      normalizedY >= edgeInsetY,
                      normalizedY <= 1 - edgeInsetY else { continue }

                var isLocalMaximum = true
                for neighborRow in (row - 1)...(row + 1) {
                    for neighborColumn in (column - 1)...(column + 1) {
                        if neighborRow == row && neighborColumn == column { continue }
                        let neighborScore = filteredScores[neighborRow * columns + neighborColumn]
                        if neighborScore > score * 1.035 {
                            isLocalMaximum = false
                        }
                    }
                }
                guard isLocalMaximum else { continue }

                candidates.append((
                    id: index,
                    location: CGPoint(x: normalizedX, y: normalizedY),
                    score: score
                ))
            }
        }

        candidates.sort { $0.score > $1.score }
        var selected: [AutofocusPoint] = []

        for candidate in candidates {
            let separated = selected.allSatisfy {
                hypot($0.location.x - candidate.location.x, $0.location.y - candidate.location.y) >= minimumSpacing
            }
            guard separated else { continue }

            let previous = previousLocations[candidate.id]
            let smoothedLocation: CGPoint
            if let previous {
                smoothedLocation = CGPoint(
                    x: previous.x * 0.38 + candidate.location.x * 0.62,
                    y: previous.y * 0.38 + candidate.location.y * 0.62
                )
            } else {
                smoothedLocation = candidate.location
            }

            selected.append(
                AutofocusPoint(
                    id: candidate.id,
                    location: smoothedLocation,
                    strength: CGFloat(candidate.score)
                )
            )
            if selected.count == 10 { break }
        }

        previousLocations = Dictionary(
            uniqueKeysWithValues: selected.map { ($0.id, $0.location) }
        )
        return selected
    }
}
