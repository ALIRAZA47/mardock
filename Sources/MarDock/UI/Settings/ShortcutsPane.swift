import AppKit
import MarDockCore
import SwiftUI

struct ShortcutsPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var extras: ExtrasMonitor

    var body: some View {
        SettingsPage(.shortcuts) {
            SettingsSection(
                "Double-click",
                footer: "The first click opens the app or brings it forward, as always. Right-click an app for the same shortcuts at any time."
            ) {
                PickerRow("Double-clicking an app", selection: $store.settings.doubleClickAction) {
                    Text("Shows its shortcuts").tag(DoubleClickAction.shortcuts)
                    Text("Hides it").tag(DoubleClickAction.hide)
                    Text("Hides other apps").tag(DoubleClickAction.hideOthers)
                    Text("Does nothing").tag(DoubleClickAction.off)
                }
                .settingAnchor("doubleClick")
                SettingRow(
                    "Each app's own commands",
                    detail: "New Window, New Tab, Open and the like, from the app's File menu, with their keyboard shortcuts. Reading them needs Accessibility; MarDock's helper reads nothing else from that menu."
                ) {
                    if extras.accessibilityTrusted {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow…") {
                            extras.requestAccessibility()
                            ExtrasMonitor.openPrivacySettings("Accessibility")
                        }
                        .controlSize(.small)
                    }
                }
            }

            YourShortcuts()
                .settingAnchor("yourShortcuts")

            SettingsSection(
                "Keyboard",
                footer: "1 is Finder, then your apps in the order they're in the dock. No permission is needed: macOS tells MarDock about these key combinations only. With ⌥ alone, those keys stop typing characters such as ¡ and ™ in other apps."
            ) {
                PickerRow("Open the first nine apps with", selection: $store.settings.launchShortcut) {
                    Text("Off").tag(LaunchShortcut.off)
                    Text("⌃⌥ 1 – 9").tag(LaunchShortcut.controlOption)
                    Text("⌥ 1 – 9").tag(LaunchShortcut.option)
                    Text("⌥⌘ 1 – 9").tag(LaunchShortcut.commandOption)
                }
                .settingAnchor("keyboard")
            }
        }
        .onAppear { extras.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            extras.refreshPermissions()
        }
    }
}

/// Shortcuts the user makes for an app: websites and files to open in it,
/// and shortcuts from the Shortcuts app.
private struct YourShortcuts: View {
    private struct Choice: Identifiable, Hashable {
        let bundleIdentifier: String
        let name: String
        var id: String { bundleIdentifier.lowercased() }
    }

    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var pins: PinStore
    @EnvironmentObject private var shortcuts: UserShortcutStore
    @State private var selected: Choice?
    @State private var adding: NewShortcut.Kind?

    private var choices: [Choice] {
        var list = [Choice(bundleIdentifier: DockIdentity.finderBundleIdentifier, name: "Finder")]
        list += pins.pins.map { Choice(bundleIdentifier: $0.bundleIdentifier, name: $0.name) }
        if let target = navigator.shortcutsTarget {
            list.append(Choice(bundleIdentifier: target.bundleIdentifier, name: target.name))
        }
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        let choices = self.choices
        let current = selected.flatMap { choice in choices.first { $0.id == choice.id } } ?? choices.first
        let list = current.map { shortcuts.shortcuts(forApp: $0.bundleIdentifier) } ?? []
        SettingsSection(
            "Your shortcuts",
            footer: "They appear on the app's panel when you double-click it. Files and folders open in that app; so do websites, if it can show them."
        ) {
            RowBox {
                HStack(spacing: 10) {
                    Picker("App", selection: Binding(get: { current }, set: { selected = $0 })) {
                        ForEach(choices) { choice in
                            Text(choice.name).tag(Optional(choice))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Spacer(minLength: 8)
                    Menu {
                        Button("Website…") { adding = .website }
                        Button("File or Folder…") {
                            if let current { chooseFile(for: current) }
                        }
                        Button("Shortcut from the Shortcuts App…") { adding = .shortcut }
                    } label: {
                        Label("Add Shortcut", systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(list.count >= UserShortcutList.maxPerApp)
                }
                .controlSize(.small)
            }
            if list.isEmpty {
                RowBox {
                    Text(current.map { "Nothing here yet for \($0.name)." } ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(list) { shortcut in
                RowBox {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(for: shortcut))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(shortcut.title)
                                .font(.system(size: 13))
                            Text(detail(for: shortcut))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Button {
                            if let current { shortcuts.remove(shortcut.id, fromApp: current.bundleIdentifier) }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text("Remove \(shortcut.title)"))
                    }
                }
            }
        }
        .onAppear(perform: follow)
        .onChange(of: navigator.shortcutsTarget) { follow() }
        .sheet(item: $adding) { kind in
            NewShortcut(kind: kind, appName: current?.name ?? "") { shortcut in
                if let current { shortcuts.add(shortcut, toApp: current.bundleIdentifier) }
            }
        }
    }

    /// Comes here from an app's panel: show that app.
    private func follow() {
        guard let target = navigator.shortcutsTarget else { return }
        selected = Choice(bundleIdentifier: target.bundleIdentifier, name: target.name)
    }

    private func chooseFile(for app: Choice) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Shortcut"
        panel.message = "Choose a file or folder to open in \(app.name)."
        guard panel.runModal() == .OK, let url = panel.url, let action = UserShortcutStore.action(forFile: url),
              let shortcut = UserShortcut(title: FileManager.default.displayName(atPath: url.path), action: action)
        else { return }
        shortcuts.add(shortcut, toApp: app.bundleIdentifier)
    }

    private func symbol(for shortcut: UserShortcut) -> String {
        switch shortcut.action {
        case .website: return "globe"
        case .file: return "doc"
        case .shortcut: return "square.2.layers.3d"
        }
    }

    private func detail(for shortcut: UserShortcut) -> String {
        switch shortcut.action {
        case let .website(url): return url.absoluteString
        case let .file(path, _): return path
        case let .shortcut(name): return "Runs “\(name)” in Shortcuts"
        }
    }
}

/// Asks for a website, or the name of a shortcut.
private struct NewShortcut: View {
    enum Kind: String, Identifiable {
        case website, shortcut
        var id: String { rawValue }
    }

    let kind: Kind
    let appName: String
    let add: (UserShortcut) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var value = ""

    private var result: UserShortcut? {
        switch kind {
        case .website:
            guard let url = UserShortcut.webURL(from: value) else { return nil }
            return UserShortcut(title: title.isEmpty ? (url.host ?? value) : title, action: .website(url))
        case .shortcut:
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return UserShortcut(title: title.isEmpty ? name : title, action: .shortcut(name))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .website ? "Add a website to \(appName)" : "Add a shortcut to \(appName)")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text(kind == .website ? "Address" : "Shortcut name")
                        .gridColumnAlignment(.trailing)
                    TextField(kind == .website ? "example.com" : "As it's named in the Shortcuts app", text: $value)
                }
                GridRow {
                    Text("Title")
                    TextField("Optional", text: $title)
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let result { add(result) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(result == nil)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
