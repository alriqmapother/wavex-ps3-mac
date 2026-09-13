import Foundation
import simd

/// Wave/spline tunables. A direct port of `ps3xmbwave/spline-settings.js`.
struct WaveParams: Codable, Equatable {
    var flowSpeed: Float = 0.18
    var tension: Float = 0.12
    var damping: Float = 0.0001
    var length: Float = 0.306001
    var spacing: Float = 407.658
    var timeStep: Float = 1.0

    var bandAmplitude: Float = 0.200
    var bandSecondaryFreq: Float = 7.0
    var bandSecondaryAmp: Float = 0.025

    var travelSpeed1: Float = 0.25
    var travelAmp1: Float = 0.014
    var travelSpeed2: Float = 0.15
    var travelAmp2: Float = 0.008

    var perturbation: Float = 0.0998587
    var perturbationScale: Float = 0.07
    var waveCosAmp: Float = 0.09
    var waveBias: Float = -0.1
    var waveHeightScale: Float = 0.5
    var waveSoftClip: Float = 0.22

    var rePipelineBlend: Float = 0.45
    var reDescriptorStrength: Float = 0.7
    var reSyntheticDescriptorSeed: Float = 1337
    var reSyntheticDescriptorMotion: Float = 0.65
    var reKernelGain: Float = 0.04
    var reNormalizeGain: Float = 0.08
    var reKernelPhaseStep: Float = 0.45
    var reIndexJitter: Float = 0.006
    var reTemporalSmooth: Float = 0.84

    var fresnelPower: Float = 4.0
    var fresnelScale: Float = 0.5
    var opacity: Float = 0.7
    var brightness: Float = 0.98
    var zDetailScale: Float = 0.08

    var ffdScale1X: Float = 5.67726
    var ffdScale1Y: Float = 1.00077
    var ffdScale1Z: Float = 1.0
    var ffdScale2X: Float = 2.82755
    var ffdScale2Y: Float = 1.27579
    var ffdScale2Z: Float = 2.88782
    var ffdOffsetX: Float = 0.0
    var ffdOffsetY: Float = -0.469999
    var ffdOffsetZ: Float = 0.0
    var ffdYAmp: Float = 0.05
    var ffdZAmp: Float = 0.06

    // Custom ("Original RGB sliders") background, used by the `custom` variant only.
    var colorR: Float = 37
    var colorG: Float = 89
    var colorB: Float = 179
    var gradientTopMul: Float = 0.09
    var gradientBotMul: Float = 0.62
}

/// Particle/sparkle tunables. Port of `ps3xmbwave/particles-settings.js`.
struct ParticleParams: Codable, Equatable {
    var count: Float = 2000
    var opacity: Float = 0.75
    var sizeBase: Float = 2.6
    var sizeVar: Float = 1.5
    var flowSpeed: Float = 0.18
}

/// Slider metadata for the settings UI.
struct ParamSpec<Root>: Identifiable {
    let id: String
    let key: WritableKeyPath<Root, Float>
    let min: Float
    let max: Float
    let step: Float
    let decimals: Int

    init(_ id: String, _ key: WritableKeyPath<Root, Float>, _ min: Float, _ max: Float, _ step: Float, decimals: Int? = nil) {
        self.id = id
        self.key = key
        self.min = min
        self.max = max
        self.step = step
        if let d = decimals {
            self.decimals = d
        } else {
            self.decimals = step >= 1 ? 0 : Swift.min(6, Int(ceil(-log10(Double(step)) - 1e-6)))
        }
    }

    var title: String {
        var out = ""
        for (i, ch) in id.enumerated() {
            if ch.isUppercase, i > 0 { out.append(" ") }
            out.append(i == 0 ? Character(ch.uppercased()) : ch)
        }
        return out
    }
}

enum ParamCatalog {
    static let basicWave: [ParamSpec<WaveParams>] = [
        .init("flowSpeed", \.flowSpeed, 0, 1.2, 0.005),
        .init("waveHeightScale", \.waveHeightScale, 0, 1, 0.005),
        .init("bandAmplitude", \.bandAmplitude, 0, 0.6, 0.002),
        .init("brightness", \.brightness, 0, 2, 0.01),
        .init("opacity", \.opacity, 0, 1, 0.005),
        .init("fresnelScale", \.fresnelScale, 0, 2, 0.01),
        .init("fresnelPower", \.fresnelPower, 0.2, 8, 0.05),
    ]

