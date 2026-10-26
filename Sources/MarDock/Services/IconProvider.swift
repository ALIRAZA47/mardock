import AppKit
import MarDockCore
import UniformTypeIdentifiers

/// Fetches app icons and renders them once, at the exact pixel size the dock
/// needs at full magnification. Layers then only scale bitmaps on the GPU.
@MainActor
final class IconProvider {
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
        let workspace = NSWorkspace.shared
        switch entry.kind {
        case .trash:
            return NSImage(named: NSImage.trashEmptyName) ?? workspace.icon(for: .folder)
        case .finder:
            if let url = workspace.urlForApplication(withBundleIdentifier: DockIdentity.finderBundleIdentifier) {
                return workspace.icon(forFile: url.path)
            }
        case let .pinned(pin):
            if FileManager.default.fileExists(atPath: pin.path) {
                return workspace.icon(forFile: pin.path)
            }
            if let url = workspace.urlForApplication(withBundleIdentifier: pin.bundleIdentifier) {
                return workspace.icon(forFile: url.path)
            }
        case .running, .separator:
            break
        }
        if let icon = running?.icon { return icon }
        if let url = running?.bundleURL { return workspace.icon(forFile: url.path) }
        return workspace.icon(for: .applicationBundle)
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
