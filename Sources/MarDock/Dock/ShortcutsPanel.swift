import AppKit
import Combine
import MarDockCore
import SwiftUI

/// What the shortcuts panel shows for one app.
@MainActor
final class ShortcutsModel: ObservableObject {
    enum CommandState {
        case none
        case loading
        /// The helper needs Accessibility to read the app's menus.
        case needsAccessibility
    }

    struct Handlers {
        let run: (AppCommand) -> Void
        let open: (UserShortcut) -> Void
        let setHidden: (Bool) -> Void
        let hideOthers: () -> Void
        let reveal: () -> Void
        let quit: () -> Void
        let allowAccessibility: () -> Void
        let edit: () -> Void
    }

    let name: String
    let icon: NSImage
    let shortcuts: [UserShortcut]
    let isHidden: Bool
    let canQuit: Bool
    let handlers: Handlers
    @Published var isRunning: Bool
    @Published var commands: [AppCommand] = []
    @Published var commandState: CommandState = .loading

    init(name: String, icon: NSImage, shortcuts: [UserShortcut], isRunning: Bool, isHidden: Bool, canQuit: Bool, handlers: Handlers) {
        self.name = name
        self.icon = icon
        self.shortcuts = shortcuts
        self.isRunning = isRunning
        self.isHidden = isHidden
        self.canQuit = canQuit
        self.handlers = handlers
    }
}

/// The panel double-clicking an app opens: a small glass menu above its
/// tile. Clicking a row does what it says and closes the panel, and clicking
/// anywhere else closes it too.
@MainActor
final class ShortcutsPanel {
    /// Called when the panel closes, for whatever reason.
    var onClose: (() -> Void)?
    private var panel: NSPanel?
    private var hosting: NSView?
    private var shown: ShortcutsModel?
    private var anchor = NSRect.zero
    private var position = DockPosition.bottom
    private var monitors: [Any] = []
    private var observation: AnyCancellable?

    var isShown: Bool { panel != nil }

    func isShowing(_ model: ShortcutsModel) -> Bool { shown === model }

    func show(_ model: ShortcutsModel, anchor: NSRect, position: DockPosition) {
        close()
        self.anchor = anchor
        self.position = position
        let hosting = FirstClickHostingView(rootView: ShortcutsContent(model: model) { [weak self] in self?.close() })
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        shown = model
        place()
        panel.orderFrontRegardless()

        // The app's commands arrive a moment later: keep the panel sitting on
        // its tile. `objectWillChange` fires first; the debounce lets the view catch up.
        observation = model.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.place() }

        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let window = event.window
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, window !== panel else { return }
                self.close()
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    func close() {
        guard let panel else { return }
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        observation = nil
        panel.orderOut(nil)
        self.panel = nil
        hosting = nil
        shown = nil
        onClose?()
    }

    private func place() {
        guard let panel, let hosting else { return }
        let size = hosting.fittingSize
        panel.setFrame(NSRect(origin: Self.origin(for: size, anchor: anchor, position: position), size: size), display: true)
    }

    private static func origin(for size: NSSize, anchor: NSRect, position: DockPosition) -> NSPoint {
        var origin: NSPoint
        switch position {
        case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 2)
        case .left: origin = NSPoint(x: anchor.maxX + 2, y: anchor.midY - size.height / 2)
        case .right: origin = NSPoint(x: anchor.minX - size.width - 2, y: anchor.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        }
        return origin
    }
}

struct ShortcutsContent: View {
    @ObservedObject var model: ShortcutsModel
    let close: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !model.commands.isEmpty || model.commandState != .none {
                section {
                    ForEach(model.commands) { command in
                        row(command.title, symbol: symbol(for: command), keys: command.keys) { model.handlers.run(command) }
                    }
                    switch model.commandState {
                    case .none:
                        EmptyView()
                    case .loading:
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Text(model.isRunning ? "Reading \(model.name)'s commands…" : "Waiting for \(model.name) to open…")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    case .needsAccessibility:
                        row("Show \(model.name)'s commands…", symbol: "hand.raised", tint: .orange) { model.handlers.allowAccessibility() }
                    }
                }
            }
            if !model.shortcuts.isEmpty {
                section {
                    ForEach(model.shortcuts) { shortcut in
                        row(shortcut.title, symbol: symbol(for: shortcut)) { model.handlers.open(shortcut) }
                    }
                }
            }
            section {
                if model.isRunning {
                    if model.isHidden {
                        row("Show \(model.name)", symbol: "eye") { model.handlers.setHidden(false) }
                    } else {
                        row("Hide \(model.name)", symbol: "eye.slash") { model.handlers.setHidden(true) }
                    }
                    row("Hide Others", symbol: "rectangle.on.rectangle.slash") { model.handlers.hideOthers() }
                }
                row("Show in Finder", symbol: "folder") { model.handlers.reveal() }
                if model.isRunning && model.canQuit {
                    row("Quit \(model.name)", symbol: "xmark.circle") { model.handlers.quit() }
                }
            }
        }
        .padding(.vertical, 5)
        .frame(width: 276)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .padding(18)
        .onAppear {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) { shown = true }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: model.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
            Text(model.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                model.handlers.edit()
                close()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Add a shortcut for \(model.name)")
            .accessibilityLabel(Text("Add a shortcut for \(model.name)"))
        }
        .padding(.leading, 11)
        .padding(.trailing, 8)
        .padding(.top, 3)
        .padding(.bottom, 6)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 10).padding(.bottom, 4)
            content()
        }
        .padding(.bottom, 4)
    }

    private func row(_ title: String, symbol: String, keys: String = "", tint: Color? = nil, action: @escaping () -> Void) -> some View {
        ShortcutRow(title: title, symbol: symbol, keys: keys, tint: tint) {
            action()
            close()
        }
    }

    private func symbol(for command: AppCommand) -> String {
        let title = command.title.lowercased()
        if title.contains("private") || title.contains("incognito") { return "eyeglasses" }
        if title.contains("tab") { return "plus.square.on.square" }
        if title.contains("folder") { return "folder.badge.plus" }
        if title.contains("window") { return "macwindow.badge.plus" }
        if title.hasPrefix("open") || title.hasPrefix("reopen") { return "arrow.up.forward.square" }
        return "plus.circle"
    }

    private func symbol(for shortcut: UserShortcut) -> String {
        switch shortcut.action {
        case .website: return "globe"
        case .file: return "doc"
        case .shortcut: return "square.2.layers.3d"
        }
    }
}

private struct ShortcutRow: View {
    let title: String
    let symbol: String
    let keys: String
    let tint: Color?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(hovering ? Color.white : (tint ?? Color.secondary))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(hovering ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 10)
                if !keys.isEmpty {
                    Text(keys)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(hovering ? Color.white.opacity(0.85) : Color.secondary)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 5)
        .onHover { hovering = $0 }
    }
}
