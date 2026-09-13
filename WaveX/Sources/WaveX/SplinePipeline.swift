import Foundation

/// CPU displacement generator. A faithful port of `ps3xmbwave/spline-reverse.js`:
/// synthetic b380 descriptor blob -> 361-entry spline table -> 8-iteration kernel ->
/// per-row B-spline control points -> 256x64 single-channel float texture.
final class SplinePipeline {
    static let tableEntryCount = 0x169
    static let loopIters = 8
    static let b380Size = 0x2200
    static let kernelVecCount = loopIters * 8
    static let controlPointCount = 28

    private let normA: [Float] = [0.39584, -0.0052389996, -0.58664495, 0.189007]
    private let normB: [Float] = [-0.003751, -0.57536095, 0.161975, 0.417137]
    private let r37Words: [Int] = [0x00, 0x11, 0x22, 0x33]

    private var lastSeed = Int.min
    private var lastSeedParams: (Float, Float, Float, Float) = (.nan, .nan, .nan, .nan)
    private var b380 = [UInt8](repeating: 0, count: SplinePipeline.b380Size)
    private var b300 = [Float](repeating: 0, count: 16)
    private var coeffs = [Float](repeating: 0, count: SplinePipeline.tableEntryCount * 16)
    private var table = [Float](repeating: 0, count: SplinePipeline.tableEntryCount * 4)
    private var kernelPacked = [Float](repeating: 0, count: SplinePipeline.kernelVecCount * 4)
    private var kernelPrev = [Float](repeating: 0, count: SplinePipeline.kernelVecCount * 4)
    private var hasPrev = false
    private var cp = [Float](repeating: 0, count: SplinePipeline.controlPointCount)

    // Trig caches: every per-entry / per-texel argument is `constant + f(time)`, so the constant
    // part is tabulated once and each frame only pays for a handful of sin/cos calls.
    private var harmonicSin = [Float](repeating: 0, count: SplinePipeline.tableEntryCount * 16)
    private var harmonicCos = [Float](repeating: 0, count: SplinePipeline.tableEntryCount * 16)
    private var harmonicReady = false
    private var rowTrigKey: (Int, Int, Float, Float, Float) = (0, 0, .nan, .nan, .nan)
    private var rowTrig = [Float]()   // per (row, cp): sin/cos of the 5 constant phases (10 floats)

    func reset() { hasPrev = false }

    // MARK: - b380 (synthetic descriptor blob)

    private static func hash01(_ x: Double) -> Double {
        let v = sin(x) * 43758.5453123
        return v - floor(v)
    }

    private func buildB380(_ p: WaveParams) {
        let seed = Int(p.reSyntheticDescriptorSeed)
        let key = (p.length, p.tension, p.perturbationScale, p.reDescriptorStrength)
        if seed == lastSeed && key == lastSeedParams { return }
        lastSeed = seed
        lastSeedParams = key
        let len = b380.count
        for i in 0..<len {
            let f = Double(i) / Double(len)
            let wave = sin((f * 97.0) * (0.3 + Double(p.length))) * 0.5
                + sin((f * 211.0) * (0.15 + Double(p.tension) * 3.0)) * 0.3
                + sin((f * 17.0) * (0.2 + Double(p.perturbationScale) * 2.0)) * 0.2
            let noise = SplinePipeline.hash01(Double(i) * 13.37 + Double(seed) * 0.01) * 2.0 - 1.0
            let v = min(1, max(0, (wave * Double(p.reDescriptorStrength) + noise * 0.35 + 1.0) * 0.5))
            b380[i] = UInt8(Int(v * 255) & 0xff)
        }
    }

