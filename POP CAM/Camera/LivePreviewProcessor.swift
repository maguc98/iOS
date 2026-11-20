import AVFoundation
import CoreImage
import QuartzCore
import CoreGraphics
import UIKit

struct VisualMotionEstimate: Equatable {
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    var confidence: CGFloat = 0
}

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
    private let visualMotionDetector = GlobalMotionDetector()
    private var lastMotionAnalysisTime: CFTimeInterval = 0
    var onFrame: ((CGImage) -> Void)?
    var onAutofocusPoints: (([AutofocusPoint]) -> Void)?
    var onVisualMotion: ((VisualMotionEstimate) -> Void)?

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

        if now - lastMotionAnalysisTime >= 0.12 {
            lastMotionAnalysisTime = now
            onVisualMotion?(visualMotionDetector.estimate(in: frame))
        }

        if isAutofocusVisualizationEnabled,
           now - lastAutofocusAnalysisTime >= 0.18 {
            lastAutofocusAnalysisTime = now
            onAutofocusPoints?(autofocusDetector.detect(in: frame))
        }
    }
}

/// Estimates dominant frame-to-frame image translation from sampled luminance.
/// This is visual scene-motion tracking, not a replacement for AVFoundation EIS.
private final class GlobalMotionDetector {
    private let width = 80
    private let height = 100
    private var previous: [UInt8]?
    private var smoothed = VisualMotionEstimate()

    func estimate(in image: CGImage) -> VisualMotionEstimate {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return smoothed }
        guard let previous else { self.previous = pixels; return VisualMotionEstimate() }

        let radius = 7
        var bestError = Double.greatestFiniteMagnitude
        var secondBest = Double.greatestFiniteMagnitude
        var bestDX = 0
        var bestDY = 0
        // Sample every second pixel to keep this suitable for live preview.
        for dy in -radius...radius {
            for dx in -radius...radius {
                var error = 0.0
                var count = 0
                for y in stride(from: radius + 2, to: height - radius - 2, by: 2) {
                    for x in stride(from: radius + 2, to: width - radius - 2, by: 2) {
                        let a = Int(previous[y * width + x])
                        let b = Int(pixels[(y + dy) * width + (x + dx)])
                        error += Double(abs(a - b))
                        count += 1
                    }
                }
                let score = error / Double(max(1, count))
                if score < bestError {
                    secondBest = bestError
                    bestError = score
                    bestDX = dx
                    bestDY = dy
                } else if score < secondBest {
                    secondBest = score
                }
            }
        }
        self.previous = pixels
        let confidence = min(1, max(0, (secondBest - bestError) / max(secondBest, 1)))
        let valid = bestError < 34 && confidence > 0.008
        let target = VisualMotionEstimate(
            offsetX: valid ? CGFloat(bestDX) / CGFloat(width) : 0,
            offsetY: valid ? CGFloat(bestDY) / CGFloat(height) : 0,
            confidence: valid ? confidence : 0
        )
        smoothed.offsetX += (target.offsetX - smoothed.offsetX) * 0.38
        smoothed.offsetY += (target.offsetY - smoothed.offsetY) * 0.38
        smoothed.confidence += (target.confidence - smoothed.confidence) * 0.30
        return smoothed
    }
}

/// Finds spatially separated high-detail regions in a downsized preview frame.
/// These are visual focus-area estimates, not hardware PDAF coordinates.

private final class MultiPointAutofocusDetector {
    private let analysisWidth = 240
    private let analysisHeight = 320
    private let columns = 12
    private let rows = 16
    private let minimumEdgeScore = 0.65
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

        let strongest = filteredScores.max() ?? 0
        guard strongest >= minimumEdgeScore else {
            previousLocations.removeAll(keepingCapacity: true)
            return []
        }

        // Select multiple real detail-rich cells across the frame. The threshold
        // adapts to scene contrast, while non-maximum spacing prevents clusters.
        let threshold = max(minimumEdgeScore, strongest * 0.14)
        let rankedIndices = filteredScores.indices.sorted {
            filteredScores[$0] > filteredScores[$1]
        }
        var selected: [AutofocusPoint] = []

        for index in rankedIndices {
            let row = index / columns
            let column = index % columns
            guard row > 0, row < rows - 1, column > 0, column < columns - 1 else { continue }

            let score = filteredScores[index]
            guard score >= threshold else { break }

            let normalizedX = (CGFloat(column) + 0.5) / CGFloat(columns)
            let normalizedY = (CGFloat(row) + 0.5) / CGFloat(rows)
            guard normalizedX >= edgeInsetX, normalizedX <= 1 - edgeInsetX,
                  normalizedY >= edgeInsetY, normalizedY <= 1 - edgeInsetY else { continue }

            let location = CGPoint(x: normalizedX, y: normalizedY)
            let separated = selected.allSatisfy {
                hypot($0.location.x - location.x, $0.location.y - location.y) >= 0.075
            }
            guard separated else { continue }

            let previous = previousLocations[index]
            let smoothedLocation: CGPoint
            if let previous {
                smoothedLocation = CGPoint(
                    x: previous.x * 0.38 + location.x * 0.62,
                    y: previous.y * 0.38 + location.y * 0.62
                )
            } else {
                smoothedLocation = location
            }

            selected.append(
                AutofocusPoint(id: index, location: smoothedLocation, strength: CGFloat(score))
            )
            if selected.count == 9 { break }
        }

        previousLocations = Dictionary(
            uniqueKeysWithValues: selected.map { ($0.id, $0.location) }
        )
        return selected
    }
}
