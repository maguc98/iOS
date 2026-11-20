import CoreML
import CoreGraphics
import UIKit
import Foundation

enum SuperResolutionError: LocalizedError {
    case modelMissing
    case unsupportedModel
    case unsupportedImage
    case outputTooLarge
    case modelRequiresNewerOS
    case inferenceFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "AI 超分模型没有随应用安装，请重新安装最新版 POP CAM。"
        case .unsupportedModel:
            return "当前 AI 模型格式暂不受支持。"
        case .unsupportedImage:
            return "无法读取这张照片，请尝试另一张照片。"
        case .outputTooLarge:
            return "这张照片使用 4× 超分会占用过多内存，请切换为 2×。"
        case .modelRequiresNewerOS:
            return "当前 AI 模型需要 iOS 18 或更新版本。"
        case .inferenceFailed:
            return "AI 超分处理失败，请重试或切换为 2×。"
        }
    }
}

enum RealESRGANProcessor {
    static func enhance(
        image: UIImage,
        scale: Int,
        progress: @escaping (Double) -> Void
    ) throws -> UIImage {
        guard #available(iOS 18.0, *) else {
            throw SuperResolutionError.modelRequiresNewerOS
        }

        let normalizedFormat = UIGraphicsImageRendererFormat()
        normalizedFormat.scale = 1
        let normalizedImage = UIGraphicsImageRenderer(size: image.size, format: normalizedFormat).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let original = normalizedImage.cgImage else {
            throw SuperResolutionError.unsupportedImage
        }

