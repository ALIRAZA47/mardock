import AppKit

/// The borderless, non-activating window the dock lives in. It spans the
/// dock's whole screen edge; clicks only reach it over the dock itself (see
/// `DockController.updateMouseIgnoring`), so it never steals clicks from the
/// apps underneath and never takes focus away from them.
final class DockPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        setAccessibilityLabel("MarDock")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func setShowsInFullScreen(_ show: Bool) {
        var behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if show { behavior.insert(.fullScreenAuxiliary) }
        collectionBehavior = behavior
    }
}

/// A view that hosts raw Core Animation layers and is invisible to the mouse.
final class LayerHostView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let host = CALayer()
        host.masksToBounds = false
        layer = host
        wantsLayer = true
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
