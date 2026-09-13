import Foundation
import Metal
import MetalKit
import simd

enum RendererError: Error { case noDevice, shader(String) }

/// Metal renderer for one output surface. Owns the pipelines, the mesh, the displacement
/// texture ring and the animation clock. Port of `spline.js` + `particles.js`.
final class WaveRenderer {
    static let textureWidth = 256
    static let textureHeight = 64
    static let gridResolution = 100
    static let ringSize = 3

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pixelFormat: MTLPixelFormat
    let sampleCount: Int

    private let bgPipeline: MTLRenderPipelineState
    private let wavePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState

    private let gridVertices: MTLBuffer
    private let gridIndices: MTLBuffer
    private let gridIndexCount: Int

    private var seedBuffer: MTLBuffer
    private var seedCount: Int

    private let splineTextures: [MTLTexture]
    private let splineData: UnsafeMutablePointer<Float>
    private let spline = SplinePipeline()
    private var frameIndex = 0
    private let inflight = DispatchSemaphore(value: WaveRenderer.ringSize)

    // Clock (Double so days of uptime never quantise the phases).
    private(set) var time: Double = 0
    private var particleTime: Double = Double.random(in: 0..<1000)
    private var lastDt: Double = 1.0 / 60.0

    // Colour crossfade state.
    private var shownGradient: GradientSpec?
    private var shownBrightness: Float = 1
    private var shownWaveColor = SIMD3<Float>(repeating: 1)

    /// Seconds a variant change takes to crossfade.
    var crossfadeSeconds: Double = 0.35

