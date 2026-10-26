import AppKit
import Combine
import MarDockCore
import UniformTypeIdentifiers

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
    private let recents: RecentAppsStore
    private let customIcons: CustomIconStore
    private let themes: ThemeStore
    private let folders: FolderStacks
    private let stackPanel = StackPanel()
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
    private var sharePickerOpen = false
    private var pointerAtEdge = false
    private var pointerInDock = false
    private var windowOverlaps = false
    private var autoHideTimer: Timer?
    private var overlapTimer: Timer?
    private var followCandidate: (display: CGDirectDisplayID, since: TimeInterval)?
    private var followTimer: Timer?

    init(
        settings: SettingsStore, pins: PinStore, recents: RecentAppsStore, customIcons: CustomIconStore, themes: ThemeStore,
        folders: FolderStacks, running: RunningAppsMonitor, icons: IconProvider, actions: AppActions, systemDock: SystemDockManager
    ) {
        self.settings = settings
        self.pins = pins
        self.recents = recents
        self.customIcons = customIcons
        self.themes = themes
        self.folders = folders
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
        // A folder's newest files changed: redraw its tile.
        folders.$revision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshFolderIcons() }
            .store(in: &cancellables)
        stackPanel.onClose = { [weak self] in
            guard let self else { return }
            self.reevaluateAutoHide()
            self.mouse.refresh()
        }
        // Editing the theme in use restyles the dock as you go.
        themes.$custom
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applySettings() }
            .store(in: &cancellables)
        Publishers.Merge4(
            pins.$items.map { _ in () },
            recents.$recents.map { _ in () },
            running.$snapshots.map { _ in () },
            running.$launching.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.rebuild(animated: true) }
        .store(in: &cancellables)
        customIcons.$revision
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.icons.invalidate()
                self.dockView.reloadImages()
                self.renderNow()
            }
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
        let recipe = themes.recipe(for: s)
        let style = ThemeStyle(recipe: recipe)
        let floor = style.floor && s.position == .bottom
        var available = 0.0
        if let target = resolveScreen() {
            let visible = target.visibleFrame
            available = Double(s.position.isVertical ? visible.height : target.frame.width) - 24
        }
        let separators = entries.filter { $0.spec.kind.isNarrow }.count
        let metrics = DockMetrics.fitting(s, tallFloor: floor, tiles: entries.count - separators, separators: separators, available: available)
        guard force || metrics != engine.metrics else { return }
        engine.setMetrics(metrics)

        var configuration = DockView.Configuration()
        configuration.position = s.position
        configuration.themeKey = ThemeStyle.key(for: recipe)
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
            items: pins.items,
            running: running.snapshots,
            recents: recents.recents.apps,
            launching: running.launching,
            showRunningApps: s.showRunningApps,
            recentLimit: s.showRecentApps ? s.recentAppsCount : 0,
            showTrash: s.showTrash
        )
        entries = built
        entriesByID = Dictionary(built.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        updateGeometry()
        engine.setItems(built.map(\.spec), animated: animated)
        icons.retain(only: Set(built.map(\.id)))
        folders.retain(only: Set(built.map(\.id)))
        dockView.updateAccessibility(items: built.filter(\.spec.hasLabel).map { ($0.id, name(for: $0.id)) })
        kick()
    }

    func name(for id: String) -> String {
        guard let entry = entriesByID[id] else { return "" }
        switch entry.kind {
        case .finder: return "Finder"
        case let .pinned(pin): return entry.running?.name ?? pin.name
        case let .recent(app): return app.name
        case .running: return entry.running?.name ?? "App"
        case .trash: return "Trash"
        case .share: return "Share"
        case let .folder(stack): return stack.name
        case let .divider(title): return title
        case .separator, .spacer: return ""
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
        menuIsOpen || sharePickerOpen || stackPanel.isShown || pressed != nil || dragSourceID != nil || externalDropActive
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
        case .separator, .spacer, .divider:
            return
        case .folder:
            toggleStack(entry)
            return
        case .trash:
            ripple(entry.id)
            actions.openTrash()
            return
        case .share:
            // There's nothing to share yet; say what the tile is for.
            if let rect = dockView.iconRect(for: entry.id) {
                showMenu(DockMenus.menu(for: entry, controller: self), at: NSPoint(x: rect.midX, y: rect.midY))
            }
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

    /// ⌃⌥1 to ⌃⌥9: does what clicking the n-th app does.
    func openShortcutTarget(_ index: Int) {
        let targets = entries.shortcutTargets
        guard targets.indices.contains(index) else {
            NSSound.beep()
            return
        }
        activate(targets[index], modifiers: [])
    }

    /// Takes a tile out of the dock (or out of the recent apps).
    func unpin(_ entry: DockEntry) {
        if entry.isRecent {
            recents.remove(entry.id)
        } else {
            pins.remove(entry.id)
        }
        rebuild(animated: true)
    }

    /// Adds a spacer, divider or the Share tile where the dock was clicked
    /// (or at the end of the user's items).
    func addItem(_ item: DockItem, atU u: Double?) {
        pins.insert(item, at: u.map { pinInsertionIndex(forU: $0, excluding: nil) })
        rebuild(animated: true)
        if case .divider = item, let entry = entriesByID[item.id] {
            renameDivider(entry)
        }
    }

    var hasShareTile: Bool { pins.contains(DockIdentity.share) }

    func renameDivider(_ entry: DockEntry) {
        guard case let .divider(title) = entry.kind else { return }
        let alert = NSAlert()
        alert.messageText = title.isEmpty ? "Name this divider" : "Rename this divider"
        alert.informativeText = "The name shows when you point at the divider. Leave it empty for a plain line."
        let field = NSTextField(string: title)
        field.placeholderString = "Work, Games, Writing…"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            pins.rename(entry.id, to: field.stringValue)
        }
    }

    func hasCustomIcon(_ entry: DockEntry) -> Bool {
        customIcons.hasIcon(for: entry.id)
    }

    /// Lets the user pick an image to show instead of the app's own icon.
    func chooseIcon(for entry: DockEntry) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as Icon"
        panel.message = "Choose an image to show for \(name(for: entry.id)) in MarDock."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try customIcons.setIcon(contentsOf: url, for: entry.id)
        } catch {
            NSSound.beep()
        }
    }

    func resetIcon(for entry: DockEntry) {
        customIcons.removeIcon(for: entry.id)
    }

    func keepInDock(_ entry: DockEntry) {
        guard let pin = pinnable(entry) else { return }
        pins.pin(pin)
        rebuild(animated: true)
    }

    func pinnable(_ entry: DockEntry) -> PinnedApp? {
        switch entry.kind {
        case let .pinned(pin), let .recent(pin):
            return pin
        case .running:
            guard let app = running.runningApp(for: entry.id), let identifier = app.bundleIdentifier, let url = app.bundleURL else { return nil }
            return PinnedApp(bundleIdentifier: identifier, path: url.path, name: app.localizedName ?? "")
        default:
            return nil
        }
    }

    /// What to store when a tile is dropped among the user's items.
    private func keptItem(for entry: DockEntry) -> DockItem? {
        switch entry.kind {
        case .spacer: return .spacer(id: entry.id)
        case let .divider(title): return .divider(id: entry.id, title: title)
        case .share: return .share
        case let .folder(stack): return .folder(stack)
        default: return pinnable(entry).map(DockItem.app)
        }
    }

    func runningApp(for entry: DockEntry) -> NSRunningApplication? {
        running.runningApp(for: entry.id)
    }

    // MARK: - Folders

    /// Lets the user choose a folder to keep in the dock.
    func addFolder(atU u: Double?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Add to Dock"
        panel.message = "Choose a folder to keep in MarDock. Its newest files will fan out when you click it."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let stack = FolderStacks.makeStack(for: url) else { return }
        addItem(.folder(stack), atU: u)
    }

    /// Opens or closes a folder tile's stack.
    func toggleStack(_ entry: DockEntry) {
        guard case let .folder(stack) = entry.kind else { return }
        if stackPanel.stackID == entry.id {
            stackPanel.close()
            return
        }
        if let closed = stackPanel.lastClosed, closed.id == entry.id, ProcessInfo.processInfo.systemUptime - closed.time < 0.5 {
            return
        }
        guard let url = folders.url(for: stack) else {
            findFolder(entry)
            return
        }
        let anchor = dockView.screenRect(forItem: entry.id)
        guard anchor != .zero else { return }
        stackPanel.show(id: entry.id, files: folders.files(in: stack), folder: url, name: stack.name, anchor: anchor, position: settings.settings.position)
        reevaluateAutoHide()
    }

    func openFolderInFinder(_ entry: DockEntry) {
        guard case let .folder(stack) = entry.kind else { return }
        if let url = folders.url(for: stack) {
            NSWorkspace.shared.open(url)
        } else {
            findFolder(entry)
        }
    }

    /// Changes how a folder tile looks or sorts its files.
    func updateFolder(_ entry: DockEntry, display: FolderStack.Display? = nil, sorting: FolderStack.Sorting? = nil) {
        guard case var .folder(stack) = entry.kind else { return }
        if let display { stack.display = display }
        if let sorting { stack.sorting = sorting }
        pins.replace(.folder(stack))
        icons.invalidate(entry.id)
        dockView.reloadImages()
        rebuild(animated: true)
    }

    /// The folder's bookmark doesn't lead anywhere (it was moved or deleted,
    /// or the dock came from another Mac): offer to choose it again.
    private func findFolder(_ entry: DockEntry) {
        guard case let .folder(stack) = entry.kind else { return }
        let alert = NSAlert()
        alert.messageText = "MarDock can't open “\(stack.name)”"
        alert.informativeText = "It may have been moved or deleted. Choose the folder again to keep it in the dock."
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let fresh = FolderStacks.makeStack(for: url),
              let replacement = FolderStack(id: stack.id, name: fresh.name, path: fresh.path, bookmark: fresh.bookmark, display: stack.display, sorting: stack.sorting)
        else { return }
        pins.replace(.folder(replacement))
        icons.invalidate(entry.id)
        dockView.reloadImages()
        rebuild(animated: true)
    }

    private func refreshFolderIcons() {
        var changed = false
        for entry in entries {
            if case .folder = entry.kind {
                icons.invalidate(entry.id)
                changed = true
            }
        }
        guard changed else { return }
        dockView.reloadImages()
        renderNow()
    }

    // MARK: - Sharing

    /// Files dropped on the Share tile go to the system share sheet.
    private func share(_ urls: [URL], fromTile id: String) {
        ripple(id)
        // Present once the drop has finished.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let rect = self.dockView.iconRect(for: id) else { return }
                let picker = NSSharingServicePicker(items: urls)
                picker.delegate = self
                self.sharePickerOpen = true
                self.reevaluateAutoHide()
                picker.show(relativeTo: rect, of: self.dockView, preferredEdge: self.edgeFacingScreen)
            }
        }
    }

    private var edgeFacingScreen: NSRectEdge {
        switch settings.settings.position {
        case .bottom: return .maxY
        case .left: return .maxX
        case .right: return .minX
        }
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

    /// Index among the user's items (excluding `excluded`) where a drop at `u` lands.
    private func pinInsertionIndex(forU u: Double, excluding excluded: String?) -> Int {
        let kept = entries.filter { $0.isKept && $0.id != excluded }.map(\.id)
        return engine.lastFrame.insertionIndex(u: u, among: kept)
    }

    /// Index among all tiles where the drop gap should open.
    private func gapIndex(forU u: Double, excluding excluded: String?) -> Int {
        let pinned = entries.filter { $0.isKept && $0.id != excluded }
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
        return entry.isKept || entry.isRecent
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
            menu = DockMenus.dockMenu(controller: self, settings: settings, coordinator: coordinator, at: p.u)
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
        guard let entry = entriesByID[id], (entry.isApp && entry.kind != .finder) || entry.isKept,
              let rect = dockView.iconRect(for: id), let index = entries.firstIndex(where: { $0.id == id })
        else { return }
        let item = NSPasteboardItem()
        item.setString(id, forType: .mardockTile)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(rect, contents: icons.image(for: entry, running: running.runningApp(for: id)))

        dragSourceID = id
        dragDropHandled = false
        // The drag session swallows the mouse-up, so the press ends here.
        pressed = nil
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
            dragDropHandled = false
            updateMouseIgnoring()
            mouse.refresh()
            kick()
        }
        if dragDropHandled { return }
        if operation == [] && isRemovalPoint(screenPoint) && canRemove(id) {
            let image = bitmap(for: id, pixels: dockView.pixelSize)
            PoofEffect.show(at: screenPoint, icon: image, size: CGFloat(engine.metrics.iconSize), reduceMotion: reduceMotion)
            if entriesByID[id]?.isRecent == true {
                recents.remove(id)
            } else {
                pins.remove(id)
            }
            rebuild(animated: true)
            engine.setDropGap(at: nil)
            engine.setDraggedItem(nil)
        } else if engine.hasOpenGap {
            // Cancelled over the dock: the drag image slides home into its
            // gap, then the tile takes its place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.dragSourceID == nil else { return }
                    self.engine.commitDrop()
                    self.kick()
                }
            }
        } else {
            // Cancelled away from the dock: the tile grows back in place.
            engine.setDropGap(at: nil)
            engine.setDraggedItem(nil)
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
        if let item = engine.lastFrame.item(atU: p.u, v: p.v), let entry = entriesByID[item.id], entry.isApp || entry.kind == .share {
            engine.setHighlighted(item.id)
            return .copy
        }
        engine.setHighlighted(nil)
        return []
    }

    func dockView(_ view: DockView, draggingEnded info: NSDraggingInfo?) {
        externalDropActive = false
        engine.setHighlighted(nil)
        engine.setDropGap(at: nil)
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
                  let item = keptItem(for: entry)
            else { return false }
            pins.insert(item, at: pinInsertionIndex(forU: p.u, excluding: id))
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
        if let item = engine.lastFrame.item(atU: p.u, v: p.v), let entry = entriesByID[item.id] {
            if entry.kind == .share {
                share(Array(urls.prefix(100)), fromTile: item.id)
                return true
            }
            if entry.isApp {
                actions.open(documents: Array(urls.prefix(100)), with: entry, running: running.runningApp(for: entry.id))
                ripple(item.id)
                return true
            }
        }
        return false
    }
}

