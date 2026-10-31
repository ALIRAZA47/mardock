import AppKit
import MarDockCore
import SwiftUI

/// The Settings window: a sidebar with search, and the pane it's on.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, appearance, behavior, apps, shortcuts, extras, systemDock, privacy, about

        var id: Self { self }

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            case .behavior: return "Behaviour"
            case .apps: return "Apps"
            case .shortcuts: return "Shortcuts"
            case .extras: return "Extras"
            case .systemDock: return "macOS Dock"
            case .privacy: return "Privacy & Security"
            case .about: return "About"
            }
        }

        var subtitle: String {
            switch self {
            case .general: return "Starting up, the macOS Dock, updates and backups."
            case .appearance: return "How the dock looks. The preview follows every change."
            case .behavior: return "Where the dock sits, when it hides and what it shows."
            case .apps: return "What's in the dock, and sets of apps to switch between."
            case .shortcuts: return "Quick ways into your apps, by mouse and by keyboard."
            case .extras: return "Optional touches that need a little more access. All off until you want them."
            case .systemDock: return "Hide the built-in Dock, or tune it."
            case .privacy: return "What MarDock can and can't do, read live from macOS."
            case .about: return "The version you have, and new ones."
            }
        }

        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .appearance: return "paintpalette.fill"
            case .behavior: return "cursorarrow.motionlines"
            case .apps: return "square.grid.2x2.fill"
            case .shortcuts: return "command"
            case .extras: return "sparkles"
            case .systemDock: return "dock.rectangle"
            case .privacy: return "lock.shield.fill"
            case .about: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: return .gray
            case .appearance: return .pink
            case .behavior: return .blue
            case .apps: return .orange
            case .shortcuts: return .purple
            case .extras: return .teal
            case .systemDock: return .indigo
            case .privacy: return .green
            case .about: return .gray
            }
        }
    }

    @EnvironmentObject private var navigator: SettingsNavigator

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
            pane
                .id(navigator.pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SettingsStyle.canvas)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(SettingsStyle.hairline)
                        .frame(width: 0.5)
                }
        }
        .ignoresSafeArea()
        .frame(minWidth: 820, minHeight: 540)
    }

    @ViewBuilder private var pane: some View {
        switch navigator.pane {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .behavior: BehaviorPane()
        case .apps: AppsPane()
        case .shortcuts: ShortcutsPane()
        case .extras: ExtrasPane()
        case .systemDock: SystemDockPane()
        case .privacy: PrivacyPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var updates: UpdateController
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var themes: ThemeStore
    @State private var query = ""
    @FocusState private var searching: Bool

    private let groups: [[SettingsView.Pane]] = [
        [.general],
        [.appearance, .behavior, .apps, .shortcuts, .extras],
        [.systemDock, .privacy],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                Text("MarDock")
                    .font(.system(size: 14, weight: .semibold))
            }
            .padding(.leading, 16)
            .padding(.top, 44)
            .padding(.bottom, 12)

            searchField
                .padding(.horizontal, 10)
                .padding(.bottom, 10)

            ScrollView {
                if query.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(groups[index]) { pane in
                                    SidebarRow(pane: pane)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                } else {
                    SearchResults(query: query) {
                        query = ""
                        searching = false
                    }
                    .padding(.horizontal, 10)
                }
            }
            .scrollIndicators(.never)

            Spacer(minLength: 8)

            SidebarRow(pane: .about, badge: updateBadge)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(width: 222)
        .background {
            ZStack(alignment: .top) {
                SidebarMaterial()
                // A breath of the theme in use, so Settings feels like part of the dock.
                LinearGradient(colors: themeColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 300)
                    .opacity(0.18)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
            }
        }
    }

    private var themeColors: [Color] {
        let colors = themes.recipe(for: store.settings).swatch.map { Color(nsColor: NSColor(themeColor: $0)) }
        return colors.count >= 2 ? colors : [.clear, .clear]
    }

    private var updateBadge: Bool {
        if case .available = updates.phase { return true }
        return false
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($searching)
                .onSubmit {
                    if let first = SettingsTopic.matches(query).first {
                        navigator.show(first.pane, spotlight: first.anchor)
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background {
            Button("Search") { searching = true }
                .keyboardShortcut("f")
                .hidden()
        }
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    let pane: SettingsView.Pane
    var badge = false
    @State private var hovering = false

    private var isSelected: Bool { navigator.pane == pane }

    var body: some View {
        Button {
            navigator.show(pane)
        } label: {
            HStack(spacing: 9) {
                PaneIcon(symbol: pane.symbol, color: pane.color)
                Text(pane.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                Spacer(minLength: 0)
                if badge {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel(Text("An update is available"))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.1 : (hovering ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SearchResults: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    let query: String
    let done: () -> Void

    var body: some View {
        let results = SettingsTopic.matches(query)
        VStack(alignment: .leading, spacing: 1) {
            if results.isEmpty {
                Text("No settings match “\(query)”.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
            }
            ForEach(results) { topic in
                SearchRow(topic: topic) {
                    navigator.show(topic.pane, spotlight: topic.anchor)
                    done()
                }
            }
        }
    }
}

private struct SearchRow: View {
    let topic: SettingsTopic
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PaneIcon(symbol: topic.pane.symbol, color: topic.pane.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(topic.title)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Text(topic.pane.title)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.07 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Search

/// One setting search can find. `anchor` names the row to spotlight.
struct SettingsTopic: Identifiable {
    let title: String
    let pane: SettingsView.Pane
    let anchor: String
    /// Other words people would use for it.
    var keywords = ""

    var id: String { anchor }

    /// The topics that have every word of `query`, best first: a match at the
    /// start of the title beats one anywhere else.
    static func matches(_ query: String) -> [SettingsTopic] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        return all
            .filter { topic in
                let text = "\(topic.title) \(topic.keywords) \(topic.pane.title)".lowercased()
                return words.allSatisfy(text.contains)
            }
            .sorted { first, second in
                first.title.lowercased().hasPrefix(words[0]) && !second.title.lowercased().hasPrefix(words[0])
            }
    }

    static let all: [SettingsTopic] = [
        SettingsTopic(title: "Open at login", pane: .general, anchor: "openAtLogin", keywords: "startup start launch boot automatically autostart restart"),
        SettingsTopic(title: "Replace the macOS Dock", pane: .general, anchor: "replaceDock", keywords: "hide system dock disable remove built-in apple"),
        SettingsTopic(title: "Restore the macOS Dock on quit", pane: .general, anchor: "restoreOnQuit", keywords: "system dock back"),
        SettingsTopic(title: "Check for updates", pane: .general, anchor: "updates", keywords: "new version upgrade daily"),
        SettingsTopic(title: "Export or import settings", pane: .general, anchor: "backup", keywords: "backup move another mac transfer restore file"),

        SettingsTopic(title: "Theme", pane: .appearance, anchor: "themes", keywords: "glass liquid aurora midnight sunset mirror minimal look style custom new import export"),
        SettingsTopic(title: "Icon size", pane: .appearance, anchor: "iconSize", keywords: "big small tile scale"),
        SettingsTopic(title: "Magnification", pane: .appearance, anchor: "magnification", keywords: "zoom enlarge grow hover reach amount"),
        SettingsTopic(title: "Running indicators", pane: .appearance, anchor: "indicators", keywords: "dots lines glow open apps lights"),
        SettingsTopic(title: "Accent colour", pane: .appearance, anchor: "accent", keywords: "color tint highlight"),
        SettingsTopic(title: "App names on hover", pane: .appearance, anchor: "labels", keywords: "labels titles tooltips"),
        SettingsTopic(title: "Reflections", pane: .appearance, anchor: "reflections", keywords: "mirror floor"),
        SettingsTopic(title: "Dim icons of hidden apps", pane: .appearance, anchor: "dimHidden", keywords: "translucent faded"),
        SettingsTopic(title: "Bounce when opening apps", pane: .appearance, anchor: "bounce", keywords: "animation launch motion"),
        SettingsTopic(title: "Ripple when clicking", pane: .appearance, anchor: "ripple", keywords: "effect animation motion"),
        SettingsTopic(title: "Animation speed", pane: .appearance, anchor: "speed", keywords: "motion fast slow"),

        SettingsTopic(title: "Position on screen", pane: .behavior, anchor: "position", keywords: "left right bottom side edge"),
        SettingsTopic(title: "Which display", pane: .behavior, anchor: "display", keywords: "monitor screen external multiple follow pointer mouse"),
        SettingsTopic(title: "Automatically hide", pane: .behavior, anchor: "autoHide", keywords: "auto-hide autohide overlap reveal delay"),
        SettingsTopic(title: "Show in full-screen spaces", pane: .behavior, anchor: "fullScreen", keywords: "fullscreen"),
        SettingsTopic(title: "Running apps not kept in the dock", pane: .behavior, anchor: "runningApps", keywords: "open apps contents"),
        SettingsTopic(title: "Recently used apps", pane: .behavior, anchor: "recentApps", keywords: "recents contents"),
        SettingsTopic(title: "Show the Trash", pane: .behavior, anchor: "trash", keywords: "bin contents"),
        SettingsTopic(title: "Click the frontmost app to hide it", pane: .behavior, anchor: "clickToHide", keywords: "minimize toggle"),

        SettingsTopic(title: "Profiles", pane: .apps, anchor: "profiles", keywords: "work personal sets switch focus"),
        SettingsTopic(title: "Apps in the dock", pane: .apps, anchor: "dockItems", keywords: "reorder remove pin keep icon change custom"),
        SettingsTopic(title: "Add apps, spacers, dividers, folders", pane: .apps, anchor: "addItems", keywords: "share tile stack downloads import"),

        SettingsTopic(title: "Double-click an app", pane: .shortcuts, anchor: "doubleClick", keywords: "double click action quick menu commands new window"),
        SettingsTopic(title: "Your shortcuts", pane: .shortcuts, anchor: "yourShortcuts", keywords: "custom website link url file folder add app"),
        SettingsTopic(title: "Open apps from the keyboard", pane: .shortcuts, anchor: "keyboard", keywords: "hotkey key combination launch number control option command"),

        SettingsTopic(title: "Show when the Trash is full", pane: .extras, anchor: "trashFull", keywords: "bin"),
        SettingsTopic(title: "Notification badges", pane: .extras, anchor: "badges", keywords: "unread counts numbers accessibility"),
        SettingsTopic(title: "Minimized windows in the dock", pane: .extras, anchor: "minimized", keywords: "minimised accessibility"),
        SettingsTopic(title: "Window previews", pane: .extras, anchor: "previews", keywords: "thumbnails screen recording hover"),

        SettingsTopic(title: "Tune the macOS Dock", pane: .systemDock, anchor: "tune", keywords: "minimize effect genie scale suck recents indicators auto-hide delay"),

        SettingsTopic(title: "App Sandbox and network", pane: .privacy, anchor: "thisApp", keywords: "security signature hardened runtime"),
        SettingsTopic(title: "Verify app integrity", pane: .privacy, anchor: "helper", keywords: "helper tamper signature"),
        SettingsTopic(title: "Permissions", pane: .privacy, anchor: "permissions", keywords: "accessibility screen recording automation"),

        SettingsTopic(title: "Version", pane: .about, anchor: "aboutHero", keywords: "about build"),
    ]
}
