import AppKit
import MarDockCore
import UniformTypeIdentifiers

/// Fetches app icons and renders them once, at the exact pixel size the dock
/// needs at full magnification. Layers then only scale bitmaps on the GPU.
@MainActor
final class IconProvider {
    /// Icons the user picked; they win over the app's own.
    var customIcons: CustomIconStore?
    private var images: [String: NSImage] = [:]
    private var bitmaps: [String: CGImage] = [:]

    func image(for entry: DockEntry, running: NSRunningApplication?) -> NSImage {
        if let cached = images[entry.id] { return cached }
        let image = loadImage(for: entry, running: running)
        images[entry.id] = image
        return image
    }

    func bitmap(for entry: DockEntry, running: NSRunningApplication?, pixels: Int) -> CGImage? {
        let key = "\(entry.id)#\(pixels)"
        if let cached = bitmaps[key] { return cached }
        guard let bitmap = Self.render(image(for: entry, running: running), pixels: pixels) else { return nil }
        bitmaps[key] = bitmap
        return bitmap
    }

    /// Drops cached icons for tiles that are gone.
    func retain(only ids: Set<String>) {
        images = images.filter { ids.contains($0.key) }
        bitmaps = bitmaps.filter { key, _ in
            guard let id = key.split(separator: "#").first else { return false }
            return ids.contains(String(id))
        }
    }

    func invalidate(_ id: String? = nil) {
        guard let id else {
            images.removeAll()
            bitmaps.removeAll()
            return
        }
        images[id] = nil
        bitmaps = bitmaps.filter { !$0.key.hasPrefix(id + "#") }
    }

    private func loadImage(for entry: DockEntry, running: NSRunningApplication?) -> NSImage {
        if let custom = customIcons?.icon(for: entry.id) {
            return custom
        }
        let workspace = NSWorkspace.shared
        switch entry.kind {
        case .trash:
            return NSImage(named: NSImage.trashEmptyName) ?? workspace.icon(for: .folder)
        case .finder:
            if let url = workspace.urlForApplication(withBundleIdentifier: DockIdentity.finderBundleIdentifier) {
                return workspace.icon(forFile: url.path)
            }
        case let .pinned(pin), let .recent(pin):
            if FileManager.default.fileExists(atPath: pin.path) {
                return workspace.icon(forFile: pin.path)
            }
            if let url = workspace.urlForApplication(withBundleIdentifier: pin.bundleIdentifier) {
                return workspace.icon(forFile: url.path)
            }
        case .share:
            return Self.shareIcon
        case .spacer:
            return Self.spacerImage
        case .divider:
            return Self.dividerImage
        case .folder:
            return workspace.icon(for: .folder)
        case .running, .separator:
            break
        }
        if let icon = running?.icon { return icon }
        if let url = running?.bundleURL { return workspace.icon(forFile: url.path) }
        return workspace.icon(for: .applicationBundle)
    }

    /// The Share tile: a share symbol on a rounded square, like an app icon.
    static let shareIcon = symbolTile("square.and.arrow.up", top: NSColor(hex: 0x5AC8FA), bottom: NSColor(hex: 0x0A6FE8))

    /// What a spacer looks like while it's dragged (in the dock it's invisible).
    static let spacerImage = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 30, dy: 30), xRadius: 44, yRadius: 44)
        path.lineWidth = 10
        path.setLineDash([26, 18], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.85).setStroke()
        path.stroke()
        return true
    }

    /// What a divider looks like while it's dragged.
    static let dividerImage = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
        let line = NSBezierPath(roundedRect: NSRect(x: rect.midX - 6, y: 40, width: 12, height: rect.height - 80), xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.9).setFill()
        line.fill()
        return true
    }

    /// An SF Symbol in white on a gradient squircle, sized like a macOS app icon.
    static func symbolTile(_ symbol: String, top: NSColor, bottom: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            let body = rect.insetBy(dx: rect.width * 0.098, dy: rect.height * 0.098)
            let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.height * 0.225)
            NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: body.width * 0.46, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = glyph.size
                glyph.draw(in: NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2, width: size.width, height: size.height))
            }
            return true
        }
    }

    static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard pixels > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)]
        )
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