    static let advancedWave: [ParamSpec<WaveParams>] = [
        .init("tension", \.tension, 0, 0.5, 0.005),
        .init("damping", \.damping, 0, 0.002, 0.00001),
        .init("length", \.length, 0.05, 1.2, 0.001),
        .init("spacing", \.spacing, 10, 800, 1, decimals: 0),
        .init("timeStep", \.timeStep, 0.1, 4, 0.05),
        .init("bandSecondaryFreq", \.bandSecondaryFreq, 0.5, 16, 0.1),
        .init("bandSecondaryAmp", \.bandSecondaryAmp, 0, 0.12, 0.002),
        .init("travelSpeed1", \.travelSpeed1, 0, 1.5, 0.01),
        .init("travelAmp1", \.travelAmp1, 0, 0.08, 0.001),
        .init("travelSpeed2", \.travelSpeed2, 0, 1.5, 0.01),
        .init("travelAmp2", \.travelAmp2, 0, 0.08, 0.001),
        .init("perturbation", \.perturbation, 0, 0.3, 0.001),
        .init("perturbationScale", \.perturbationScale, 0, 0.3, 0.001),
        .init("waveCosAmp", \.waveCosAmp, 0, 0.3, 0.001),
        .init("waveBias", \.waveBias, -0.3, 0.3, 0.001),
        .init("waveSoftClip", \.waveSoftClip, 0.05, 0.5, 0.005),
        .init("zDetailScale", \.zDetailScale, 0, 0.25, 0.001),
        .init("ffdScale1X", \.ffdScale1X, 0, 8, 0.01),
        .init("ffdScale1Y", \.ffdScale1Y, 0, 3, 0.01),
        .init("ffdScale1Z", \.ffdScale1Z, 0, 3, 0.01),
        .init("ffdScale2X", \.ffdScale2X, 0, 8, 0.01),
        .init("ffdScale2Y", \.ffdScale2Y, 0, 3, 0.01),
        .init("ffdScale2Z", \.ffdScale2Z, 0, 6, 0.01),
        .init("ffdOffsetX", \.ffdOffsetX, -2, 2, 0.01),
        .init("ffdOffsetY", \.ffdOffsetY, -2, 2, 0.01),
        .init("ffdOffsetZ", \.ffdOffsetZ, -2, 2, 0.01),
        .init("ffdYAmp", \.ffdYAmp, 0, 0.3, 0.001),
        .init("ffdZAmp", \.ffdZAmp, 0, 0.3, 0.001),
    ]

    static let reversePipeline: [ParamSpec<WaveParams>] = [
        .init("rePipelineBlend", \.rePipelineBlend, 0, 1, 0.01),
        .init("reDescriptorStrength", \.reDescriptorStrength, 0, 2, 0.01),
        .init("reSyntheticDescriptorSeed", \.reSyntheticDescriptorSeed, 0, 100000, 1, decimals: 0),
        .init("reSyntheticDescriptorMotion", \.reSyntheticDescriptorMotion, 0, 5, 0.05),
        .init("reKernelGain", \.reKernelGain, 0, 1, 0.005),
        .init("reNormalizeGain", \.reNormalizeGain, 0, 2, 0.01),
        .init("reKernelPhaseStep", \.reKernelPhaseStep, 0, 8, 0.05),
        .init("reIndexJitter", \.reIndexJitter, 0, 0.5, 0.001),
        .init("reTemporalSmooth", \.reTemporalSmooth, 0, 0.98, 0.01),
    ]

    static let customColor: [ParamSpec<WaveParams>] = [
        .init("colorR", \.colorR, 0, 255, 1, decimals: 0),
        .init("colorG", \.colorG, 0, 255, 1, decimals: 0),
        .init("colorB", \.colorB, 0, 255, 1, decimals: 0),
        .init("gradientTopMul", \.gradientTopMul, 0, 0.3, 0.005),
        .init("gradientBotMul", \.gradientBotMul, 0.2, 1.2, 0.005),
    ]

    static let particles: [ParamSpec<ParticleParams>] = [
        .init("count", \.count, 10, 4000, 1, decimals: 0),
        .init("opacity", \.opacity, 0, 1, 0.01),
        .init("sizeBase", \.sizeBase, 1, 40, 0.1),
        .init("sizeVar", \.sizeVar, 0, 50, 0.1),
        .init("flowSpeed", \.flowSpeed, 0, 3, 0.01),
    ]
}
