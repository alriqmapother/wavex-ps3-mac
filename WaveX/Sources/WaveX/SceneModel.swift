import Foundation
import Combine
import simd
import ServiceManagement

/// Everything the renderer needs for one frame, captured on the main thread.
struct SceneSnapshot {
    var wave: WaveParams
    var particles: ParticleParams
    var gradient: GradientSpec
    var waveBrightness: Float
    var waveColor: SIMD3<Float>
}

/// App-wide observable state: chosen variant, hover preview, tunables, persistence.
final class SceneModel: ObservableObject {
    static let shared = SceneModel()

    @Published var selectedID: String { didSet { persist() } }
    @Published private(set) var previewID: String?
    @Published var wave: WaveParams { didSet { persist() } }
    @Published var particles: ParticleParams { didSet { persist() } }
    @Published var paused: Bool = false
    @Published var fpsLimit: Int { didSet { persist() } }          // 0 = display maximum
    @Published var launchAtLogin: Bool = false

    private let defaults = UserDefaults.standard
    private var hoverGrace: DispatchWorkItem?
    private var loading = true

    static let hoverGraceMs = 150

    private init() {
        let storedID = UserDefaults.standard.string(forKey: "selectedVariant") ?? VariantCatalog.defaultID
        selectedID = VariantCatalog.variant(id: storedID) == nil ? VariantCatalog.defaultID : storedID
        wave = Self.load("waveParams") ?? WaveParams()
        particles = Self.load("particleParams") ?? ParticleParams()
        // Default to 60 fps: indistinguishable for a slow wave, and much easier on the battery than 120.
        fpsLimit = UserDefaults.standard.object(forKey: "fpsLimit") == nil ? 60 : UserDefaults.standard.integer(forKey: "fpsLimit")
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loading = false
    }

    var selectedVariant: Variant { VariantCatalog.variant(id: selectedID) ?? VariantCatalog.all[0] }
    var activeVariant: Variant { previewID.flatMap(VariantCatalog.variant(id:)) ?? selectedVariant }

    func select(_ id: String) {
        hoverGrace?.cancel()
        previewID = nil
        selectedID = id
    }

    /// Hover-to-preview with a short grace period so moving between tiles never flashes the
    /// selected variant in between.
    func hover(_ id: String?) {
        hoverGrace?.cancel()
        if let id {
            previewID = id
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.previewID = nil }
        hoverGrace = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Self.hoverGraceMs), execute: item)
    }

    func gradient(for v: Variant) -> GradientSpec {
        v.isCustom ? .custom(wave) : .linear(angleDeg: v.angleDeg, start: v.colorStart, end: v.colorEnd)
    }

    func snapshot(for v: Variant? = nil) -> SceneSnapshot {
        let variant = v ?? activeVariant
        return SceneSnapshot(wave: wave, particles: particles, gradient: gradient(for: variant),
                             waveBrightness: variant.waveBrightness, waveColor: variant.waveColor)
    }

    func resetWave() { wave = WaveParams() }
    func resetParticles() { particles = ParticleParams() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            NSLog("Launch at login failed: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard !loading else { return }
        defaults.set(selectedID, forKey: "selectedVariant")
        defaults.set(fpsLimit, forKey: "fpsLimit")
        Self.store(wave, "waveParams")
        Self.store(particles, "particleParams")
    }

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }
}
