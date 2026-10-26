import AppKit
import Combine
import MarDockCore

/// Owns the dock window and wires everything together: settings and app
/// state flow into the engine, the engine's frames flow into the view, and
/// the view's events flow back out as actions.
@MainActor
final class DockController: NSObject {
    let engine = DockEngine()
    let dockView = DockView(frame: NSRect(x: 0, y: 0, width: 800, height: 160))
    private let panel = DockPanel()
    private let driver = FrameDriver()
    private let mouse = MouseTracker()

    private let settings: SettingsStore
    private let pins: PinStore
    private let running: RunningAppsMonitor
    private let icons: IconProvider
    private let actions: AppActions
    private let systemDock: SystemDockManager
    weak var coordinator: AppCoordinator?

    private(set) var entries: [DockEntry] = []
    private var entriesByID: [String: DockEntry] = [:]
    private var screen: NSScreen?
    private(set) var isVisible = true
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    private var autoHide = AutoHideLogic()
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    // Interaction state.
    private var pressed: (id: String, event: NSEvent)?
    private var dragSourceID: String?
    private var dragDropHandled = false
    private var externalDropActive = false
    private var menuIsOpen = false
    private var pointerAtEdge = false
    private var pointerInDock = false
    private var windowOverlaps = false
    private var autoHideTimer: Timer?
    private var overlapTimer: Timer?
    private var followCandidate: (display: CGDirectDisplayID, since: TimeInterval)?
    private var followTimer: Timer?