        guard let modelURL = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil)?.first
                ?? Bundle.main.url(forResource: "RealESRGAN_x4v3", withExtension: "mlmodelc") else {
            throw SuperResolutionError.modelMissing
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)

        guard let inputEntry = model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .multiArray }),
              let inputConstraint = inputEntry.value.multiArrayConstraint,
              let outputEntry = model.modelDescription.outputDescriptionsByName.first(where: { $0.value.type == .multiArray }) else {
            throw SuperResolutionError.unsupportedModel
        }

        let inputShape = inputConstraint.shape.map(\.intValue)
        guard inputShape.count == 4, inputShape[0] == 1, inputShape[1] == 3 else {
            throw SuperResolutionError.unsupportedModel
        }

        let inputWidth = inputShape[3]
        let inputHeight = inputShape[2]
        guard let outputConstraint = outputEntry.value.multiArrayConstraint else {
            throw SuperResolutionError.unsupportedModel
        }
        let outputShape = outputConstraint.shape.map(\.intValue)
        guard outputShape.count == 4, outputShape[0] == 1, outputShape[1] == 3 else {
            throw SuperResolutionError.unsupportedModel
        }

        let tileOutputWidth = outputShape[3]
        let tileOutputHeight = outputShape[2]
        let scaleX = tileOutputWidth / inputWidth
        let scaleY = tileOutputHeight / inputHeight
        guard scaleX == 4, scaleY == 4 else {
            throw SuperResolutionError.unsupportedModel
        }

        let processingImage: CGImage
        if scale == 2 {
            let targetWidth = max(1, original.width / 2)
            let targetHeight = max(1, original.height / 2)
            guard let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw SuperResolutionError.unsupportedImage
            }
            context.interpolationQuality = .high
            context.draw(original, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            guard let resized = context.makeImage() else {
                throw SuperResolutionError.unsupportedImage
            }
            processingImage = resized
        } else {
            processingImage = original
        }

        let outputWidth = processingImage.width * scaleX
        let outputHeight = processingImage.height * scaleY
        let outputPixels = Int64(outputWidth) * Int64(outputHeight)
        guard outputPixels <= 80_000_000 else {
            throw SuperResolutionError.outputTooLarge
        }

        // Build the result in a single top-left-origin pixel buffer.
        // Avoid CGContext transforms when placing individual model tiles.
        var finalPixels = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)

        let columns = Int(ceil(Double(processingImage.width) / Double(inputWidth)))
        let rows = Int(ceil(Double(processingImage.height) / Double(inputHeight)))
        let totalTiles = max(1, columns * rows)
        var completedTiles = 0

        for tileY in stride(from: 0, to: processingImage.height, by: inputHeight) {
            for tileX in stride(from: 0, to: processingImage.width, by: inputWidth) {
                let actualWidth = min(inputWidth, processingImage.width - tileX)
                let actualHeight = min(inputHeight, processingImage.height - tileY)
                let sourceRect = CGRect(x: tileX, y: tileY, width: actualWidth, height: actualHeight)

                guard let crop = processingImage.cropping(to: sourceRect),
                      let inputPixels = makeRGBA(crop, width: inputWidth, height: inputHeight) else {
                    throw SuperResolutionError.unsupportedImage
                }

                let inputArray = try makeInputArray(
                    pixels: inputPixels,
                    shape: inputShape,
                    dataType: inputConstraint.dataType
                )
                let provider = try MLDictionaryFeatureProvider(dictionary: [
                    inputEntry.key: MLFeatureValue(multiArray: inputArray)
                ])
                let prediction = try model.prediction(from: provider)
                guard let outputArray = prediction.featureValue(for: outputEntry.key)?.multiArrayValue,
                      let tilePixels = makeOutputPixels(array: outputArray, width: tileOutputWidth, height: tileOutputHeight) else {
                    throw SuperResolutionError.inferenceFailed
                }

                let validWidth = actualWidth * scaleX
                let validHeight = actualHeight * scaleY
                let destinationX = tileX * scaleX
                let destinationY = tileY * scaleY
                for row in 0..<validHeight {
                    let sourceStart = row * tileOutputWidth * 4
                    let destinationStart = ((destinationY + row) * outputWidth + destinationX) * 4
                    let byteCount = validWidth * 4
                    finalPixels.replaceSubrange(
                        destinationStart..<(destinationStart + byteCount),
                        with: tilePixels[sourceStart..<(sourceStart + byteCount)]
                    )
                }

                completedTiles += 1
                progress(Double(completedTiles) / Double(totalTiles))
            }
        }

        guard let result = makeCGImage(pixels: finalPixels, width: outputWidth, height: outputHeight) else {
            throw SuperResolutionError.inferenceFailed
        }
        return UIImage(cgImage: result, scale: 1, orientation: .up)
    }

    private static func makeRGBA(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? pixels : nil
    }

    private static func makeInputArray(
        pixels: [UInt8],
        shape: [Int],
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: shape.map { NSNumber(value: $0) },
            dataType: dataType
        )
        let strides = array.strides.map(\.intValue)
        let width = shape[3]
        let height = shape[2]

        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = (y * width + x) * 4
                for channel in 0..<3 {
                    let offset = channel * strides[1] + y * strides[2] + x * strides[3]
                    let value = Float(pixels[pixelOffset + channel]) / 255
                    set(value, in: array, at: offset)
                }
            }
        }
        return array
    }

    private static func makeOutputPixels(array: MLMultiArray, width: Int, height: Int) -> [UInt8]? {
        guard array.shape.count == 4,
              array.shape[0].intValue == 1,
              array.shape[1].intValue == 3,
              array.shape[2].intValue == height,
              array.shape[3].intValue == width else { return nil }

        let strides = array.strides.map(\.intValue)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let pixelOffset = (y * width + x) * 4
                for channel in 0..<3 {
                    let offset = channel * strides[1] + y * strides[2] + x * strides[3]
                    let value = min(max(read(array, at: offset), 0), 1)
                    pixels[pixelOffset + channel] = UInt8((value * 255).rounded())
                }
            }
        }
        return pixels
    }

    private static func makeCGImage(pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func set(_ value: Float, in array: MLMultiArray, at index: Int) {
        switch array.dataType {
        case .float32:
            array.dataPointer.bindMemory(to: Float.self, capacity: array.count)[index] = value
        case .float16:
            array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)[index] = Float16(value).bitPattern
        case .double:
            array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[index] = Double(value)
        default:
            break
        }
    }

    private static func read(_ array: MLMultiArray, at index: Int) -> Float {
        switch array.dataType {
        case .float32:
            return array.dataPointer.bindMemory(to: Float.self, capacity: array.count)[index]
        case .float16:
            return Float(Float16(bitPattern: array.dataPointer.bindMemory(to: UInt16.self, capacity: array.count)[index]))
        case .double:
            return Float(array.dataPointer.bindMemory(to: Double.self, capacity: array.count)[index])
        default:
            return 0
        }
    }
}
