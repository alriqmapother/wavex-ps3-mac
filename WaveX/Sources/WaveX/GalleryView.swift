import SwiftUI
import AppKit
import Metal

/// Renders variant thumbnails off the main thread with a private renderer and caches them.
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()
    static let width = 384
    static let height = 216

    @Published private(set) var images: [String: NSImage] = [:]
    private var pending = Set<String>()
    private let queue = DispatchQueue(label: "wavex.thumbnails", qos: .userInitiated)
    private var renderer: WaveRenderer?
    private var target: WaveRenderer.OffscreenTarget?

    func image(for variant: Variant, snapshot: SceneSnapshot) -> NSImage? {
        if let img = images[variant.id] { return img }
        request(variant, snapshot: snapshot)
        return nil
    }

    func invalidate(_ id: String) {
        images.removeValue(forKey: id)
    }

    private func request(_ variant: Variant, snapshot: SceneSnapshot) {
        guard !pending.contains(variant.id) else { return }
        pending.insert(variant.id)
        queue.async { [self] in
            let img = render(snapshot)
            DispatchQueue.main.async {
                self.pending.remove(variant.id)
                if let img { self.images[variant.id] = img }
            }
        }
    }

    private func render(_ snapshot: SceneSnapshot) -> NSImage? {
        if renderer == nil {
            guard let device = MTLCreateSystemDefaultDevice(), let r = try? WaveRenderer(device: device, sampleCount: 4) else { return nil }
            r.crossfadeSeconds = 0
            renderer = r
            target = r.makeOffscreenTarget(width: ThumbnailStore.width, height: ThumbnailStore.height)
        }
        guard let renderer, let target else { return nil }
        renderer.resetClock(time: 8)
        renderer.snapColors(to: snapshot)
        for _ in 0..<3 {
            renderer.advance(dt: 1.0 / 60.0)
            renderer.renderOffscreen(target: target, snapshot: snapshot)
        }
        guard let cg = WaveRenderer.cgImage(from: target.resolve) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: ThumbnailStore.width / 2, height: ThumbnailStore.height / 2))
    }
}

/// Gallery filter state. (An ObservableObject rather than `@State` so the package builds
/// with the Command Line Tools, whose toolchain lacks SwiftUI's macro plugin.)
final class GalleryFilter: ObservableObject {
    @Published var family = "All"
    @Published var search = ""
}

struct GalleryView: View {
    @ObservedObject var model = SceneModel.shared
    @ObservedObject var thumbs = ThumbnailStore.shared
    @StateObject private var filter = GalleryFilter()

    private var filtered: [Variant] {
        let family = filter.family
        let search = filter.search
        return VariantCatalog.all.filter { v in
            (family == "All" || v.family == family)
                && (search.isEmpty || v.name.localizedCaseInsensitiveContains(search) || v.family.localizedCaseInsensitiveContains(search)
                    || v.kind.label.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Family", selection: $filter.family) {
                    Text("All").tag("All")
                    ForEach(VariantCatalog.families, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 160)
                Spacer()
                Text("\(filtered.count) of \(VariantCatalog.all.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                TextField("Search", text: $filter.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 14)], spacing: 16) {
                    ForEach(filtered) { v in
                        VariantTile(
                            variant: v,
                            image: thumbs.image(for: v, snapshot: model.snapshot(for: v)),
                            selected: model.selectedID == v.id,
                            previewing: model.previewID == v.id,
                            onHover: { inside in model.hover(inside ? v.id : nil) },
                            onTap: { model.select(v.id) }
                        )
                    }
                }
                .padding(14)
            }
            Divider()
            HStack {
                Text("Selected: **\(model.selectedVariant.name)**")
                Spacer()
                Text("Hover to preview on the desktop · click to keep")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: model.wave) { _, _ in thumbs.invalidate(VariantCatalog.customID) }
        .onDisappear { model.hover(nil) }
    }
}

struct VariantTile: View {
    let variant: Variant
    let image: NSImage?
    let selected: Bool
    let previewing: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.35))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(selected ? Color.accentColor : (previewing ? Color.white.opacity(0.7) : Color.white.opacity(0.12)),
                            lineWidth: selected ? 3 : 1.5)
            )
            Text(variant.name)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Text((variant.month.map { "Month \(String(format: "%02d", $0)) · " } ?? "") + variant.kind.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover(perform: onHover)
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(variant.name)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
