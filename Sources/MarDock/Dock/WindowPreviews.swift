import AppKit
import MarDockCore
import ScreenCaptureKit
import SwiftUI

/// Pictures of a running app's windows while the pointer rests on its tile
/// (an extra the user turns on; it needs Screen Recording). The pictures are
/// small, taken only for the app under the pointer, shown, and dropped:
/// nothing is stored or sent anywhere.
@MainActor
final class WindowPreviews {
    struct Preview: Identifiable {
        let id: CGWindowID
        let title: String
        let image: CGImage
        let size: CGSize
    }

    /// The window to bring forward was clicked.
    var onSelect: ((pid_t, String) -> Void)?
    /// The panel opened or closed (the dock stays out while it's open).
    var onVisibilityChange: (() -> Void)?

    private var panel: NSPanel?
    private var hoverID: String?
    private var shownID: String?
    private var pending: Task<Void, Never>?
    private var closeTimer: Timer?

    var isShown: Bool { panel != nil }

    /// The tile under the pointer is now `entry` (nil: none). A running app's
    /// previews appear after the pointer rests on it for a moment.
    func hover(_ entry: DockEntry?, anchor: @escaping @MainActor () -> NSRect, position: DockPosition) {
        let id = entry?.id
        guard id != hoverID else { return }
        hoverID = id
        pending?.cancel()
        pending = nil
        guard let entry, let app = entry.running, app.pid > 0, CGPreflightScreenCaptureAccess() else {
            scheduleClose()
            return
        }
        if shownID == entry.id {
            closeTimer?.invalidate()
            closeTimer = nil
            return
        }
        let pid = app.pid
        let name = app.name
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.isShown == true ? 150_000_000 : 650_000_000)
            guard !Task.isCancelled else { return }
            let previews = await Self.capture(pid: pid)
            guard !Task.isCancelled, let self, self.hoverID == entry.id else { return }
            if previews.isEmpty {
                self.close()
            } else {
                self.show(previews, id: entry.id, pid: pid, appName: name, anchor: anchor(), position: position)
            }
        }
    }

    /// Keeps the panel while the pointer moves from the tile onto it.
    func pointerMoved(to point: NSPoint) {
        guard let panel else { return }
        if panel.frame.insetBy(dx: -8, dy: -8).contains(point) {
            closeTimer?.invalidate()
            closeTimer = nil
        } else if hoverID != shownID {
            scheduleClose()
        }
    }

    func close() {
        closeTimer?.invalidate()
        closeTimer = nil
        pending?.cancel()
        pending = nil
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        shownID = nil
        onVisibilityChange?()
    }

    private func scheduleClose() {
        guard isShown, closeTimer == nil else { return }
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeTimer = nil
                if let panel = self.panel, panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) { return }
                if self.hoverID != self.shownID { self.close() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func show(_ previews: [Preview], id: String, pid: pid_t, appName: String, anchor: NSRect, position: DockPosition) {
        let content = PreviewStrip(previews: previews, appName: appName) { [weak self] preview in
            self?.onSelect?(pid, preview.title)
            self?.close()
        }
        let hosting = FirstClickHostingView(rootView: content)
        let size = hosting.fittingSize
        let frame = NSRect(origin: Self.origin(for: size, anchor: anchor, position: position), size: size)
        let panel = self.panel ?? Self.makePanel()
        panel.contentView = hosting
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        let opened = self.panel == nil
        self.panel = panel
        shownID = id
        if opened { onVisibilityChange?() }
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private static func origin(for size: NSSize, anchor: NSRect, position: DockPosition) -> NSPoint {
        var origin: NSPoint
        switch position {
        case .bottom: origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 6)
        case .left: origin = NSPoint(x: anchor.maxX + 6, y: anchor.midY - size.height / 2)
        case .right: origin = NSPoint(x: anchor.minX - size.width - 6, y: anchor.midY - size.height / 2)
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 4), max(visible.minX + 4, visible.maxX - size.width - 4))
            origin.y = min(max(origin.y, visible.minY + 4), max(visible.minY + 4, visible.maxY - size.height - 4))
        }
        return origin
    }

    /// Small pictures of the app's normal, visible windows, biggest first.
    private static func capture(pid: pid_t) async -> [Preview] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let windows = content.windows
            .filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width >= 120 && $0.frame.height >= 80 }
            .sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
            .prefix(5)
        var previews: [Preview] = []
        for window in windows {
            let configuration = SCStreamConfiguration()
            let scale = min(1, 300 / max(window.frame.width, window.frame.height))
            configuration.width = max(1, Int(window.frame.width * scale * 2))
            configuration.height = max(1, Int(window.frame.height * scale * 2))
            configuration.showsCursor = false
            let filter = SCContentFilter(desktopIndependentWindow: window)
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else { continue }
            let title = InputValidation.sanitizedDisplayName(window.title ?? "")
            previews.append(Preview(id: window.windowID, title: title, image: image, size: CGSize(width: window.frame.width * scale, height: window.frame.height * scale)))
        }
        return previews
    }
}

private struct PreviewStrip: View {
    let previews: [WindowPreviews.Preview]
    let appName: String
    let select: (WindowPreviews.Preview) -> Void
    @State private var shown = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ForEach(previews) { preview in
                PreviewCard(preview: preview, appName: appName) { select(preview) }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .scaleEffect(shown ? 1 : 0.94, anchor: .bottom)
        .opacity(shown ? 1 : 0)
        .padding(10)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { shown = true }
        }
    }
}

private struct PreviewCard: View {
    let preview: WindowPreviews.Preview
    let appName: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(decorative: preview.image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: preview.size.width, height: preview.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Text(preview.title.isEmpty ? appName : preview.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: preview.size.width)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.accentColor.opacity(0.22) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(preview.title)
    }
}
