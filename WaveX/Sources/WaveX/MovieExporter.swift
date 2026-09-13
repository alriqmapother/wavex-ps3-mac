import Foundation
import AVFoundation
import VideoToolbox
import CoreVideo
import CoreMedia
import Metal
import AppKit

/// Renders a variant offscreen and encodes it as HEVC with temporal sub-layers (the frame
/// layout macOS's Aerial wallpaper player expects), muxed into a .mov by AVAssetWriter.
final class MovieExporter {
    struct Options {
        var width = 3840
        var height = 2160
        var fps = 60
        var duration: Double = 120
        var bitrateMbps: Double = 16
        var temporalLayers = true
    }

    enum ExportError: LocalizedError {
        case metal
        case videoToolbox(OSStatus, String)
        case writer(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .metal: return "Metal is unavailable."
            case .videoToolbox(let s, let what): return "VideoToolbox failed (\(s)) during \(what)."
            case .writer(let m): return "Movie writer failed: \(m)"
            case .cancelled: return "Export cancelled."
            }
        }
    }

    private var cancelled = false
    func cancel() { cancelled = true }

    /// Blocking. Run on a background thread.
    func export(snapshot: SceneSnapshot, options o: Options, to url: URL, progress: @escaping (Double) -> Void) throws {
        cancelled = false
        guard let device = MTLCreateSystemDefaultDevice() else { throw ExportError.metal }
        let renderer = try WaveRenderer(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        renderer.crossfadeSeconds = 0
        renderer.resetClock(time: 0)
        renderer.snapColors(to: snapshot)
        let target = renderer.makeOffscreenTarget(width: o.width, height: o.height)

        // Metal-compatible pixel buffers backed by IOSurface.
        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: o.width,
            kCVPixelBufferHeightKey as String: o.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, poolAttrs as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw ExportError.videoToolbox(-1, "pixel buffer pool")
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            throw ExportError.videoToolbox(-1, "texture cache")
        }

        // Compression session.
        var sessionOut: VTCompressionSession?
        let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true]
        var st = VTCompressionSessionCreate(allocator: nil, width: Int32(o.width), height: Int32(o.height),
                                            codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut)
        guard st == noErr, let session = sessionOut else { throw ExportError.videoToolbox(st, "session create") }
        defer { VTCompressionSessionInvalidate(session) }

        func set(_ key: CFString, _ value: CFTypeRef, required: Bool = true) throws {
            let r = VTSessionSetProperty(session, key: key, value: value)
            if r != noErr && required { throw ExportError.videoToolbox(r, "set \(key)") }
            if r != noErr { NSLog("Wave X export: optional property \(key) rejected (\(r))") }
        }
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        try set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: Int(o.bitrateMbps * 1_000_000)))
        try set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: o.fps))
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: o.fps * 2))
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 2))
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        try set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2, required: false)
        try set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2, required: false)
        try set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2, required: false)
        if o.temporalLayers {
            // Base layer at half rate -> two temporal sub-layers. Verified on macOS 27 / Apple Silicon:
            // the encoder then tags every sample with HEVCTemporalLevelInfo and AVAssetWriter emits the
            // 'tscl' + 'tsas' sample groups that Apple's own aerial movies carry.
            // (`BaseLayerFrameRateFraction` is rejected by this encoder, hence the absolute-rate key.)
            // Non-fatal: some encoders (older Intel Macs) lack it; the movie still exports as plain HEVC.
            try set(kVTCompressionPropertyKey_BaseLayerFrameRate, NSNumber(value: max(1, o.fps / 2)), required: false)
        }
        st = VTCompressionSessionPrepareToEncodeFrames(session)
        guard st == noErr else { throw ExportError.videoToolbox(st, "prepare") }

        // Writer (passthrough input, created when the first encoded sample tells us the format).
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let writeQueue = DispatchQueue(label: "wavex.export.write")
        var input: AVAssetWriterInput?
        var failure: Error?

        func handle(_ sb: CMSampleBuffer) {
            if failure != nil { return }
            if input == nil {
                guard let fd = CMSampleBufferGetFormatDescription(sb) else { failure = ExportError.writer("no format description"); return }
                let inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fd)
                inp.expectsMediaDataInRealTime = false
                guard writer.canAdd(inp) else { failure = ExportError.writer("cannot add input"); return }
                writer.add(inp)
                guard writer.startWriting() else { failure = ExportError.writer(writer.error?.localizedDescription ?? "startWriting"); return }
                writer.startSession(atSourceTime: .zero)
                input = inp
            }
            guard let inp = input else { return }
            var spins = 0
            while !inp.isReadyForMoreMediaData && spins < 20_000 { usleep(250); spins += 1 }
            if !inp.append(sb) { failure = ExportError.writer(writer.error?.localizedDescription ?? "append") }
        }

        let total = max(1, Int(o.duration * Double(o.fps)))
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        let dt = 1.0 / Double(o.fps)

        for i in 0..<total {
            if cancelled { break }
            if let f = writeQueue.sync(execute: { failure }) { throw f }

            var pbOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else {
                throw ExportError.videoToolbox(-1, "pixel buffer")
            }
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

            var cvTexOut: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, o.width, o.height, 0, &cvTexOut) == kCVReturnSuccess,
                  let cvTex = cvTexOut, let dst = CVMetalTextureGetTexture(cvTex) else {
                throw ExportError.videoToolbox(-1, "metal texture")
            }

            renderer.advance(dt: dt)
            renderer.renderOffscreen(target: target, snapshot: snapshot) { cmd in
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: target.resolve, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                              sourceSize: MTLSize(width: o.width, height: o.height, depth: 1),
                              to: dst, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
            }

            let pts = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(o.fps))
            var flags = VTEncodeInfoFlags()
            let r = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: frameDuration,
                                                    frameProperties: nil, infoFlagsOut: &flags) { status, _, sample in
                if status != noErr {
                    writeQueue.async { if failure == nil { failure = ExportError.videoToolbox(status, "encode") } }
                    return
                }
                guard let sample else { return }
                writeQueue.async { handle(sample) }
            }
            guard r == noErr else { throw ExportError.videoToolbox(r, "encode frame") }
            if i % 15 == 0 || i == total - 1 {
                let p = Double(i + 1) / Double(total)
                DispatchQueue.main.async { progress(p) }
            }
        }

        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        writeQueue.sync {}
        if let f = failure { writer.cancelWriting(); throw f }
        if cancelled { writer.cancelWriting(); try? FileManager.default.removeItem(at: url); throw ExportError.cancelled }
        guard let inp = input else { writer.cancelWriting(); throw ExportError.writer("no frames encoded") }
        inp.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw ExportError.writer(writer.error?.localizedDescription ?? "finishWriting") }
    }

    /// Writes a still PNG (used as the catalog preview image).
    static func writeThumbnail(snapshot: SceneSnapshot, width: Int = 960, height: Int = 540, to url: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ExportError.metal }
        let renderer = try WaveRenderer(device: device, sampleCount: 4)
        renderer.crossfadeSeconds = 0
        renderer.resetClock(time: 8)
        renderer.snapColors(to: snapshot)
        let target = renderer.makeOffscreenTarget(width: width, height: height)
        for _ in 0..<3 {
            renderer.advance(dt: 1.0 / 60.0)
            renderer.renderOffscreen(target: target, snapshot: snapshot)
        }
        guard let cg = WaveRenderer.cgImage(from: target.resolve),
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            throw ExportError.writer("thumbnail encode")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
    }
}