    init(settings: SettingsStore, pins: PinStore, running: RunningAppsMonitor, icons: IconProvider, actions: AppActions, systemDock: SystemDockManager) {
        self.settings = settings
        self.pins = pins
        self.running = running
        self.icons = icons
        self.actions = actions
        self.systemDock = systemDock
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        panel.contentView = dockView
        dockView.delegate = self
        dockView.imageProvider = { [weak self] id, pixels in self?.bitmap(for: id, pixels: pixels) }
        dockView.nameProvider = { [weak self] id in self?.name(for: id) ?? "" }
        driver.onFrame = { [weak self] dt in self?.step(dt) ?? false }
        mouse.onMove = { [weak self] point in self?.pointerMoved(to: point) }

        settings.$settings
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        Publishers.Merge3(
            pins.$pins.map { _ in () },
            running.$snapshots.map { _ in () },
            running.$launching.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuild(animated: true) }
        .store(in: &cancellables)

        listen(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { controller in
            controller.updateGeometry(force: true)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        listen(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { controller in
            controller.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            controller.increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            controller.applySettings()
        }
        listen(workspace, NSWorkspace.didActivateApplicationNotification) { controller in
            controller.checkOverlap()
        }
        listen(workspace, NSWorkspace.activeSpaceDidChangeNotification) { controller in
            controller.checkOverlap()
            controller.mouse.refresh()
        }

        applySettings()
        rebuild(animated: false)
        panel.orderFrontRegardless()
        // The display link follows the screen the view is on, so create it
        // once the window is up.
        driver.attach(to: dockView)
        mouse.start()
        renderNow()
    }

    private func listen(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (DockController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }

    /// Stops following the real pointer (used by screenshot demos).
    func stopPointerTracking() {
        mouse.stop()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            panel.orderFrontRegardless()
            engine.setRevealed(false, animated: false)
            engine.setRevealed(true, animated: true)
        } else {
            panel.orderOut(nil)
        }
        pointerInDock = false
        updateMouseIgnoring()
        kick()
    }

    // MARK: - Settings & layout

    func applySettings() {
        let s = settings.settings
        engine.bounceEnabled = s.bounceOnLaunch && !reduceMotion
        engine.dimHiddenApps = s.dimHiddenApps
        engine.labelsEnabled = s.showLabels
        engine.speed = reduceMotion ? max(s.animationSpeed, 1.5) : s.animationSpeed
        autoHide.mode = s.autoHide
        autoHide.revealDelay = s.revealDelay
        updateGeometry(force: true)
        panel.setShowsInFullScreen(s.showInFullScreen)
        updateOverlapPolling()
        rebuild(animated: true)
        reevaluateAutoHide()
    }

    /// Recomputes metrics (shrinking icons if the dock wouldn't fit on the
    /// screen) and pushes them to the engine, the view and the window.
    private func updateGeometry(force: Bool = false) {
        let s = settings.settings
        let style = ThemeStyle.style(for: s.theme)
        let floor = style.floor && s.position == .bottom
        var available = 0.0
        if let target = resolveScreen() {
            let visible = target.visibleFrame
            available = Double(s.position.isVertical ? visible.height : target.frame.width) - 24
        }
        let separators = entries.filter { $0.kind == .separator }.count
        let metrics = DockMetrics.fitting(s, tallFloor: floor, tiles: entries.count - separators, separators: separators, available: available)
        guard force || metrics != engine.metrics else { return }
        engine.setMetrics(metrics)

        var configuration = DockView.Configuration()
        configuration.position = s.position
        configuration.themeID = s.theme
        configuration.style = style
        configuration.accent = ThemeStyle.accentColor(for: s.accent, theme: style)
        configuration.indicatorStyle = s.indicatorStyle
        configuration.reflections = s.reflections
        configuration.metrics = metrics
        configuration.blending = .behindWindow
        configuration.reduceMotion = reduceMotion
        configuration.increaseContrast = increaseContrast
        dockView.setConfiguration(configuration)
        updatePanelFrame()
    }

    private func resolveScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return nil }
        if settings.settings.display == .followMouse, let current = screen?.displayID,
           let match = screens.first(where: { $0.displayID == current }) {
            return match
        }
        return primary
    }

    func updatePanelFrame() {
        guard let target = resolveScreen() else { return }
        screen = target
        let position = settings.settings.position
        let depth = CGFloat(engine.metrics.requiredDepth).rounded(.up)
        let full = target.frame
        let visible = target.visibleFrame
        let menuBar = max(0, full.maxY - visible.maxY)
        let rect: NSRect
        switch position {
        case .bottom:
            // Sits on the screen edge, or just above the macOS Dock if that is showing.
            rect = NSRect(x: full.minX, y: visible.minY, width: full.width, height: depth)
        case .left:
            rect = NSRect(x: visible.minX, y: full.minY, width: depth, height: full.height - menuBar)
        case .right:
            rect = NSRect(x: visible.maxX - depth, y: full.minY, width: depth, height: full.height - menuBar)
        }
        if panel.frame != rect {
            panel.setFrame(rect, display: false)
        }
        dockView.frame = NSRect(origin: .zero, size: rect.size)
        engine.stripCenter = Double(position.isVertical ? rect.height / 2 : rect.width / 2)
        renderNow()
    }

    // MARK: - Content

    func rebuild(animated: Bool) {
        let s = settings.settings
        let built = DockContentBuilder.build(
            pins: pins.pins,
            running: running.snapshots,
            launching: running.launching,
            showRunningApps: s.showRunningApps,
            showTrash: s.showTrash
        )
        entries = built
        entriesByID = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        updateGeometry()
        engine.setItems(built.map(\.spec), animated: animated)
        icons.retain(only: Set(built.map(\.id)))
        dockView.updateAccessibility(items: built.filter { $0.kind != .separator }.map { ($0.id, name(for: $0.id)) })
        kick()
    }

    func name(for id: String) -> String {
        guard let entry = entriesByID[id] else { return "" }
        switch entry.kind {
        case .finder: return "Finder"
        case let .pinned(pin): return entry.running?.name ?? pin.name
        case .running: return entry.running?.name ?? "App"
        case .trash: return "Trash"
        case .separator: return ""
        }
    }

    private func bitmap(for id: String, pixels: Int) -> CGImage? {
        guard let entry = entriesByID[id] else { return nil }
        return icons.bitmap(for: entry, running: running.runningApp(for: id), pixels: pixels)
    }

    // MARK: - Animation

    private func step(_ dt: Double) -> Bool {
        dockView.apply(engine.tick(dt))
        return engine.isAnimating
    }

    private func kick() {
        driver.start()
    }

    private func renderNow() {
        dockView.apply(engine.tick(0))
        kick()
    }

    // MARK: - Pointer

    private func pointerMoved(to point: NSPoint) {
        guard isVisible else { return }
        if settings.settings.display == .followMouse {
            considerFollowing(point)
        }
        let local = panel.convertPoint(fromScreen: point)
        let p = dockView.dockPoint(for: local)
        let frame = engine.lastFrame
        let onScreen = screen.map { NSMouseInRect(point, $0.frame, false) } ?? false
        let inside = onScreen && engine.isRevealed && frame.contains(u: p.u, v: p.v, slop: 1)
        let reach = engine.metrics.slot * 1.5
        pointerInDock = inside
        pointerAtEdge = onScreen && isAtEdge(point, of: screen) && p.u >= frame.shelfStart - reach && p.u <= frame.shelfEnd + reach

        // Only wake the renderer when the dock is actually affected, so moving
        // the mouse around the rest of the screen costs (almost) nothing.
        let wasTracking = engine.isPointerInside
        if inside || pressed != nil {
            engine.setPointer(p)
        } else if wasTracking {
            engine.setPointer(nil)
        }
        updateMouseIgnoring()
        reevaluateAutoHide()
        if inside || wasTracking || pressed != nil {
            kick()
        }
    }

    private func isAtEdge(_ point: NSPoint, of screen: NSScreen?) -> Bool {
        guard let frame = screen?.frame else { return false }
        switch settings.settings.position {
        case .bottom: return point.y <= frame.minY + 1.5
        case .left: return point.x <= frame.minX + 1.5
        case .right: return point.x >= frame.maxX - 1.5
        }
    }

    /// The window only accepts clicks while the pointer is over the dock, so
    /// it never blocks the apps underneath.
    private func updateMouseIgnoring() {
        let interactive = isVisible && engine.isRevealed
            && (pointerInDock || pressed != nil || dragSourceID != nil || externalDropActive)
        if panel.ignoresMouseEvents == interactive {
            panel.ignoresMouseEvents = !interactive
        }
    }

    private func considerFollowing(_ point: NSPoint) {
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              let display = target.displayID, display != screen?.displayID, isAtEdge(point, of: target)
        else {
            followCandidate = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let candidate = followCandidate, candidate.display == display {
            if now - candidate.since >= 0.35 {
                followCandidate = nil
                screen = target
                updateGeometry(force: true)
                engine.setRevealed(false, animated: false)
                engine.setRevealed(true, animated: true)
                kick()
            }
        } else {
            followCandidate = (display, now)
            followTimer?.invalidate()
            followTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouse.refresh() }
            }
        }
    }

