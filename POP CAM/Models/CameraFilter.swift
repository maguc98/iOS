import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum CameraFilter: String, CaseIterable, Identifiable {
    case original = "Original"
    case pop = "POP"
    case warm = "Warm"
    case cream = "Cream"
    case film = "Film"
    case vintage = "Retro"
    case mono = "Mono"
    case cool = "Cool"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .original: return "自然原色"
        case .pop: return "鲜活明亮"
        case .warm: return "温柔暖调"
        case .cream: return "奶油柔光"
        case .film: return "清透胶片"
        case .vintage: return "复古记忆"
        case .mono: return "黑白故事"
        case .cool: return "清冷蓝调"
        }
    }

    func apply(to input: CIImage) -> CIImage {
        switch self {
        case .original:
            return input
        case .pop:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.saturation = 1.32
            filter.contrast = 1.12
            filter.brightness = 0.025
            return filter.outputImage ?? input
        case .warm:
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = input
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 4900, y: 0)
            return temperature.outputImage ?? input
        case .cream:
            let filter = CIFilter.colorControls()
            filter.inputImage = input
            filter.saturation = 0.82
            filter.contrast = 0.92
            filter.brightness = 0.055
            return filter.outputImage ?? input
        case .film:
            let filter = CIFilter.photoEffectTransfer()
            filter.inputImage = input
            return filter.outputImage ?? input
        case .vintage:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = input
            filter.intensity = 0.48
            return filter.outputImage ?? input
        case .mono:
            let filter = CIFilter.photoEffectMono()
            filter.inputImage = input
            return filter.outputImage ?? input
        case .cool:
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = input
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: 7900, y: 0)
            return temperature.outputImage ?? input
        }
    }

    func apply(to image: UIImage) -> UIImage {
        guard let input = CIImage(image: image),
              let output = apply(to: input).cropped(to: input.extent).cgImageValue else {
            return image
        }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }
}

private extension CIImage {
    var cgImageValue: CGImage? {
        CIContext(options: [.useSoftwareRenderer: false]).createCGImage(self, from: extent)
    }
}