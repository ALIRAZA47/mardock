import AppKit
import QuartzCore

/// Drives animation at the display's refresh rate (120 Hz on ProMotion) and
/// stops completely when nothing moves, so an idle dock costs no CPU.
@MainActor
final class FrameDriver: NSObject {
    /// Called every frame with the elapsed time; return false to stop.
    var onFrame: ((Double) -> Bool)?
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    var isRunning: Bool { link.map { !$0.isPaused } ?? false }

    func start() {
        guard let link, link.isPaused else { return }
        lastTimestamp = 0
        link.isPaused = false
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? max(link.duration, 1.0 / 120) : min(max(now - lastTimestamp, 0), 1.0 / 15)
        lastTimestamp = now
        if onFrame?(dt) != true {
            link.isPaused = true
            lastTimestamp = 0
        }
    }
}

/// Reports the pointer position wherever it is on screen. Uses event
/// monitors (mouse movement needs no special permission) plus a slow poll as
/// a safety net, so the dock reacts even while other apps own the pointer.
@MainActor
final class MouseTracker {
    var onMove: ((NSPoint) -> Void)?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pollTimer: Timer?
    private var lastPoint = NSPoint(x: -1, y: -1)

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(force: false) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.emit(force: false) }
            return event
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(force: false) }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        pollTimer?.invalidate()
        globalMonitor = nil
        localMonitor = nil
        pollTimer = nil
    }

    /// Re-sends the current position (after layout changes, for instance).
    func refresh() { emit(force: true) }

    private func emit(force: Bool) {
        let point = NSEvent.mouseLocation
        guard force || point != lastPoint else { return }
        lastPoint = point
        onMove?(point)
    }
}
