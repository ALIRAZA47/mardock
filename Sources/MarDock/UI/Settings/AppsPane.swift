import AppKit
import MarDockCore
import SwiftUI
import UniformTypeIdentifiers

struct AppsPane: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var pins: PinStore
    @EnvironmentObject private var profiles: ProfileStore
    @State private var importMessage: String?
    @State private var dragged: String?

    var body: some View {
        SettingsPage(.apps) {
            SettingsSection(
                "Profile",
                footer: "Profiles are sets of apps and items you switch between, such as Work and Personal: from the dock's menu, or here. A new profile starts as a copy of the current dock."
            ) {
                RowBox {
                    HStack(spacing: 10) {
                        Picker("Profile", selection: Binding(get: { profiles.activeID }, set: { profiles.activate($0) })) {
                            ForEach(profiles.profiles) { profile in
                                Text(profile.name).tag(profile.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                        Spacer(minLength: 8)
                        Button("New…") {
                            if let name = askForProfileName(title: "New profile", button: "Create", initial: "") {
                                profiles.create(named: name.isEmpty ? "Profile \(profiles.profiles.count + 1)" : name)
                            }
                        }
                        Button("Rename…") {
                            let current = profiles.profiles.first { $0.id == profiles.activeID }?.name ?? ""
                            if let name = askForProfileName(title: "Rename profile", button: "Rename", initial: current) {
                                profiles.rename(profiles.activeID, to: name)
                            }
                        }
                        Button("Delete…") {
                            confirmDeleteProfile()
                        }
                        .disabled(profiles.profiles.count < 2)
                    }
                    .controlSize(.small)
                }
            }
            .settingAnchor("profiles")

            SettingsSection(
                "In the dock",
                footer: "Drag rows to reorder. Drop an image on an app's icon (or click it) to change how that app looks in MarDock. On the dock itself you can drag apps in from Finder, drag tiles along, or drag one off to remove it."
            ) {
                AppRow(name: "Finder", detail: "Always first", id: DockIdentity.finder, original: icon(forBundle: DockIdentity.finderBundleIdentifier), remove: nil)
                ForEach(pins.items) { item in
                    row(for: item)
                        .onDrag {
                            dragged = item.id
                            return NSItemProvider(object: item.id as NSString)
                        }
                        .onDrop(of: [.text], delegate: RowDrop(target: item.id, dragged: $dragged, pins: pins))
                }
            }
            .settingAnchor("dockItems")

            SettingsSection(
                "Add",
                footer: "Spacers leave a gap, dividers draw a line with an optional name that shows when you point at it, the Share tile sends files you drop on it to AirDrop, Mail or Messages, and a folder shows its newest files when you click it."
            ) {
                RowBox {
                    HStack(spacing: 10) {
                        Button {
                            addApps()
                        } label: {
                            Label("Add Apps…", systemImage: "plus")
                        }
                        Menu {
                            Button("Spacer") { withAnimation { pins.insert(.newSpacer()) } }
                            Button("Divider") { withAnimation { pins.insert(.newDivider()) } }
                            Button("Share Tile") { withAnimation { pins.insert(.share) } }
                                .disabled(pins.contains(DockIdentity.share))
                            Button("Folder…") { addFolder() }
                        } label: {
                            Label("Add Item", systemImage: "rectangle.dashed")
                        }
                        .fixedSize()
                        Button {
                            Task {
                                let count = await coordinator.importFromSystemDock()
                                importMessage = count > 0 ? "Imported \(count) apps from the macOS Dock." : "Couldn't read the macOS Dock's apps."
                            }
                        } label: {
                            Label("Import from macOS Dock", systemImage: "square.and.arrow.down")
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }
                if let importMessage {
                    RowBox {
                        Text(importMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .settingAnchor("addItems")
        }
    }

    @ViewBuilder
    private func row(for item: DockItem) -> some View {
        switch item {
        case let .app(pin):
            AppRow(name: pin.name, detail: pin.path, id: pin.id, original: NSWorkspace.shared.icon(forFile: pin.path)) {
                withAnimation { pins.remove(pin.id) }
            }
        case .spacer:
            ItemRow(symbol: "rectangle.dashed", title: "Spacer", detail: "An empty space between apps") {
                withAnimation { pins.remove(item.id) }
            }
        case let .divider(id, title):
            DividerRow(title: title, rename: { pins.rename(id, to: $0) }) {
                withAnimation { pins.remove(id) }
            }
        case .share:
            ItemRow(symbol: "square.and.arrow.up", title: "Share", detail: "Drop files on it for AirDrop, Mail or Messages") {
                withAnimation { pins.remove(item.id) }
            }
        case let .folder(stack):
            ItemRow(symbol: "folder", title: stack.name, detail: stack.path) {
                withAnimation { pins.remove(stack.id) }
            }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Add to Dock"
        panel.message = "Choose a folder to keep in MarDock. Its newest files will fan out when you click it."
        guard panel.runModal() == .OK, let url = panel.url, let stack = FolderStacks.makeStack(for: url) else { return }
        withAnimation { pins.insert(.folder(stack)) }
    }

    private func confirmDeleteProfile() {
        guard let current = profiles.profiles.first(where: { $0.id == profiles.activeID }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the profile “\(current.name)”?"
        alert.informativeText = "Its apps and items go with it, and the dock switches to another profile."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        profiles.delete(current.id)
    }

    private func icon(forBundle identifier: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Add to Dock"
        panel.message = "Choose apps to keep in MarDock."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let app = AppCatalog.pinnedApp(url: url) {
                pins.pin(app)
            }
        }
    }
}

/// Reorders the dock's rows live, as one is dragged over the others.
private struct RowDrop: DropDelegate {
    let target: String
    @Binding var dragged: String?
    let pins: PinStore

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target, let index = pins.items.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { pins.move(dragged, to: index) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

private struct AppRow: View {
    let name: String
    let detail: String
    let id: String
    let original: NSImage
    let remove: (() -> Void)?

    var body: some View {
        RowBox {
            HStack(spacing: 12) {
                IconWell(id: id, name: name, original: original)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 13))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if let remove {
                    RemoveButton(name: name, action: remove)
                }
            }
        }
    }
}

/// An app's icon in Settings. Drop an image on it, or click it, to show that
/// image for the app in MarDock.
private struct IconWell: View {
    @EnvironmentObject private var customIcons: CustomIconStore
    let id: String
    let name: String
    let original: NSImage
    @State private var targeted = false

    var body: some View {
        Image(nsImage: customIcons.icon(for: id) ?? original)
            .resizable()
            .interpolation(.high)
            .frame(width: 30, height: 30)
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: targeted ? 2 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture { choose() }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                return (try? customIcons.setIcon(contentsOf: url, for: id)) != nil
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Button("Choose Icon…") { choose() }
                if customIcons.hasIcon(for: id) {
                    Button("Use Original Icon") { customIcons.removeIcon(for: id) }
                }
            }
            .help("Drop an image here, or click, to change \(name)'s icon in MarDock")
            .accessibilityLabel(Text("\(name) icon"))
            .accessibilityHint(Text("Choose an image to show for \(name) in MarDock"))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as Icon"
        panel.message = "Choose an image to show for \(name) in MarDock."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try customIcons.setIcon(contentsOf: url, for: id)
        } catch {
            NSSound.beep()
        }
    }
}

/// A spacer or the Share tile in the list.
private struct ItemRow: View {
    let symbol: String
    let title: String
    let detail: String
    let remove: () -> Void

    var body: some View {
        RowBox {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                RemoveButton(name: title, action: remove)
            }
        }
    }
}

/// A divider, named in place.
private struct DividerRow: View {
    let title: String
    let rename: (String) -> Void
    let remove: () -> Void
    @State private var draft = ""

    var body: some View {
        RowBox {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Divider")
                        .font(.system(size: 13))
                    TextField("Name (optional)", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(maxWidth: 220)
                        .onChange(of: draft) { rename(draft) }
                }
                Spacer(minLength: 0)
                RemoveButton(name: "divider", action: remove)
            }
        }
        .onAppear { draft = title }
    }
}

private struct RemoveButton: View {
    let name: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
        }
        .buttonStyle(.borderless)
        .help("Remove from dock")
        .accessibilityLabel(Text("Remove \(name)"))
    }
}