    private func decodeCoefficients(_ p: WaveParams, time: Double) {
        let len = b380.count
        let stride = 0x130
        let phase = time * Double(p.flowSpeed) * Double(p.timeStep) * Double(p.reSyntheticDescriptorMotion)
        let n = SplinePipeline.tableEntryCount
        if !harmonicReady {
            for entry in 0..<n {
                for blk in 0..<4 {
                    for lane in 0..<4 {
                        let a = Double(entry) * 0.07 + Double(blk) * 0.91 + Double(lane) * 1.37
                        harmonicSin[entry * 16 + blk * 4 + lane] = Float(sin(a))
                        harmonicCos[entry * 16 + blk * 4 + lane] = Float(cos(a))
                    }
                }
            }
            harmonicReady = true
        }
        let ph = (phase * 0.23).truncatingRemainder(dividingBy: 2 * .pi)
        let sp = Float(sin(ph)), cpz = Float(cos(ph))
        coeffs.withUnsafeMutableBufferPointer { c in
            harmonicSin.withUnsafeBufferPointer { hs in
                harmonicCos.withUnsafeBufferPointer { hc in
                    for entry in 0..<n {
                        let entryBase = entry * 16
                        let descBase = (entry * stride) % len
                        for blk in 0..<4 {
                            for lane in 0..<4 {
                                let k = entryBase + blk * 4 + lane
                                let byteIdx = (descBase + blk * 0x10 + lane * 4 + (entry % 7)) % len
                                let centered = Float(b380[byteIdx]) * (2.0 / 255.0) - 1
                                let harmonic = hs[k] * cpz + hc[k] * sp
                                c[k] = centered * 0.75 + harmonic * 0.25
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Table

    private func buildRuntimeInputs(_ s: WaveParams) {
        b300[0] = s.damping
        b300[1] = s.length
        b300[2] = s.tension
        b300[3] = s.spacing * 0.001
        b300[4] = s.waveCosAmp
        b300[5] = s.waveBias
        b300[6] = s.timeStep
        b300[7] = s.perturbation
        b300[8] = s.perturbationScale
        b300[9] = s.flowSpeed
        b300[10] = s.ffdScale1X
        b300[11] = s.ffdScale2X
        b300[12] = s.ffdOffsetY
        b300[13] = s.fresnelScale
        b300[14] = s.waveHeightScale
        b300[15] = 1.0
    }

    private func buildSplineTable(_ p: WaveParams, time: Double) {
        decodeCoefficients(p, time: time)
        let gain = p.reNormalizeGain
        let n = SplinePipeline.tableEntryCount
        let b0 = b300[0], b1 = b300[1], b2 = b300[2], b3 = b300[3]
        coeffs.withUnsafeBufferPointer { c in
            table.withUnsafeMutableBufferPointer { t in
                for i in 0..<n {
                    let cBase = i * 16
                    let tBase = i * 4
                    for lane in 0..<4 {
                        let raw = c[cBase + lane] * b0 + c[cBase + 4 + lane] * b1 + c[cBase + 8 + lane] * b2 + c[cBase + 12 + lane] * b3
                        let denomAbs = max(abs(normB[lane]), 0.05)
                        let denom = normB[lane] < 0 ? -denomAbs : denomAbs
                        let norm = ((raw - normA[lane]) / denom) * gain
                        t[tBase + lane] = tanh(norm)
                    }
                }
            }
        }
    }

    // MARK: - Kernel

    private static func tableIndex(fromWord word: Int) -> Int {
        let hi = (word >> 4) & 0xff
        let lo = word & 0xf
        return (19 * hi + lo) % tableEntryCount
    }

    private static func wrap(_ v: Float, _ len: Float) -> Float {
        var out = fmodf(v, len)
        if out < 0 { out += len }
        return out
    }

    @inline(__always)
    private func sampleTable(_ t: UnsafeBufferPointer<Float>, _ idx: Float, _ out: inout SIMD4<Float>) {
        let len = SplinePipeline.tableEntryCount
        let fl = floorf(idx)
        let i0 = Int(fl) % len
        let i1 = (i0 + 1) % len
        let f = idx - fl
        let a = SIMD4<Float>(t[i0 * 4], t[i0 * 4 + 1], t[i0 * 4 + 2], t[i0 * 4 + 3])
        let b = SIMD4<Float>(t[i1 * 4], t[i1 * 4 + 1], t[i1 * 4 + 2], t[i1 * 4 + 3])
        out = a * (1 - f) + b * f
    }

    private func runKernel(_ p: WaveParams, time: Double, dt: Double) {
        let iters = SplinePipeline.loopIters
        let n = Float(SplinePipeline.tableEntryCount)
        var v0 = SIMD4<Float>(), v1 = SIMD4<Float>(), v2 = SIMD4<Float>(), v3 = SIMD4<Float>()
        table.withUnsafeBufferPointer { t in
            kernelPacked.withUnsafeMutableBufferPointer { k in
                for iter in 0..<iters {
                    let phase = time * Double(p.reKernelPhaseStep) + Double(iter) * 0.37
                    var idx = SIMD4<Float>()
                    for lane in 0..<4 {
                        let baseWord = (r37Words[lane] + iter * 0x13) & 0xff
                        let baseIdx = Float(SplinePipeline.tableIndex(fromWord: baseWord))
                        let smooth = Float(sin(phase + Double(lane) * 0.77)) * p.reIndexJitter * n
                        idx[lane] = SplinePipeline.wrap(baseIdx + smooth, n)
                    }
                    sampleTable(t, idx[0], &v0)
                    sampleTable(t, idx[1], &v1)
                    sampleTable(t, idx[2], &v2)
                    sampleTable(t, idx[3], &v3)

                    let mixA = Float(0.5 + 0.5 * sin(phase * 0.7))
                    let mixB = Float(0.5 + 0.5 * cos(phase * 0.9))
                    @inline(__always) func store(_ s: Int, _ vec: SIMD4<Float>) {
                        let base = (iter * 8 + s) * 4
                        k[base] = vec.x; k[base + 1] = vec.y; k[base + 2] = vec.z; k[base + 3] = vec.w
                    }
                    store(0, v0 * (1 - mixA) + v1 * mixA)
                    store(1, v1 * (1 - mixB) + v2 * mixB)
                    store(2, v2 * (1 - mixA) + v3 * mixA)
                    store(3, v3 * (1 - mixB) + v0 * mixB)
                    store(4, v1 - v0)
                    store(5, v2 - v1)
                    store(6, v3 - v2)
                    store(7, v0 - v3)
                }
            }
        }

        // Temporal EMA, made frame-rate independent (the JS applied it once per 60 Hz frame).
        let perFrame = Double(min(0.999, max(0, p.reTemporalSmooth)))
        let temporal = Float(pow(perFrame, max(0.0, dt) * 60.0))
        if !hasPrev {
            kernelPrev = kernelPacked
            hasPrev = true
        } else {
            for i in 0..<kernelPacked.count {
                let sm = kernelPrev[i] * temporal + kernelPacked[i] * (1 - temporal)
                kernelPacked[i] = sm
                kernelPrev[i] = sm
            }
        }
    }

    // MARK: - Spline evaluation

    @inline(__always)
    private static func evalSpline(_ cp: UnsafeBufferPointer<Float>, _ u: Float) -> Float {
        let n = cp.count - 3
        if n < 1 { return 0 }
        let s = max(0, min(u * Float(n), Float(n) - 1e-6))
        let seg = Int(s)
        let t = s - Float(seg)
        let t2 = t * t
        let t3 = t2 * t
        let b0 = (1 - 3 * t + 3 * t2 - t3) / 6
        let b1 = (4 - 6 * t2 + 3 * t3) / 6
        let b2 = (1 + 3 * t + 3 * t2 - 3 * t3) / 6
        let b3 = t3 / 6
        return b0 * cp[seg] + b1 * cp[seg + 1] + b2 * cp[seg + 2] + b3 * cp[seg + 3]
    }

    /// Fills `out` (row-major, width*height floats) with wave displacement for `time` seconds.
    func writeDisplacement(into out: UnsafeMutablePointer<Float>, width: Int, height: Int, params p: WaveParams, time: Double, dt: Double) {
        buildRuntimeInputs(p)
        buildB380(p)
        buildSplineTable(p, time: time)
        runKernel(p, time: time, dt: dt)

        let cpCount = SplinePipeline.controlPointCount
        let kvc = SplinePipeline.kernelVecCount
        let flow = time * Double(p.flowSpeed) * Double(p.timeStep)
        let blend = p.rePipelineBlend

        // Constant phase tables (depend only on geometry + a few params).
        let key = (width, height, p.bandSecondaryFreq, p.length, p.spacing)
        if rowTrig.count != height * cpCount * 10 || key != rowTrigKey {
            rowTrigKey = key
            rowTrig = [Float](repeating: 0, count: height * cpCount * 10)
            for row in 0..<height {
                let z = Double(row) / Double(max(1, height - 1)) * 2 - 1
                for i in 0..<cpCount {
                    let x = Double(i) / Double(max(1, cpCount - 1))
                    let a0 = z * 1.7 + x * 6.2                                   // band
                    let a1 = z * Double(p.bandSecondaryFreq) + x * 4.8            // secondary band
                    let a2 = x * Double.pi * 1.3 + z * 0.8                        // travel 1
                    let a3 = x * Double.pi * 2.8 - z * 1.2                        // travel 2
                    let a4 = (x * (4.0 + Double(p.length) * 2.0) + z * 4.0) * Double(p.spacing) * 0.01   // perturbation
                    let b = (row * cpCount + i) * 10
                    rowTrig[b] = Float(sin(a0)); rowTrig[b + 1] = Float(cos(a0))
                    rowTrig[b + 2] = Float(sin(a1)); rowTrig[b + 3] = Float(cos(a1))
                    rowTrig[b + 4] = Float(sin(a2)); rowTrig[b + 5] = Float(cos(a2))
                    rowTrig[b + 6] = Float(sin(a3)); rowTrig[b + 7] = Float(cos(a3))
                    rowTrig[b + 8] = Float(sin(a4)); rowTrig[b + 9] = Float(cos(a4))
                }
            }
        }

        // Time-only phases (reduced mod 2π before the Float conversion).
        func red(_ v: Double) -> Double { v.truncatingRemainder(dividingBy: 2 * .pi) }
        let f0 = red(flow * 0.25), f1 = red(flow * 0.09)
        let f2 = red(-flow * Double(p.travelSpeed1)), f3 = red(flow * Double(p.travelSpeed2))
        let f4 = red(-flow * 0.6 * Double(p.spacing) * 0.01)
        let s0 = Float(sin(f0)), c0 = Float(cos(f0))
        let s1 = Float(sin(f1)), c1 = Float(cos(f1))
        let s2 = Float(sin(f2)), c2 = Float(cos(f2))
        let s3 = Float(sin(f3)), c3 = Float(cos(f3))
        let s4 = Float(sin(f4)), c4 = Float(cos(f4))
        let travel1Gain = p.travelAmp1 * p.tension
        let pertGain = p.perturbation * p.perturbationScale

        kernelPacked.withUnsafeBufferPointer { kp in
          rowTrig.withUnsafeBufferPointer { rt in
            cp.withUnsafeMutableBufferPointer { cpBuf in
                for row in 0..<height {
                    let rowBase = row * width

                    for i in 0..<cpCount {
                        let kvf = Double(row) * 0.93 + Double(i) * 0.61 + flow * 0.35
                        let kvFloor = floor(kvf)
                        let kv0 = ((Int(kvFloor) % kvc) + kvc) % kvc
                        let kv1 = (kv0 + 1) % kvc
                        let kt = Float(kvf - kvFloor)
                        let k0 = kv0 * 4, k1 = kv1 * 4
                        let kx = kp[k0] * (1 - kt) + kp[k1] * kt
                        let ky = kp[k0 + 1] * (1 - kt) + kp[k1 + 1] * kt
                        let kz = kp[k0 + 2] * (1 - kt) + kp[k1 + 2] * kt
                        let kw = kp[k0 + 3] * (1 - kt) + kp[k1 + 3] * kt

                        let b = (row * cpCount + i) * 10
                        // sin(a + f) = sin a cos f + cos a sin f ; cos(a + f) = cos a cos f - sin a sin f
                        let band = rt[b] * c0 + rt[b + 1] * s0
                        let band2 = rt[b + 3] * c1 - rt[b + 2] * s1
                        let trav1 = rt[b + 4] * c2 + rt[b + 5] * s2
                        let trav2 = rt[b + 6] * c3 + rt[b + 7] * s3
                        let pert = rt[b + 8] * c4 + rt[b + 9] * s4

                        let reCore = (kx * 0.45 + ky * 0.25 + kz * 0.2 + kw * 0.1) * p.reKernelGain
                            + band * p.bandAmplitude + band2 * p.bandSecondaryAmp
                        let legacy = trav1 * travel1Gain + trav2 * p.travelAmp2 + pertGain * pert

                        cpBuf[i] = reCore * blend + legacy * (1 - blend)
                    }

                    let ro = UnsafeBufferPointer(cpBuf)
                    let inv = 1 / Float(max(1, width - 1))
                    for xi in 0..<width {
                        out[rowBase + xi] = SplinePipeline.evalSpline(ro, Float(xi) * inv)
                    }
                }
            }
          }
        }
    }
}