    init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm, sampleCount: Int = 4) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.sampleCount = sampleCount
        guard let queue = device.makeCommandQueue() else { throw RendererError.noDevice }
        self.queue = queue

        let library: MTLLibrary
        do {
            let opts = MTLCompileOptions()
            opts.fastMathEnabled = true
            library = try device.makeLibrary(source: waveShaderSource, options: opts)
        } catch {
            throw RendererError.shader("\(error)")
        }

        func pipeline(_ vs: String, _ fs: String, blend: ((MTLRenderPipelineColorAttachmentDescriptor) -> Void)?) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            d.colorAttachments[0].pixelFormat = pixelFormat
            d.rasterSampleCount = sampleCount
            if let blend { blend(d.colorAttachments[0]) }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        bgPipeline = try pipeline("bgVert", "bgFrag", blend: nil)
        wavePipeline = try pipeline("waveVert", "waveFrag") { c in
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .sourceAlpha
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.sourceAlphaBlendFactor = .sourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        particlePipeline = try pipeline("ptVert", "ptFrag") { c in
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.destinationRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationAlphaBlendFactor = .one
        }

        // Grid mesh: one long triangle strip with degenerate joins (same as createGrid in spline.js).
        let res = WaveRenderer.gridResolution
        let strips = res - 1
        let vertsPerStrip = res * 2
        var verts = [Float](repeating: 0, count: strips * vertsPerStrip * 2)
        var vi = 0
        for y in 0..<strips {
            for x in 0..<res {
                let fx = Float(x) / Float(res - 1) * 2 - 1
                verts[vi] = fx; verts[vi + 1] = Float(y + 1) / Float(res - 1) * 2 - 1
                verts[vi + 2] = fx; verts[vi + 3] = Float(y) / Float(res - 1) * 2 - 1
                vi += 4
            }
        }
        var idx = [UInt16](repeating: 0, count: strips * (vertsPerStrip + 2) - 2)
        var ii = 0
        var base = 0
        for s in 0..<strips {
            if s > 0 {
                idx[ii] = UInt16(base - 1); idx[ii + 1] = UInt16(base); ii += 2
            }
            for i in 0..<vertsPerStrip { idx[ii] = UInt16(base + i); ii += 1 }
            base += vertsPerStrip
        }
        gridVertices = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)!
        gridIndices = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared)!
        gridIndexCount = ii

        // Displacement texture ring.
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: WaveRenderer.textureWidth,
                                                          height: WaveRenderer.textureHeight, mipmapped: false)
        td.usage = .shaderRead
        td.storageMode = .shared
        splineTextures = (0..<WaveRenderer.ringSize).map { _ in device.makeTexture(descriptor: td)! }
        splineData = UnsafeMutablePointer<Float>.allocate(capacity: WaveRenderer.textureWidth * WaveRenderer.textureHeight)
        splineData.initialize(repeating: 0, count: WaveRenderer.textureWidth * WaveRenderer.textureHeight)

        // Particles.
        seedCount = 0
        seedBuffer = device.makeBuffer(length: 16, options: .storageModeShared)!
        rebuildParticles(count: 2000)
    }

    deinit { splineData.deallocate() }

    private func rebuildParticles(count newCount: Int) {
        let count = max(1, newCount)
        var seeds = [SIMD3<Float>](repeating: .zero, count: count)
        for i in 0..<count {
            seeds[i] = SIMD3<Float>(Float.random(in: 0..<1), Float.random(in: 0..<1), powf(Float.random(in: 0..<1), 8) + 0.1)
        }
        seedBuffer = device.makeBuffer(bytes: seeds, length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)!
        seedCount = count
    }

    // MARK: - Clock

    func advance(dt: Double) {
        let clamped = max(0, min(dt, 0.25))
        lastDt = clamped
        time += clamped
        particleTime += clamped
    }

    func resetClock(time: Double = 0) {
        self.time = time
        spline.reset()
    }

    /// Snap the crossfade to the target immediately (used for thumbnails and export).
    func snapColors(to snap: SceneSnapshot) {
        shownGradient = snap.gradient
        shownBrightness = snap.waveBrightness
        shownWaveColor = snap.waveColor
    }

    // MARK: - Uniforms

    private static func mod2pi(_ v: Double) -> Float { Float(v.truncatingRemainder(dividingBy: 2 * .pi)) }

    private func waveUniforms(_ p: WaveParams, gradientBrightness: Float, waveColor: SIMD3<Float>) -> WaveUniforms {
        let t = time
        let fs = Double(p.flowSpeed), ts = Double(p.timeStep)
        return WaveUniforms(
            ffdScale1: SIMD4<Float>(p.ffdScale1X, p.ffdScale1Y, p.ffdScale1Z, 0),
            ffdScale2: SIMD4<Float>(p.ffdScale2X, p.ffdScale2Y, p.ffdScale2Z, 0),
            ffdOffset: SIMD4<Float>(p.ffdOffsetX, p.ffdOffsetY, p.ffdOffsetZ, 0),
            waveColor: SIMD4<Float>(waveColor, 0),
            phaseFlow: Self.mod2pi(t * fs),
            phaseBase: Self.mod2pi(t * 0.5 * ts),
            phaseTension: Self.mod2pi(t * fs * ts * 0.25),
            phaseStruct1: Self.mod2pi(t * fs * ts * 0.7),
            phaseStruct2: Self.mod2pi(t * fs * ts * 0.35),
            uvShift: Float((t * fs * 0.04 * ts).truncatingRemainder(dividingBy: 1)),
            tension: p.tension, damping: p.damping, length: p.length, spacing: p.spacing,
            perturbation: p.perturbation, perturbationScale: p.perturbationScale,
            waveCosAmp: p.waveCosAmp, waveBias: p.waveBias, waveHeightScale: p.waveHeightScale,
            waveSoftClip: p.waveSoftClip, ffdYAmp: p.ffdYAmp, ffdZAmp: p.ffdZAmp, zDetailScale: p.zDetailScale,
            opacity: p.opacity, brightness: p.brightness * gradientBrightness,
            fresnelPower: p.fresnelPower, fresnelScale: p.fresnelScale
        )
    }

    // MARK: - Frame

    /// Encodes one full frame (background, wave, particles) into `pass`. Call `advance(dt:)` first.
    /// Returns the command buffer, already committed. The caller may present a drawable on it.
    @discardableResult
    func encodeFrame(pass: MTLRenderPassDescriptor, drawableSize: CGSize, snapshot: SceneSnapshot,
                     before: ((MTLCommandBuffer) -> Void)? = nil,
                     after: ((MTLCommandBuffer) -> Void)? = nil) -> MTLCommandBuffer? {
        inflight.wait()
        guard let cmd = queue.makeCommandBuffer() else { inflight.signal(); return nil }
        cmd.addCompletedHandler { [inflight] _ in inflight.signal() }

        // Colour crossfade toward the target variant.
        let k = Float(1 - exp(-lastDt / max(0.01, crossfadeSeconds) * 3))
        if let g = shownGradient {
            shownGradient = .mix(g, snapshot.gradient, k)
            shownBrightness += (snapshot.waveBrightness - shownBrightness) * k
            shownWaveColor += (snapshot.waveColor - shownWaveColor) * k
        } else {
            snapColors(to: snapshot)
        }
        let grad = shownGradient!

        // CPU displacement into this frame's ring texture.
        let tex = splineTextures[frameIndex % WaveRenderer.ringSize]
        frameIndex &+= 1
        spline.writeDisplacement(into: splineData, width: WaveRenderer.textureWidth, height: WaveRenderer.textureHeight,
                                 params: snapshot.wave, time: time, dt: lastDt)
        tex.replace(region: MTLRegionMake2D(0, 0, WaveRenderer.textureWidth, WaveRenderer.textureHeight), mipmapLevel: 0,
                    withBytes: splineData, bytesPerRow: WaveRenderer.textureWidth * 4)

        let wantCount = max(1, Int(snapshot.particles.count))
        if wantCount != seedCount { rebuildParticles(count: wantCount) }

        before?(cmd)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { cmd.commit(); return cmd }

        // Background gradient.
        var bg = BgUniforms(colorStart: SIMD4<Float>(grad.start, 1), colorEnd: SIMD4<Float>(grad.end, 1),
                            dir: grad.dir, tMin: grad.tMin, tSpan: grad.tSpan)
        enc.setRenderPipelineState(bgPipeline)
        enc.setFragmentBytes(&bg, length: MemoryLayout<BgUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Wave sheet.
        var wu = waveUniforms(snapshot.wave, gradientBrightness: shownBrightness, waveColor: shownWaveColor)
        enc.setRenderPipelineState(wavePipeline)
        enc.setVertexBuffer(gridVertices, offset: 0, index: 0)
        enc.setVertexBytes(&wu, length: MemoryLayout<WaveUniforms>.stride, index: 1)
        enc.setVertexTexture(tex, index: 0)
        enc.setFragmentBytes(&wu, length: MemoryLayout<WaveUniforms>.stride, index: 0)
        enc.drawIndexedPrimitives(type: .triangleStrip, indexCount: gridIndexCount, indexType: .uint16,
                                  indexBuffer: gridIndices, indexBufferOffset: 0)

        // Sparkles.
        let aspect = Float(drawableSize.width / max(1, drawableSize.height))
        var pu = ParticleUniforms(
            time: Float(particleTime), flowSpeed: snapshot.particles.flowSpeed,
            ratio: max(1, min(aspect, 2)) * 0.375,
            sizeBase: snapshot.particles.sizeBase, sizeVar: snapshot.particles.sizeVar,
            opacity: snapshot.particles.opacity,
            pointScale: max(1, Float(drawableSize.height) / 1080)
        )
        enc.setRenderPipelineState(particlePipeline)
        enc.setVertexBuffer(seedBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 1)
        enc.setFragmentBytes(&pu, length: MemoryLayout<ParticleUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: seedCount)

        enc.endEncoding()
        after?(cmd)
        cmd.commit()
        return cmd
    }

    // MARK: - Offscreen helpers

    struct OffscreenTarget {
        let msaa: MTLTexture?
        let resolve: MTLTexture
        let width: Int
        let height: Int

        var passDescriptor: MTLRenderPassDescriptor {
            let pass = MTLRenderPassDescriptor()
            let a = pass.colorAttachments[0]!
            a.loadAction = .clear
            a.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            if let msaa {
                a.texture = msaa
                a.resolveTexture = resolve
                a.storeAction = .multisampleResolve
            } else {
                a.texture = resolve
                a.storeAction = .store
            }
            return pass
        }
    }

    func makeOffscreenTarget(width: Int, height: Int) -> OffscreenTarget {
        let rd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        rd.usage = [.renderTarget, .shaderRead]
        rd.storageMode = .shared
        let resolve = device.makeTexture(descriptor: rd)!
        var msaa: MTLTexture? = nil
        if sampleCount > 1 {
            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
            md.textureType = .type2DMultisample
            md.sampleCount = sampleCount
            md.usage = .renderTarget
            md.storageMode = .private
            msaa = device.makeTexture(descriptor: md)
        }
        return OffscreenTarget(msaa: msaa, resolve: resolve, width: width, height: height)
    }

    /// Renders one frame synchronously into `target`.
    func renderOffscreen(target: OffscreenTarget, snapshot: SceneSnapshot, after: ((MTLCommandBuffer) -> Void)? = nil) {
        let cmd = encodeFrame(pass: target.passDescriptor, drawableSize: CGSize(width: target.width, height: target.height),
                              snapshot: snapshot, after: after)
        cmd?.waitUntilCompleted()
    }

    /// Reads a BGRA8 texture back into a CGImage.
    static func cgImage(from texture: MTLTexture) -> CGImage? {
        let w = texture.width, h = texture.height
        let bpr = w * 4
        var bytes = [UInt8](repeating: 0, count: bpr * h)
        texture.getBytes(&bytes, bytesPerRow: bpr, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        let info: CGBitmapInfo = [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
