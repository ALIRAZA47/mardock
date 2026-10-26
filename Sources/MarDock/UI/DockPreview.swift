import AppKit
import MarDockCore
import SwiftUI

/// A live, interactive miniature of the dock for Settings and onboarding.
/// It runs the real engine and renderer over a colourful backdrop; when the
/// pointer isn't over it, a "ghost cursor" sweeps across to show off the
/// magnification.
struct DockPreviewCard: NSViewRepresentable {
    var settings: DockSettings

    func makeNSView(context: Context) -> DockPreviewView {
        DockPreviewView(settings: settings)
    }

    func updateNSView(_ view: DockPreviewView, context: Context) {
        view.update(settings: settings)
    }
}

@MainActor
final class DockPreviewView: NSView {
    private struct Sample {
        let id: String
        let name: String
        let image: NSImage
        var spec: DockItemSpec
    }

    private let backdrop = LayerHostView()
    private let dockView = DockView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
    private let engine = DockEngine()
    private let driver = FrameDriver()
    private var samples: [Sample] = []
    private var bitmaps: [String: CGImage] = [:]
    private var settings: DockSettings
    private var hoverPointer: DockPointer?
    private var lastHover: TimeInterval = 0
    private var demoClock: Double = 0
    private var lastDemoBounce = -1
    private var tracking: NSTrackingArea?
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(settings: DockSettings) {
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        wantsLayer = true
        layer?.masksToBounds = true

        backdrop.frame = bounds
        addSubview(backdrop)
        buildBackdrop()
        dockView.frame = bounds
        dockView.autoresizingMask = [.width, .height]
        addSubview(dockView)

        samples = Self.loadSamples()
        dockView.imageProvider = { [weak self] id, pixels in self?.bitmap(id: id, pixels: pixels) }
        dockView.nameProvider = { [weak self] id in self?.samples.first { $0.id == id }?.name ?? "" }
        driver.onFrame = { [weak self] dt in self?.step(dt) ?? false }
        engine.setItems(samples.map(\.spec), animated: false)
        update(settings: settings)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(settings: DockSettings) {
        self.settings = settings
        let style = ThemeStyle.style(for: settings.theme)
        var previewSettings = settings
        let count = Double(max(samples.count, 1))
        let fitting = (Double(bounds.width) - 80) / (count * 1.2)
        previewSettings.iconSize = min(settings.iconSize * 0.8, fitting, 52).rounded()
        previewSettings.iconSize = max(previewSettings.iconSize, 24)
        let metrics = DockMetrics.make(from: previewSettings, tallFloor: style.floor)
        engine.setMetrics(metrics)
        engine.bounceEnabled = settings.bounceOnLaunch && !reduceMotion
        engine.dimHiddenApps = settings.dimHiddenApps
        engine.labelsEnabled = settings.showLabels
        engine.speed = settings.animationSpeed
        engine.stripCenter = Double(bounds.width / 2)

        var configuration = DockView.Configuration()
        configuration.position = .bottom
        configuration.themeID = settings.theme
        configuration.style = style
        configuration.accent = ThemeStyle.accentColor(for: settings.accent, theme: style)
        configuration.indicatorStyle = settings.indicatorStyle
        configuration.reflections = settings.reflections
        configuration.metrics = metrics
        configuration.blending = .withinWindow
        configuration.reduceMotion = reduceMotion
        dockView.setConfiguration(configuration)
        driver.start()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        backdrop.frame = bounds
        layoutBackdrop()
        update(settings: settings)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            driver.attach(to: dockView)
            driver.start()
        } else {
            driver.detach()
        }
    }

    // MARK: Backdrop

