import AppKit
import MetalKit

/// MTKView that drives a `WaveRenderer` from the display link at the screen's native refresh rate.
final class WaveMetalView: MTKView, MTKViewDelegate {
    private let renderer: WaveRenderer
    private let model: SceneModel
    private var lastFrameTime: CFTimeInterval = 0
    private var frameAccumulator: Double = 0
    var fpsLimit: Int = 0

    init(frame: CGRect, device: MTLDevice, model: SceneModel) throws {
        self.model = model
        self.renderer = try WaveRenderer(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        sampleCount = 4
        framebufferOnly = true
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        layer?.isOpaque = true
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime == 0 ? 1.0 / 60.0 : now - lastFrameTime
        lastFrameTime = now

        if fpsLimit > 0 {
            // Software cap below the display rate: skip frames but keep the clock honest.
            frameAccumulator += dt
            let step = 1.0 / Double(fpsLimit)
            if frameAccumulator < step { return }
            frameAccumulator = min(frameAccumulator - step, step)
        }

        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        renderer.advance(dt: dt)
        renderer.encodeFrame(pass: pass, drawableSize: view.drawableSize, snapshot: model.snapshot(),
                             after: { cmd in cmd.present(drawable) })
    }
}

/// Borderless, click-through window pinned at the desktop level on every Space of one screen.
final class DesktopWindow: NSWindow {
    let waveView: WaveMetalView
    let targetScreen: NSScreen

    init(screen: NSScreen, device: MTLDevice, model: SceneModel) throws {
        targetScreen = screen
        waveView = try WaveMetalView(frame: CGRect(origin: .zero, size: screen.frame.size), device: device, model: model)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)

        // Just above the system wallpaper, below Finder's desktop icons.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        displaysWhenScreenProfileChanges = true
        waveView.preferredFramesPerSecond = screen.maximumFramesPerSecond
        contentView = waveView
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func applyFpsLimit(_ limit: Int) {
        let native = targetScreen.maximumFramesPerSecond
        if limit > 0 && limit < native {
            waveView.preferredFramesPerSecond = limit
            waveView.fpsLimit = 0
        } else {
            waveView.preferredFramesPerSecond = native
            waveView.fpsLimit = 0
        }
    }

    func setRendering(_ on: Bool) {
        waveView.isPaused = !on
    }
}

/// Keeps one DesktopWindow per attached screen and pauses rendering when nobody can see it.
final class WallpaperController {
    private let model: SceneModel
    private let device: MTLDevice
    private var windows: [DesktopWindow] = []
    private var locked = false
    private var screensAsleep = false
    private var screensaverRunning = false
    private var tokens: [Any] = []

    init(model: SceneModel, device: MTLDevice) {
        self.model = model
        self.device = device
        rebuild()

        let nc = NotificationCenter.default
        let dnc = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter

        tokens.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.rebuild()
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.updateRunning()
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.updateRunning()
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main) { [weak self] _ in
            self?.screensaverRunning = true; self?.updateRunning()
        })
        tokens.append(dnc.addObserver(forName: Notification.Name("com.apple.screensaver.didstop"), object: nil, queue: .main) { [weak self] _ in
            self?.screensaverRunning = false; self?.updateRunning()
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = true; self?.updateRunning()
        })
        tokens.append(ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensAsleep = false; self?.updateRunning()
        })
        tokens.append(nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] note in
            guard let w = note.object as? DesktopWindow else { return }
            self?.updateRunning(window: w)
        })
    }

    func rebuild() {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        for screen in NSScreen.screens {
            do {
                let w = try DesktopWindow(screen: screen, device: device, model: model)
                w.applyFpsLimit(model.fpsLimit)
                windows.append(w)
            } catch {
                NSLog("Wave X: failed to create wallpaper window: \(error)")
            }
        }
        updateRunning()
    }

    func applyFpsLimit(_ limit: Int) {
        windows.forEach { $0.applyFpsLimit(limit) }
    }

    func updateRunning(window: DesktopWindow? = nil) {
        let globallyOff = model.paused || locked || screensAsleep || screensaverRunning
        for w in windows where window == nil || w === window {
            let visible = w.occlusionState.contains(.visible)
            w.setRendering(!globallyOff && visible)
        }
    }
}
