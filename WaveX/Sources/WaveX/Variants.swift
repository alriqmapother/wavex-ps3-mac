import Foundation
import simd

enum VariantKind: String, Codable, CaseIterable {
    case day, night, enhanced, custom

    var label: String {
        switch self {
        case .day: return "Day"
        case .night: return "Night"
        case .enhanced: return "Enhanced"
        case .custom: return "Custom"
        }
    }
}

/// One colour variant: a 2D linear background gradient plus wave tint/brightness.
struct Variant: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let month: Int?
    let kind: VariantKind
    let angleDeg: Float
    let colorStart: SIMD3<Float>   // 0...1
    let colorEnd: SIMD3<Float>     // 0...1
    let waveBrightness: Float
    let waveColor: SIMD3<Float>

    var isCustom: Bool { kind == .custom }
}

/// Resolved background gradient, the same maths as `resolveBackgroundGradient` in `spline.js`.
struct GradientSpec: Equatable {
    var start: SIMD3<Float>
    var end: SIMD3<Float>
    var dir: SIMD2<Float>
    var tMin: Float
    var tSpan: Float

    static func linear(angleDeg: Float, start: SIMD3<Float>, end: SIMD3<Float>) -> GradientSpec {
        let rad = angleDeg * Float.pi / 180
        let dir = SIMD2<Float>(cos(rad), sin(rad))
        let t10 = dir.x, t01 = dir.y, t11 = dir.x + dir.y
        let tMin = min(0, t10, t01, t11)
        let tMax = max(0, t10, t01, t11)
        return GradientSpec(start: start, end: end, dir: dir, tMin: tMin, tSpan: max(1e-6, tMax - tMin))
    }

    static func custom(_ p: WaveParams) -> GradientSpec {
        let c = SIMD3<Float>(p.colorR, p.colorG, p.colorB) / 255
        let top = SIMD3<Float>(c.x * p.gradientTopMul, c.y * p.gradientTopMul, c.z * p.gradientTopMul * 1.2)
        let bot = c * p.gradientBotMul
        return GradientSpec(start: top, end: bot, dir: SIMD2<Float>(0, 1), tMin: 0, tSpan: 1)
    }

    static func mix(_ a: GradientSpec, _ b: GradientSpec, _ t: Float) -> GradientSpec {
        let s = 1 - t
        return GradientSpec(
            start: a.start * s + b.start * t,
            end: a.end * s + b.end * t,
            dir: simd_normalize(a.dir * s + b.dir * t),
            tMin: a.tMin * s + b.tMin * t,
            tSpan: a.tSpan * s + b.tSpan * t
        )
    }
}

enum VariantCatalog {
    /// PS3 month gradients solved from the firmware .dds files (see `ps3xmbwave/background-gradients-*.js`).
    private struct MonthPreset {
        let month: Int
        let family: String
        let slug: String
        let day: (Float, [Int], [Int])
        let night: (Float, [Int], [Int])
    }

    private static let months: [MonthPreset] = [
        .init(month: 1, family: "Grey", slug: "grey", day: (90.25, [197, 197, 197], [201, 201, 201]), night: (89.75, [181, 181, 181], [0, 0, 0])),
        .init(month: 2, family: "Gold", slug: "gold", day: (67, [203, 158, 13], [219, 214, 41]), night: (93.75, [198, 188, 128], [0, 0, 0])),
        .init(month: 3, family: "Lime", slug: "lime", day: (106, [142, 190, 40], [104, 168, 22]), night: (90.25, [152, 170, 113], [0, 0, 0])),
        .init(month: 4, family: "Pink", slug: "pink", day: (136.75, [216, 182, 182], [231, 66, 117]), night: (90.25, [212, 174, 182], [10, 8, 8])),
        .init(month: 5, family: "Deep Green", slug: "dgreen", day: (1.5, [19, 108, 19], [24, 156, 24]), night: (116, [48, 118, 48], [11, 3, 11])),
        .init(month: 6, family: "Lavender", slug: "lavender", day: (148.75, [198, 120, 238], [103, 77, 161]), night: (91, [209, 163, 225], [0, 0, 0])),
        .init(month: 7, family: "Teal", slug: "teal", day: (26.5, [0, 167, 146], [10, 240, 239]), night: (109.75, [16, 129, 124], [17, 0, 0])),
        .init(month: 8, family: "Deep Blue", slug: "dblue", day: (62.5, [0, 0, 95], [33, 217, 255]), night: (69.5, [20, 159, 176], [0, 0, 31])),
        .init(month: 9, family: "Purple", slug: "purple", day: (148.5, [146, 44, 155], [217, 98, 236]), night: (51, [116, 0, 153], [12, 0, 11])),
        .init(month: 10, family: "Orange", slug: "orange", day: (128.5, [227, 151, 15], [224, 187, 2]), night: (89.75, [216, 142, 0], [0, 0, 0])),
        .init(month: 11, family: "Brown", slug: "brown", day: (90, [115, 68, 20], [154, 118, 47]), night: (90, [131, 86, 32], [18, 20, 17])),
        .init(month: 12, family: "Red", slug: "red", day: (170.5, [236, 68, 45], [214, 63, 43]), night: (118.25, [157, 59, 44], [0, 0, 3])),
    ]