    private let wallpaper = CAGradientLayer()
    private let blobs = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]

    private func buildBackdrop() {
        guard let root = backdrop.layer else { return }
        wallpaper.colors = [NSColor(hex: 0x1D2671).cgColor, NSColor(hex: 0x5B2A86).cgColor, NSColor(hex: 0xC33764).cgColor, NSColor(hex: 0xF7971E).cgColor]
        wallpaper.startPoint = CGPoint(x: 0, y: 1)
        wallpaper.endPoint = CGPoint(x: 1, y: 0)
        root.addSublayer(wallpaper)
        let colors: [NSColor] = [NSColor(hex: 0x30CFD0), NSColor(hex: 0xFFD86F), NSColor(hex: 0xFF6FD8)]
        for (blob, color) in zip(blobs, colors) {
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.colors = [color.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0).cgColor]
            root.addSublayer(blob)
        }
        layoutBackdrop()
    }

    private func layoutBackdrop() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wallpaper.frame = bounds
        let w = bounds.width
        let h = bounds.height
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(0.2, 0.25, 0.55), (0.62, 0.15, 0.45), (0.85, 0.7, 0.5)]
        for (blob, spot) in zip(blobs, spots) {
            let size = max(w, h) * spot.2
            blob.frame = CGRect(x: w * spot.0 - size / 2, y: h * spot.1 - size / 2, width: size, height: size)
        }
        CATransaction.commit()
    }

    // MARK: Animation

    private func step(_ dt: Double) -> Bool {
        guard window != nil else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if let hoverPointer {
            engine.setPointer(hoverPointer)
        } else if !reduceMotion && now - lastHover > 1.5 {
            runDemo(dt)
        } else {
            engine.setPointer(nil)
        }
        dockView.apply(engine.tick(dt))
        // The demo keeps the preview alive while it is on screen.
        return engine.isAnimating || (!reduceMotion && hoverPointer == nil)
    }

    private func runDemo(_ dt: Double) {
        demoClock += dt
        let cycle = 8.0
        let t = demoClock.truncatingRemainder(dividingBy: cycle)
        let frame = engine.lastFrame
        if t < 5, frame.shelfLength > 0 {
            let amplitude = frame.shelfLength / 2 - engine.metrics.slot * 0.6
            let u = engine.stripCenter + amplitude * sin(2 * Double.pi * t / 5 - Double.pi / 2) * 0.92
            engine.setPointer(DockPointer(u: u, v: engine.metrics.edgeGap + engine.metrics.shelfThickness / 2))
        } else {
            engine.setPointer(nil)
        }
        let cycleIndex = Int(demoClock / cycle)
        if t > 5.6, lastDemoBounce != cycleIndex, let pick = samples.filter({ $0.spec.kind == .app }).randomElement() {
            lastDemoBounce = cycleIndex
            engine.bounceOnce(pick.id)
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let p = dockView.dockPoint(for: convert(event.locationInWindow, from: nil))
        hoverPointer = engine.lastFrame.contains(u: p.u, v: p.v, slop: 2) ? p : nil
        lastHover = ProcessInfo.processInfo.systemUptime
        driver.start()
    }

    override func mouseExited(with event: NSEvent) {
        hoverPointer = nil
        lastHover = ProcessInfo.processInfo.systemUptime
        driver.start()
    }

    override func mouseDown(with event: NSEvent) {
        let p = dockView.dockPoint(for: convert(event.locationInWindow, from: nil))
        guard let item = engine.lastFrame.item(atU: p.u, v: p.v) else { return }
        engine.bounceOnce(item.id)
        if settings.clickRipple { dockView.ripple(for: item.id) }
        driver.start()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    // MARK: Samples

    private func bitmap(id: String, pixels: Int) -> CGImage? {
        let key = "\(id)#\(pixels)"
        if let cached = bitmaps[key] { return cached }
        guard let sample = samples.first(where: { $0.id == id }),
              let image = IconProvider.render(sample.image, pixels: pixels)
        else { return nil }
        bitmaps[key] = image
        return image
    }

    private static func loadSamples() -> [Sample] {
        let workspace = NSWorkspace.shared
        let apps: [(String, Bool, Bool)] = [
            ("com.apple.finder", true, false),
            ("com.apple.Safari", true, true),
            ("com.apple.mail", false, false),
            ("com.apple.MobileSMS", false, false),
            ("com.apple.Photos", false, false),
            ("com.apple.Music", true, false),
            ("com.apple.Notes", false, false),
            ("com.apple.iCal", false, false),
            ("com.apple.systempreferences", false, false),
        ]
        var samples: [Sample] = []
        for (identifier, running, active) in apps {
            guard let url = workspace.urlForApplication(withBundleIdentifier: identifier) else { continue }
            samples.append(Sample(
                id: "preview:" + identifier,
                name: AppCatalog.displayName(for: url),
                image: workspace.icon(forFile: url.path),
                spec: DockItemSpec(id: "preview:" + identifier, isRunning: running, isActive: active)
            ))
        }
        samples.append(Sample(id: "preview:separator", name: "", image: NSImage(), spec: DockItemSpec(id: "preview:separator", kind: .separator)))
        if let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            samples.append(Sample(
                id: "preview:terminal",
                name: AppCatalog.displayName(for: terminal),
                image: workspace.icon(forFile: terminal.path),
                spec: DockItemSpec(id: "preview:terminal", isRunning: true)
            ))
        }
        samples.append(Sample(
            id: "preview:trash",
            name: "Trash",
            image: NSImage(named: NSImage.trashEmptyName) ?? NSImage(),
            spec: DockItemSpec(id: "preview:trash", kind: .trash)
        ))
        return samples
    }
}