    // MARK: - Auto-hide

    private var holdOpen: Bool {
        menuIsOpen || pressed != nil || dragSourceID != nil || externalDropActive
    }

    private func reevaluateAutoHide() {
        let shown = autoHide.update(.init(
            now: ProcessInfo.processInfo.systemUptime,
            pointerAtEdge: pointerAtEdge,
            pointerInDock: pointerInDock,
            windowOverlaps: windowOverlaps,
            holdOpen: holdOpen
        ))
        if shown != engine.isRevealed {
            engine.setRevealed(shown, animated: true)
            if !shown {
                engine.setPointer(nil)
                pointerInDock = false
            }
            updateMouseIgnoring()
            kick()
            if shown {
                mouse.refresh()
            }
        }
        if autoHide.hasPendingTransition {
            guard autoHideTimer == nil else { return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluateAutoHide() }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoHideTimer = timer
        } else {
            autoHideTimer?.invalidate()
            autoHideTimer = nil
        }
    }

    private func updateOverlapPolling() {
        overlapTimer?.invalidate()
        overlapTimer = nil
        guard settings.settings.autoHide == .smart else {
            windowOverlaps = false
            return
        }
        checkOverlap()
        let timer = Timer(timeInterval: 0.6, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOverlap() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        overlapTimer = timer
    }

    private func checkOverlap() {
        guard settings.settings.autoHide == .smart, isVisible else { return }
        let frame = engine.lastFrame
        let m = engine.metrics
        let size = panel.frame.size
        let axis = DockAxis(position: settings.settings.position, width: Double(size.width), height: Double(size.height))
        let r = axis.rect(u0: frame.shelfStart, u1: frame.shelfEnd, v0: 0, v1: m.edgeGap + m.shelfThickness)
        let rect = NSRect(x: panel.frame.minX + r.x, y: panel.frame.minY + r.y, width: r.width, height: r.height)
        let overlaps = WindowOverlapDetector.frontmostAppOverlaps(rect)
        if overlaps != windowOverlaps {
            windowOverlaps = overlaps
            reevaluateAutoHide()
        }
    }

    // MARK: - Actions

    func activate(_ entry: DockEntry, modifiers: NSEvent.ModifierFlags) {
        switch entry.kind {
        case .separator:
            return
        case .trash:
            ripple(entry.id)
            actions.openTrash()
            return
        default:
            break
        }
        let app = running.runningApp(for: entry.id)
        if modifiers.contains(.command) {
            actions.revealInFinder(entry, running: app)
            return
        }
        ripple(entry.id)
        if let app {
            if modifiers.contains(.option) {
                app.isHidden ? actions.unhide(app) : actions.hide(app)
                return
            }
            if app.isActive && settings.settings.clickToHide && entry.kind != .finder {
                actions.hide(app)
                return
            }
            actions.open(entry, running: app) { _ in }
        } else {
            let id = entry.id
            running.noteLaunchRequested(id)
            actions.open(entry, running: nil) { [weak self] succeeded in
                guard !succeeded else { return }
                self?.running.noteLaunchFailed(id)
                NSSound.beep()
            }
        }
    }

    private func ripple(_ id: String) {
        guard settings.settings.clickRipple else { return }
        dockView.ripple(for: id)
    }

    func quit(_ app: NSRunningApplication, force: Bool) {
        Task {
            do {
                try await actions.quit(app, force: force)
            } catch {
                appLog.error("Quit failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    func setHidden(_ app: NSRunningApplication, _ hidden: Bool) {
        actions.setHidden(app, hidden)
    }

    func unpin(_ entry: DockEntry) {
        pins.unpin(entry.id)
        rebuild(animated: true)
    }

    func keepInDock(_ entry: DockEntry) {
        guard let pin = pinnable(entry) else { return }
        pins.pin(pin)
        rebuild(animated: true)
    }

    func pinnable(_ entry: DockEntry) -> PinnedApp? {
        switch entry.kind {
        case let .pinned(pin):
            return pin
        case .running:
            guard let app = running.runningApp(for: entry.id), let identifier = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return PinnedApp(bundleIdentifier: identifier, path: url.path, name: app.localizedName ?? "")
        default:
            return nil
        }
    }

    func runningApp(for entry: DockEntry) -> NSRunningApplication? {
        running.runningApp(for: entry.id)
    }

    // MARK: - Menus

    private func showMenu(_ menu: NSMenu, at point: NSPoint) {
        menuIsOpen = true
        engine.setPressed(nil)
        reevaluateAutoHide()
        _ = menu.popUp(positioning: nil, at: point, in: dockView)
        menuIsOpen = false
        mouse.refresh()
        reevaluateAutoHide()
        kick()
    }

    // MARK: - Dragging helpers

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
    }

    /// Index among pinned apps (excluding `excluded`) where a drop at `u` lands.
    private func pinInsertionIndex(forU u: Double, excluding excluded: String?) -> Int {
        let pinned = entries.filter { $0.isPinned && $0.id != excluded }.map(\.id)
        return engine.lastFrame.insertionIndex(u: u, among: pinned)
    }

    /// Index among all tiles where the drop gap should open.
    private func gapIndex(forU u: Double, excluding excluded: String?) -> Int {
        let pinned = entries.filter { $0.isPinned && $0.id != excluded }
        let k = engine.lastFrame.insertionIndex(u: u, among: pinned.map(\.id))
        if k < pinned.count, let index = entries.firstIndex(where: { $0.id == pinned[k].id }) {
            return index
        }
        if let last = pinned.last, let index = entries.firstIndex(where: { $0.id == last.id }) {
            return index + 1
        }
        return 1
    }

    private func isRemovalPoint(_ screenPoint: NSPoint) -> Bool {
        let p = dockView.dockPoint(for: panel.convertPoint(fromScreen: screenPoint))
        return !engine.lastFrame.contains(u: p.u, v: p.v, slop: engine.metrics.iconSize * 0.6)
    }

    private func canRemove(_ id: String?) -> Bool {
        guard let id, let entry = entriesByID[id] else { return false }
        return entry.isPinned
    }
}

// MARK: - DockViewDelegate

extension DockController: DockViewDelegate {
    func dockView(_ view: DockView, mouseDown event: NSEvent) {
        let p = view.dockPoint(for: view.convert(event.locationInWindow, from: nil))
        guard let item = engine.lastFrame.item(atU: p.u, v: p.v) else {
            pressed = nil
            return
        }
        pressed = (item.id, event)
        engine.setPressed(item.id)
        kick()
    }

    func dockView(_ view: DockView, mouseDragged event: NSEvent) {
        guard let pressed, dragSourceID == nil else { return }
        let start = pressed.event.locationInWindow
        let now = event.locationInWindow
        guard hypot(now.x - start.x, now.y - start.y) > 6 else { return }
        beginTileDrag(id: pressed.id, event: event)
    }

    func dockView(_ view: DockView, mouseUp event: NSEvent) {
        let released = pressed
        pressed = nil
        engine.setPressed(nil)
        defer {
            updateMouseIgnoring()
            kick()
        }
        guard let released, dragSourceID == nil else { return }
        let p = view.dockPoint(for: view.convert(event.locationInWindow, from: nil))
        guard engine.lastFrame.item(atU: p.u, v: p.v)?.id == released.id, let entry = entriesByID[released.id] else { return }
        activate(entry, modifiers: event.modifierFlags)
    }

    func dockView(_ view: DockView, rightMouseDown event: NSEvent) {
        let local = view.convert(event.locationInWindow, from: nil)
        let p = view.dockPoint(for: local)
        let menu: NSMenu
        if let item = engine.lastFrame.item(atU: p.u, v: p.v), let entry = entriesByID[item.id] {
            menu = DockMenus.menu(for: entry, controller: self)
        } else {
            menu = DockMenus.dockMenu(controller: self, settings: settings, coordinator: coordinator)
        }
        showMenu(menu, at: local)
    }

    func dockViewPointerMoved(_ view: DockView) {
        pointerMoved(to: NSEvent.mouseLocation)
    }

    func dockView(_ view: DockView, accessibilityPress id: String) {
        guard let entry = entriesByID[id] else { return }
        activate(entry, modifiers: [])
    }

    private func beginTileDrag(id: String, event: NSEvent) {
        guard let entry = entriesByID[id], entry.isApp, entry.kind != .finder,
              let rect = dockView.iconRect(for: id), let index = entries.firstIndex(where: { $0.id == id })
        else { return }
        let item = NSPasteboardItem()
        item.setString(id, forType: .mardockTile)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(rect, contents: icons.image(for: entry, running: running.runningApp(for: id)))

        dragSourceID = id
        dragDropHandled = false
        engine.setPressed(nil)
        engine.setDraggedItem(id, animated: false)
        engine.setDropGap(at: index, animated: false)
        let session = dockView.beginDraggingSession(with: [dragging], event: event, source: dockView)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        kick()
    }

    func dockView(_ view: DockView, dragSession session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        let removing = isRemovalPoint(screenPoint) && canRemove(dragSourceID)
        session.animatesToStartingPositionsOnCancelOrFail = !removing
        if isRemovalPoint(screenPoint) {
            engine.setDropGap(at: nil)
        }
        pointerMoved(to: screenPoint)
    }

    func dockView(_ view: DockView, dragSessionEndedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard let id = dragSourceID else { return }
        defer {
            dragSourceID = nil
            updateMouseIgnoring()
            mouse.refresh()
            kick()
        }
        if dragDropHandled { return }
        if operation == [] && isRemovalPoint(screenPoint) && canRemove(id) {
            let image = bitmap(for: id, pixels: dockView.pixelSize)
            PoofEffect.show(at: screenPoint, icon: image, size: CGFloat(engine.metrics.iconSize), reduceMotion: reduceMotion)
            pins.unpin(id)
            rebuild(animated: true)
            engine.setDropGap(at: nil)
            engine.setDraggedItem(nil)
        } else {
            // Cancelled: the drag image slides home, then the tile reappears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.dragSourceID == nil else { return }
                    self.engine.commitDrop()
                    self.kick()
                }
            }
        }
    }

    func dockView(_ view: DockView, draggingUpdated info: NSDraggingInfo) -> NSDragOperation {
        let p = view.dockPoint(for: view.convert(info.draggingLocation, from: nil))
        let pasteboard = info.draggingPasteboard
        engine.setPointer(p)
        defer { kick() }

        if let id = pasteboard.string(forType: .mardockTile), id == dragSourceID {
            if engine.lastFrame.contains(u: p.u, v: p.v, slop: engine.metrics.iconSize * 0.6) {
                engine.setDropGap(at: gapIndex(forU: p.u, excluding: id))
            } else {
                engine.setDropGap(at: nil)
            }
            return .move
        }

        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return [] }
        externalDropActive = true
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "app" }) {
            engine.setHighlighted(nil)
            engine.setDropGap(at: gapIndex(forU: p.u, excluding: nil))
            return .copy
        }
        engine.setDropGap(at: nil)
        if let item = engine.lastFrame.item(atU: p.u, v: p.v), let entry = entriesByID[item.id], entry.isApp {
            engine.setHighlighted(item.id)
            return .copy
        }
        engine.setHighlighted(nil)
        return []
    }

    func dockView(_ view: DockView, draggingEnded info: NSDraggingInfo?) {
        externalDropActive = false
        engine.setHighlighted(nil)
        if !dragDropHandled {
            engine.setDropGap(at: nil)
        }
        mouse.refresh()
        kick()
    }

    func dockView(_ view: DockView, performDrop info: NSDraggingInfo) -> Bool {
        let p = view.dockPoint(for: view.convert(info.draggingLocation, from: nil))
        let pasteboard = info.draggingPasteboard
        defer {
            externalDropActive = false
            engine.setHighlighted(nil)
            kick()
        }

        if let id = pasteboard.string(forType: .mardockTile), id == dragSourceID, let entry = entriesByID[id] {
            guard engine.lastFrame.contains(u: p.u, v: p.v, slop: engine.metrics.iconSize * 0.6),
                  let pin = pinnable(entry)
            else { return false }
            pins.pin(pin, at: pinInsertionIndex(forU: p.u, excluding: id))
            dragDropHandled = true
            rebuild(animated: true)
            engine.commitDrop(insertedID: id)
            return true
        }

        let urls = fileURLs(from: pasteboard)
        guard !urls.isEmpty else { return false }
        if urls.allSatisfy({ $0.pathExtension.lowercased() == "app" }) {
            var index = pinInsertionIndex(forU: p.u, excluding: nil)
            var inserted: String?
            for url in urls.prefix(20) {
                guard let app = AppCatalog.pinnedApp(url: url) else { continue }
                pins.pin(app, at: index)
                index += 1
                inserted = app.id
            }
            rebuild(animated: true)
            engine.commitDrop(insertedID: inserted)
            return inserted != nil
        }
        if let item = engine.lastFrame.item(atU: p.u, v: p.v), let entry = entriesByID[item.id], entry.isApp {
            actions.open(documents: Array(urls.prefix(100)), with: entry, running: running.runningApp(for: entry.id))
            ripple(item.id)
            return true
        }
        return false
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