    static let customID = "custom"
    static let defaultID = "08_dblue_day"

    static let all: [Variant] = build()
    static let families: [String] = {
        var seen: [String] = []
        for v in all where !seen.contains(v.family) { seen.append(v.family) }
        return seen
    }()

    static func variant(id: String) -> Variant? { all.first { $0.id == id } }

    private static func rgb(_ v: [Int]) -> SIMD3<Float> {
        SIMD3<Float>(Float(v[0]), Float(v[1]), Float(v[2])) / 255
    }

    /// "Enhanced" = the day palette with extra saturation and contrast plus a brighter wave.
    private static func enhance(_ c: SIMD3<Float>, gain: Float) -> SIMD3<Float> {
        let luma = simd_dot(c, SIMD3<Float>(0.299, 0.587, 0.114))
        let sat = SIMD3<Float>(repeating: luma) + (c - SIMD3<Float>(repeating: luma)) * 1.35
        return simd_clamp(sat * gain, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
    }

    private static func build() -> [Variant] {
        var out: [Variant] = []
        let white = SIMD3<Float>(repeating: 1)
        for m in months {
            let mm = String(format: "%02d", m.month)
            out.append(Variant(id: "\(mm)_\(m.slug)_day", name: "\(m.family) · Day", family: m.family, month: m.month, kind: .day,
                               angleDeg: m.day.0, colorStart: rgb(m.day.1), colorEnd: rgb(m.day.2), waveBrightness: 1.0, waveColor: white))
            out.append(Variant(id: "\(mm)_\(m.slug)_night", name: "\(m.family) · Night", family: m.family, month: m.month, kind: .night,
                               angleDeg: m.night.0, colorStart: rgb(m.night.1), colorEnd: rgb(m.night.2), waveBrightness: 0.9, waveColor: white))
            out.append(Variant(id: "\(mm)_\(m.slug)_enhanced", name: "\(m.family) · Enhanced", family: m.family, month: m.month, kind: .enhanced,
                               angleDeg: m.day.0, colorStart: enhance(rgb(m.day.1), gain: 1.08), colorEnd: enhance(rgb(m.day.2), gain: 0.72),
                               waveBrightness: 1.25, waveColor: white))
        }
        out.append(Variant(id: "black_day", name: "Black · Day", family: "Black", month: nil, kind: .day,
                           angleDeg: 90, colorStart: SIMD3<Float>(repeating: 0.16), colorEnd: SIMD3<Float>(repeating: 0.0), waveBrightness: 1.0, waveColor: white))
        out.append(Variant(id: "black_enhanced", name: "Black · Enhanced", family: "Black", month: nil, kind: .enhanced,
                           angleDeg: 90, colorStart: SIMD3<Float>(repeating: 0.05), colorEnd: SIMD3<Float>(repeating: 0.0), waveBrightness: 1.4, waveColor: white))
        out.append(Variant(id: customID, name: "Custom · RGB", family: "Custom", month: nil, kind: .custom,
                           angleDeg: 90, colorStart: SIMD3<Float>(repeating: 0), colorEnd: SIMD3<Float>(repeating: 0), waveBrightness: 1.0, waveColor: white))
        return out
    }
}
