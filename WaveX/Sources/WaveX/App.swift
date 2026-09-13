import SwiftUI
import AppKit
import Metal
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var wallpaper: WallpaperController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let device = MTLCreateSystemDefaultDevice() else {
            NSLog("Wave X: Metal is not available")
            return
        }
        let model = SceneModel.shared
        let controller = WallpaperController(model: model, device: device)
        wallpaper = controller

        // `WaveX --smoke-ui`: host every SwiftUI window for a few seconds and exit (crash smoke test).
        if CommandLine.arguments.contains("--smoke-ui") {
            let views: [(String, NSView)] = [
                ("gallery", NSHostingView(rootView: GalleryView())),
                ("settings", NSHostingView(rootView: SettingsView())),
                ("lockscreen", NSHostingView(rootView: ExportView())),
            ]
            var windows: [NSWindow] = []
            for (name, v) in views {
                let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                w.title = name
                w.contentView = v
                w.makeKeyAndOrderFront(nil)
                windows.append(w)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                print("smoke-ui ok: \(windows.count) windows, \(ThumbnailStore.shared.images.count) thumbnails rendered, selected=\(model.selectedVariant.name)")
                exit(0)
            }
        }

        model.$paused.dropFirst().receive(on: DispatchQueue.main).sink { _ in controller.updateRunning() }.store(in: &cancellables)
        model.$fpsLimit.dropFirst().receive(on: DispatchQueue.main).sink { controller.applyFpsLimit($0) }.store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct WaveXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = SceneModel.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        let args = CommandLine.arguments

        // `WaveX --export <variantID> <out.mov> [seconds] [width] [height] [fps]` renders a lock-screen
        // movie headlessly and exits (handy for scripting and for verifying the encoder).
        if let i = args.firstIndex(of: "--export"), i + 2 < args.count {
            let variant = VariantCatalog.variant(id: args[i + 1]) ?? VariantCatalog.variant(id: VariantCatalog.defaultID)!
            var opts = MovieExporter.Options()
            opts.duration = i + 3 < args.count ? Double(args[i + 3]) ?? 120 : 120
            opts.width = i + 4 < args.count ? Int(args[i + 4]) ?? 3840 : 3840
            opts.height = i + 5 < args.count ? Int(args[i + 5]) ?? 2160 : 2160
            opts.fps = i + 6 < args.count ? Int(args[i + 6]) ?? 60 : 60
            let url = URL(fileURLWithPath: args[i + 2])
            let snap = SceneModel.shared.snapshot(for: variant)
            let started = Date()
            do {
                try MovieExporter().export(snapshot: snap, options: opts, to: url) { _ in }
                try MovieExporter.writeThumbnail(snapshot: snap, to: url.deletingPathExtension().appendingPathExtension("png"))
                print(String(format: "exported %@ in %.1fs", url.path, Date().timeIntervalSince(started)))
                exit(0)
            } catch {
                FileHandle.standardError.write("export failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }

        // `WaveX --install <variantID> <movie.mov> [preview.png]` registers an exported movie with the
        // aerial catalog and exits. Honours WAVEX_AERIALS_ROOT for testing against a copy of the catalog.
        if let i = args.firstIndex(of: "--install"), i + 2 < args.count {
            let variant = VariantCatalog.variant(id: args[i + 1]) ?? VariantCatalog.variant(id: VariantCatalog.defaultID)!
            let movie = URL(fileURLWithPath: args[i + 2])
            let png = i + 3 < args.count ? URL(fileURLWithPath: args[i + 3]) : nil
            do {
                let id = try LockScreenInstaller.install(movie: movie, thumbnail: png, variant: variant)
                print("installed asset \(id) into \(LockScreenInstaller.root.path)")
                print("installed now:", LockScreenInstaller.installed().map { "\($0.name) [\($0.id)]" })
                exit(0)
            } catch {
                FileHandle.standardError.write("install failed: \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        if args.contains("--uninstall-all") {
            do { try LockScreenInstaller.removeAll(); print("removed all Wave X assets"); exit(0) } catch { print("\(error)"); exit(1) }
        }

        // `WaveX --render-icon out.png` renders a square still and exits (used by the build script).
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            let url = URL(fileURLWithPath: args[i + 1])
            let variant = VariantCatalog.variant(id: VariantCatalog.defaultID)!
            let snap = SceneModel.shared.snapshot(for: variant)
            do {
                try MovieExporter.writeThumbnail(snapshot: snap, width: 1024, height: 1024, to: url)
                exit(0)
            } catch {
                FileHandle.standardError.write("icon render failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        MenuBarExtra("Wave X", systemImage: "water.waves") {
            Text(model.selectedVariant.name)
            Divider()
            Button("Variants…") { show("gallery") }
                .keyboardShortcut("1")
            Button("Settings…") { show("settings") }
                .keyboardShortcut(",")
            Button("Lock Screen…") { show("lockscreen") }
                .keyboardShortcut("2")
            Divider()
            Toggle("Pause Wallpaper", isOn: $model.paused)
            Divider()
            Button("Quit Wave X") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }

        Window("Wave X — Variants", id: "gallery") {
            GalleryView()
        }
        .defaultSize(width: 920, height: 640)

        Window("Wave X — Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 620, height: 720)

        Window("Wave X — Lock Screen", id: "lockscreen") {
            ExportView()
        }
        .defaultSize(width: 620, height: 600)
    }
}
