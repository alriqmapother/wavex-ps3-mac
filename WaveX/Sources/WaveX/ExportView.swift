import SwiftUI
import AppKit

final class ExportController: ObservableObject {
    enum Resolution: String, CaseIterable, Identifiable {
        case display, uhd, qhd, fhd
        var id: String { rawValue }
        var label: String {
            switch self {
            case .display:
                let s = ExportController.displayPixels
                return "This display (\(Int(s.width))×\(Int(s.height)))"
            case .uhd: return "4K UHD (3840×2160)"
            case .qhd: return "QHD (2560×1440)"
            case .fhd: return "Full HD (1920×1080)"
            }
        }
        var size: (Int, Int) {
            switch self {
            case .display:
                let s = ExportController.displayPixels
                return (Int(s.width) & ~1, Int(s.height) & ~1)
            case .uhd: return (3840, 2160)
            case .qhd: return (2560, 1440)
            case .fhd: return (1920, 1080)
            }
        }
    }

    static var displayPixels: CGSize {
        guard let s = NSScreen.main else { return CGSize(width: 3840, height: 2160) }
        let scale = s.backingScaleFactor
        return CGSize(width: s.frame.width * scale, height: s.frame.height * scale)
    }

    @Published var resolution: Resolution = .uhd
    @Published var fps = 60
    @Published var duration: Double = 120
    @Published var running = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var installed: [LockScreenInstaller.Installed] = LockScreenInstaller.installed()

    private var exporter: MovieExporter?

    static var exportsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wave X/exports", isDirectory: true)
    }

    func refresh() { installed = LockScreenInstaller.installed() }

    func cancel() { exporter?.cancel() }

    private func options() -> MovieExporter.Options {
        let (w, h) = resolution.size
        return MovieExporter.Options(width: w, height: h, fps: fps, duration: duration)
    }

    /// Export the current variant to a user-chosen location.
    func exportToFile(model: SceneModel) {
        let variant = model.selectedVariant
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "Wave X - \(variant.name).mov"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(snapshot: model.snapshot(for: variant), variant: variant, movieURL: url, install: false)
    }

    /// Export the current variant into the app's support folder and register it for the lock screen.
    func exportAndInstall(model: SceneModel) {
        let variant = model.selectedVariant
        let url = Self.exportsDir.appendingPathComponent("\(variant.id).mov")
        run(snapshot: model.snapshot(for: variant), variant: variant, movieURL: url, install: true)
    }

    private func run(snapshot: SceneSnapshot, variant: Variant, movieURL: URL, install: Bool) {
        guard !running else { return }
        if install && !LockScreenInstaller.isCatalogPresent {
            status = LockScreenInstaller.InstallError.catalogMissing.localizedDescription
            return
        }
        running = true
        progress = 0
        status = "Rendering \(variant.name)…"
        let exporter = MovieExporter()
        self.exporter = exporter
        let opts = options()
        let thread = Thread { [weak self] in
            var message = ""
            do {
                try exporter.export(snapshot: snapshot, options: opts, to: movieURL) { p in
                    self?.progress = p
                    self?.status = String(format: "Encoding %@… %.0f%%", variant.name, p * 100)
                }
                if install {
                    let thumb = movieURL.deletingPathExtension().appendingPathExtension("png")
                    try MovieExporter.writeThumbnail(snapshot: snapshot, to: thumb)
                    DispatchQueue.main.sync { self?.status = "Registering with the wallpaper catalog…" }
                    try LockScreenInstaller.install(movie: movieURL, thumbnail: thumb, variant: variant)
                    LockScreenInstaller.restartWallpaperAgent()
                    message = "Installed. Open System Settings → Wallpaper and pick “Wave X · \(variant.name)” in the Wave X section, then it will play on the lock screen."
                } else {
                    message = "Saved to \(movieURL.path)"
                }
            } catch {
                message = error.localizedDescription
            }
            DispatchQueue.main.async {
                self?.running = false
                self?.status = message
                self?.refresh()
                self?.exporter = nil
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func remove(_ item: LockScreenInstaller.Installed) {
        do {
            try LockScreenInstaller.remove(assetID: item.id)
            LockScreenInstaller.restartWallpaperAgent()
            status = "Removed \(item.name)."
        } catch {
            status = error.localizedDescription
        }
        refresh()
    }
}

struct ExportView: View {
    @ObservedObject var model = SceneModel.shared
    @StateObject private var ctl = ExportController()

    var body: some View {
        Form {
            Section("Lock screen") {
                Text("The live desktop is drawn natively with Metal. The lock screen cannot host a live view, so Wave X renders a per‑variant HEVC movie with temporal sub‑layers and registers it with macOS's aerial wallpaper catalog. That catalog is private and unsupported by Apple: a macOS update may reset it, in which case just install again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !LockScreenInstaller.isCatalogPresent {
                    Label(LockScreenInstaller.InstallError.catalogMissing.localizedDescription, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Movie") {
                LabeledContent("Variant") { Text(model.selectedVariant.name) }
                Picker("Resolution", selection: $ctl.resolution) {
                    ForEach(ExportController.Resolution.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frame rate", selection: $ctl.fps) {
                    Text("60 fps (30 fps base layer)").tag(60)
                    Text("30 fps (15 fps base layer)").tag(30)
                }
                Picker("Length", selection: $ctl.duration) {
                    Text("30 s").tag(30.0)
                    Text("60 s").tag(60.0)
                    Text("2 min").tag(120.0)
                    Text("3 min").tag(180.0)
                }
                Text("Frames: \(Int(ctl.duration) * ctl.fps) · HEVC Main · 16 Mb/s")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Export & Install to Lock Screen") { ctl.exportAndInstall(model: model) }
                        .buttonStyle(.borderedProminent)
                        .disabled(ctl.running)
                    Button("Export Movie…") { ctl.exportToFile(model: model) }
                        .disabled(ctl.running)
                    if ctl.running {
                        Button("Cancel") { ctl.cancel() }
                    }
                    Spacer()
                    Button("Open Wallpaper Settings") { LockScreenInstaller.openWallpaperSettings() }
                }
                if ctl.running {
                    ProgressView(value: ctl.progress)
                }
                if !ctl.status.isEmpty {
                    Text(ctl.status)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Installed on the lock screen") {
                if ctl.installed.isEmpty {
                    Text("Nothing installed yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(ctl.installed) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            Button("Remove") { ctl.remove(item) }
                                .disabled(ctl.running)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { ctl.refresh() }
    }
}
