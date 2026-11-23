import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct CameraColorAdjustments: Equatable {
    var exposure: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 1
    var contrast: Double = 1
    var highlights: Double = 0
    var shadows: Double = 0

    static let neutral = CameraColorAdjustments()

    func apply(to input: CIImage) -> CIImage {
        var image = input
        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = image
        exposureFilter.ev = Float(exposure)
        image = exposureFilter.outputImage ?? image

        let temperatureFilter = CIFilter.temperatureAndTint()
        temperatureFilter.inputImage = image
        temperatureFilter.neutral = CIVector(x: 6500, y: 0)
        temperatureFilter.targetNeutral = CIVector(x: 6500 + temperature * 22, y: tint * 18)
        image = temperatureFilter.outputImage ?? image

        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = Float(saturation)
        controls.contrast = Float(contrast)
        image = controls.outputImage ?? image

        let tone = CIFilter.highlightShadowAdjust()
        tone.inputImage = image
        tone.highlightAmount = Float(1 - highlights * 0.8)
        tone.shadowAmount = Float(1 + shadows * 0.8)
        return (tone.outputImage ?? image).cropped(to: input.extent)
    }
}

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