extension DockController: NSSharingServicePickerDelegate {
    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        MainActor.assumeIsolated {
            sharePickerOpen = false
            reevaluateAutoHide()
            mouse.refresh()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

#if MARDOCK_SELFTEST
// Hooks for the self-test build's scripted tour (SelfTest.swift); never in release builds.
extension DockController {
    /// Moves the dock's pointer as if the mouse were at `point` (screen
    /// coordinates), through the same path real mouse movement takes.
    func demoPointer(at point: NSPoint) {
        mouse.simulatedLocation = point
        mouse.refresh()
    }

    /// Clicks a tile: the press, then whatever a real click does.
    func demoClick(_ id: String) {
        guard let entry = entriesByID[id] else { return }
        engine.setPressed(id)
        kick()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine.setPressed(nil)
                self.activate(entry, modifiers: [])
                self.kick()
            }
        }
    }

    /// Opens a tile's menu for `seconds`, then picks the item titled `title`
    /// (if there is one).
    func demoMenu(for id: String, choosing title: String, after seconds: TimeInterval) {
        guard let entry = entriesByID[id], let rect = dockView.iconRect(for: id) else { return }
        demoShow(DockMenus.menu(for: entry, controller: self), at: NSPoint(x: rect.midX, y: rect.midY), choosing: title, after: seconds)
    }

    /// Opens the dock's own menu where `screenPoint` is, as a right-click on
    /// the shelf would, then picks the item titled `title`.
    func demoDockMenu(at screenPoint: NSPoint, choosing title: String, after seconds: TimeInterval) {
        let local = panel.convertPoint(fromScreen: screenPoint)
        let u = dockView.dockPoint(for: local).u
        demoShow(DockMenus.dockMenu(controller: self, settings: settings, coordinator: coordinator, at: u), at: local, choosing: title, after: seconds)
    }

    private func demoShow(_ menu: NSMenu, at point: NSPoint, choosing title: String, after seconds: TimeInterval) {
        let close = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { menu.cancelTracking() }
        }
        RunLoop.main.add(close, forMode: .common)
        showMenu(menu, at: point)
        if let index = menu.items.firstIndex(where: { $0.title == title }) {
            menu.performActionForItem(at: index)
        }
    }

    /// Where `id` sits among the apps ⌃⌥1–9 open (0-based), if it's one of them.
    func shortcutSlot(of id: String) -> Int? {
        entries.shortcutTargets.firstIndex { $0.id == id }
    }
}
#endif
