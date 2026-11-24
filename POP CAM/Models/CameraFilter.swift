import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Parameters shared by every photographic style.
/// Tone and Color form the two axes of the chooser; Intensity controls
/// how strongly the selected filter and its custom grading are applied.
struct CameraColorAdjustments: Equatable, Codable {
    var tone: Double = 0
    var color: Double = 0
    var intensity: Double = 100

    // Retain the existing fine controls for compatibility with other
    // camera workflows and older saved settings.
    var exposure: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var saturation: Double = 1
    var contrast: Double = 1
    var highlights: Double = 0
    var shadows: Double = 0

    // Compatibility aliases for older UI code. New UI uses Tone/Color/Intensity.
    var hue: Double {
        get { tone }
        set { tone = newValue }
    }

    var palette: Double {
        get { intensity }
        set { intensity = newValue }
    }

    static let neutral = CameraColorAdjustments()

    func apply(to input: CIImage) -> CIImage {
        var image = input

        // Tone changes the overall tonal presentation, not hue rotation.
        let toneAmount = max(-1, min(1, tone / 100.0))
        let toneFilter = CIFilter.colorControls()
        toneFilter.inputImage = image
        toneFilter.brightness = Float(toneAmount * 0.16)
        toneFilter.contrast = Float(max(0.65, min(1.35, 1.0 + toneAmount * 0.14)))
        image = toneFilter.outputImage ?? image

        // Color changes color richness independently from Tone.
        let colorFilter = CIFilter.colorControls()
        colorFilter.inputImage = image
        let colorMultiplier = 1.0 + max(-1, min(1, color / 100.0)) * 0.65
        colorFilter.saturation = Float(max(0.05, min(2.2, saturation * colorMultiplier)))
        colorFilter.contrast = Float(contrast)
        image = colorFilter.outputImage ?? image

        let exposureFilter = CIFilter.exposureAdjust()
        exposureFilter.inputImage = image
        exposureFilter.ev = Float(exposure)
        image = exposureFilter.outputImage ?? image

        let temperatureFilter = CIFilter.temperatureAndTint()
        temperatureFilter.inputImage = image
        temperatureFilter.neutral = CIVector(x: 6500, y: 0)
        temperatureFilter.targetNeutral = CIVector(x: 6500 + temperature * 22, y: tint * 18)
        image = temperatureFilter.outputImage ?? image

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

    /// Every style starts from its own Tone/Color coordinates.
    var defaultAdjustments: CameraColorAdjustments {
        switch self {
        case .original: return .init(tone: 0, color: 0, intensity: 100)
        case .pop: return .init(tone: 7, color: 12, intensity: 100)
        case .warm: return .init(tone: 3, color: 8, intensity: 100)
        case .cream: return .init(tone: 12, color: -14, intensity: 96)
        case .film: return .init(tone: 3, color: -10, intensity: 100)
        case .vintage: return .init(tone: -5, color: -4, intensity: 100)
        case .mono: return .init(tone: 8, color: -100, intensity: 100)
        case .cool: return .init(tone: -3, color: -8, intensity: 100)
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

    /// Applies the style and its Tone/Color customization, then blends the
    /// complete result against the camera original using the Intensity value.
    func render(_ input: CIImage, adjustments: CameraColorAdjustments) -> CIImage {
        let styled = adjustments.apply(to: apply(to: input)).cropped(to: input.extent)
        let strength = max(0, min(100, adjustments.intensity)) / 100.0
        guard strength < 0.999 else { return styled }

        let mask = CIImage(
            color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(strength))
        ).cropped(to: input.extent)
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = styled
        blend.backgroundImage = input
        blend.maskImage = mask
        return (blend.outputImage ?? styled).cropped(to: input.extent)
    }

    func apply(to image: UIImage) -> UIImage {
        guard let input = CIImage(image: image),
              let output = render(input, adjustments: defaultAdjustments).cropped(to: input.extent).cgImageValue else {
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