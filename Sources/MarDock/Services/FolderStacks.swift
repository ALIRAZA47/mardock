import AppKit
import MarDockCore

/// Folders the user keeps in the dock. MarDock can open a folder only
/// through the security-scoped bookmark it made when the user chose that
/// folder in an Open panel; it lists the newest files, draws them as a stack
/// and watches the folder for changes.
@MainActor
final class FolderStacks: ObservableObject {
    /// Changes whenever a watched folder's contents change.
    @Published private(set) var revision = 0

    struct File: Identifiable {
        let url: URL
        let name: String
        let date: Date
        var id: URL { url }
    }

    private final class OpenFolder {
        let url: URL
        var source: DispatchSourceFileSystemObject?

        init(url: URL) {
            self.url = url
        }

        deinit {
            source?.cancel()
            url.stopAccessingSecurityScopedResource()
        }
    }

    private var opened: [String: OpenFolder] = [:]

    /// The dock item for a folder the user just chose.
    static func makeStack(for url: URL) -> FolderStack? {
        guard let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        return FolderStack(
            id: DockIdentity.newTile(.folder),
            name: FileManager.default.displayName(atPath: url.path),
            path: url.path,
            bookmark: bookmark
        )
    }

    /// The folder, opened through its bookmark, or nil if the bookmark no
    /// longer leads anywhere (the folder was deleted, or this is another Mac).
    func url(for stack: FolderStack) -> URL? {
        if let folder = opened[stack.id] {
            return folder.url
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: stack.bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource()
        else { return nil }
        let folder = OpenFolder(url: url)
        watch(folder)
        opened[stack.id] = folder
        return url
    }

    /// Lets go of folders that are no longer in the dock.
    func retain(only ids: Set<String>) {
        opened = opened.filter { ids.contains($0.key) }
    }

    /// The folder's files in the stack's order, at most `limit`.
    func files(in stack: FolderStack, limit: Int = 40) -> [File] {
        guard let url = url(for: stack) else { return [] }
        let keys: Set<URLResourceKey> = [.addedToDirectoryDateKey, .contentModificationDateKey, .localizedNameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        ) else { return [] }
        var files = urls.prefix(5000).map { file -> File in
            let values = try? file.resourceValues(forKeys: keys)
            let added = values?.addedToDirectoryDate ?? values?.contentModificationDate
            let date = (stack.sorting == .dateModified ? values?.contentModificationDate : added) ?? .distantPast
            return File(url: file, name: values?.localizedName ?? file.lastPathComponent, date: date)
        }
        switch stack.sorting {
        case .name:
            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateAdded, .dateModified:
            files.sort { $0.date > $1.date }
        }
        return Array(files.prefix(limit))
    }

    /// The tile's picture: the newest files piled up, or the folder's own icon.
    func icon(for stack: FolderStack) -> NSImage {
        guard let url = url(for: stack) else { return Self.missingIcon }
        let workspace = NSWorkspace.shared
        let newest = stack.display == .stack ? files(in: stack, limit: 3) : []
        guard !newest.isEmpty else { return workspace.icon(forFile: url.path) }
        let icons = newest.map { workspace.icon(forFile: $0.url.path) }
        return NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
            // Back to front: the newest file ends up on top.
            for (depth, icon) in icons.enumerated().reversed() {
                let d = CGFloat(depth)
                let size = rect.width * (0.84 - d * 0.07)
                let tilt: CGFloat = depth == 0 ? 0 : (depth == 1 ? -6 : 7)
                NSGraphicsContext.saveGraphicsState()
                let transform = NSAffineTransform()
                transform.translateX(by: rect.midX + d * rect.width * 0.03, yBy: rect.minY + size / 2 + d * rect.height * 0.06)
                transform.rotate(byDegrees: tilt)
                transform.concat()
                icon.draw(in: NSRect(x: -size / 2, y: -size / 2, width: size, height: size))
                NSGraphicsContext.restoreGraphicsState()
            }
            return true
        }
    }

    /// A folder MarDock can't open any more.
    static let missingIcon = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
        NSWorkspace.shared.icon(for: .folder).draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.55)
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.width * 0.32, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .systemOrange]))
        if let badge = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            let size = badge.size
            badge.draw(in: NSRect(x: rect.maxX - size.width - 12, y: 12, width: size.width, height: size.height))
        }
        return true
    }

    private func watch(_ folder: OpenFolder) {
        let descriptor = open(folder.url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        folder.source = source
    }
}
