import AppKit
import MarDockCore
import SwiftUI

/// A folder tile's files, fanned out above it like the macOS Dock's stacks
/// (or in a grid on a side dock or for a fuller folder). Clicking a file
/// opens it; clicking anywhere else closes the stack.
@MainActor
final class StackPanel {
    /// Called when the stack closes, for whatever reason.
    var onClose: (() -> Void)?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private(set) var stackID: String?
    /// The stack that closed last, and when: a click on its own tile closes
    /// it on the way down, and the same click mustn't reopen it on the way up.
    private(set) var lastClosed: (id: String, time: TimeInterval)?

    var isShown: Bool { panel != nil }

    /// Fan rows: the name, then the icon, which lines up with the tile.
    static let rowWidth: CGFloat = 300
    static let fanRoom: CGFloat = 70
    static let maxFanned = 10

    func show(id: String, files: [FolderStacks.File], folder: URL, name: String, anchor: NSRect, position: DockPosition) {
        close()
        let fan = position == .bottom && files.count <= Self.maxFanned
        let content = StackContent(
            files: files,
            folderName: name,
            fan: fan,
            open: { [weak self] url in
                NSWorkspace.shared.open(url)
                self?.close()
            },
            openFolder: { [weak self] in
                NSWorkspace.shared.open(folder)
                self?.close()
            }
        )
        let hosting = FirstClickHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: Self.origin(for: size, anchor: anchor, position: position, fan: fan), size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        stackID = id

        // A click anywhere outside closes it, as with the macOS Dock.
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
        panel.orderOut(nil)
        self.panel = nil
        if let stackID {
            lastClosed = (stackID, ProcessInfo.processInfo.systemUptime)
        }
        stackID = nil
        onClose?()
    }

    private static func origin(for size: NSSize, anchor: NSRect, position: DockPosition, fan: Bool) -> NSPoint {
        var origin: NSPoint
        switch position {
        case .bottom:
            // A fan's lowest icon sits right above the tile; a grid is centred on it.
            let x = fan ? anchor.midX - (8 + rowWidth - 23) : anchor.midX - size.width / 2
            origin = NSPoint(x: x, y: anchor.maxY + 4)
        case .left:
            origin = NSPoint(x: anchor.maxX + 8, y: anchor.midY - size.height / 2)
        case .right:
            origin = NSPoint(x: anchor.minX - size.width - 8, y: anchor.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        }
        return origin
    }
}

/// Buttons in a panel of an app that isn't active should work on the first click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct StackContent: View {
    let files: [FolderStacks.File]
    let folderName: String
    let fan: Bool
    let open: (URL) -> Void
    let openFolder: () -> Void
    @State private var shown = false

    var body: some View {
        Group {
            if fan {
                fanView
            } else {
                gridView
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { shown = true }
        }
    }

    // MARK: Fan

    private var fanView: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Spacer(minLength: 0)
                folderButton
            }
            .frame(width: StackPanel.rowWidth)
            .offset(x: shown ? curve(files.count) : 0)
            .opacity(shown ? 1 : 0)
            if files.isEmpty {
                Text("This folder is empty")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .frame(width: StackPanel.rowWidth, alignment: .trailing)
            }
            ForEach(Array(files.enumerated()).reversed(), id: \.element.id) { index, file in
                FanRow(file: file) { open(file.url) }
                    .rotationEffect(.degrees(shown ? Double(index) * 1.1 : 0), anchor: .trailing)
                    .offset(x: shown ? curve(index) : 0, y: shown ? 0 : CGFloat(index + 1) * 51)
                    .opacity(shown ? 1 : 0)
                    .animation(.spring(response: 0.42, dampingFraction: 0.8).delay(Double(index) * 0.018), value: shown)
            }
        }
        .padding(.leading, 8)
        .padding(.vertical, 8)
        .frame(width: 8 + StackPanel.rowWidth + StackPanel.fanRoom, alignment: .leading)
    }

    /// How far right a row sits: the fan bends away as it rises.
    private func curve(_ index: Int) -> CGFloat {
        CGFloat(index * index) * 0.55
    }

    // MARK: Grid

    private var gridView: some View {
        let columns = Array(repeating: GridItem(.fixed(86), spacing: 8), count: 4)
        let rows = max(1, (files.count + 3) / 4)
        return VStack(spacing: 12) {
            Text(folderName)
                .font(.headline)
            if files.isEmpty {
                Text("This folder is empty")
                    .foregroundStyle(.secondary)
                    .frame(height: 60)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(files) { file in
                            GridCell(file: file) { open(file.url) }
                        }
                    }
                }
                .frame(height: min(CGFloat(rows) * 98, 4 * 98))
            }
            folderButton
        }
        .padding(16)
        .frame(width: 4 * 86 + 3 * 8 + 32)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .scaleEffect(shown ? 1 : 0.92)
        .opacity(shown ? 1 : 0)
        .padding(10)
    }

    private var folderButton: some View {
        Button(action: openFolder) {
            Label("Open in Finder", systemImage: "folder")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.25)))
        }
        .buttonStyle(.plain)
    }
}

private struct FanRow: View {
    let file: FolderStacks.File
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(hovering ? Color.accentColor : Color.black.opacity(0.55)))
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
                    .scaleEffect(hovering ? 1.08 : 1)
            }
            .frame(width: StackPanel.rowWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(file.name)
    }
}

private struct GridCell: View {
    let file: FolderStacks.File
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 52, height: 52)
                Text(file.name)
                    .font(.caption)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 82)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.name)
    }
}
