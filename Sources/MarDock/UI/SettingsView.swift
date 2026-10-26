import AppKit
import MarDockCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case appearance, behavior, apps, systemDock, privacy, about

        var id: Self { self }

        var title: String {
            switch self {
            case .appearance: return "Appearance"
            case .behavior: return "Behaviour"
            case .apps: return "Apps"
            case .systemDock: return "macOS Dock"
            case .privacy: return "Privacy & Security"
            case .about: return "About"
            }
        }

        var symbol: String {
            switch self {
            case .appearance: return "paintpalette.fill"
            case .behavior: return "cursorarrow.motionlines"
            case .apps: return "square.grid.2x2.fill"
            case .systemDock: return "dock.rectangle"
            case .privacy: return "lock.shield.fill"
            case .about: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .appearance: return .pink
            case .behavior: return .blue
            case .apps: return .orange
            case .systemDock: return .indigo
            case .privacy: return .green
            case .about: return .gray
            }
        }
    }

    @State private var selection: Pane? = .appearance

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label {
                    Text(pane.title)
                } icon: {
                    PaneIcon(symbol: pane.symbol, color: pane.color)
                }
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            Group {
                switch selection ?? .appearance {
                case .appearance: AppearancePane()
                case .behavior: BehaviorPane()
                case .apps: AppsPane()
                case .systemDock: SystemDockPane()
                case .privacy: PrivacyPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((selection ?? .appearance).title)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showAboutPane)) { _ in
            selection = .about
        }
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        Form {
            Section {
                DockPreviewCard(settings: store.settings)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            } footer: {
                FooterText("This preview is live — hover over it and click the icons.")
            }

            Section("Theme") {
                ThemeGallery(selection: $store.settings.theme)
                Text(store.settings.theme.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Icons") {
                SettingSlider(title: "Size", value: $store.settings.iconSize, range: DockSettings.iconSizeRange, step: 2) { "\(Int($0)) pt" }
                Toggle("Magnification", isOn: $store.settings.magnificationEnabled)
                SettingSlider(title: "Magnification amount", value: $store.settings.magnification, range: DockSettings.magnificationRange) {
                    String(format: "%.1f×", $0)
                }
                .disabled(!store.settings.magnificationEnabled)
                SettingSlider(title: "Magnification reach", value: $store.settings.magnificationSpread, range: DockSettings.spreadRange) {
                    String(format: "%.1f", $0)
                }
                .disabled(!store.settings.magnificationEnabled)
            }

            Section("Details") {
                Picker("Running indicators", selection: $store.settings.indicatorStyle) {
                    Text("Glow").tag(IndicatorStyle.glow)
                    Text("Dots").tag(IndicatorStyle.dot)
                    Text("Lines").tag(IndicatorStyle.line)
                    Text("None").tag(IndicatorStyle.none)
                }
                AccentPicker(selection: $store.settings.accent)
                Toggle("Show app names on hover", isOn: $store.settings.showLabels)
                Toggle("Reflections", isOn: $store.settings.reflections)
                    .disabled(store.settings.theme == .mirror || store.settings.position != .bottom)
                Toggle("Dim icons of hidden apps", isOn: $store.settings.dimHiddenApps)
            }

            Section {
                Toggle("Bounce when opening apps", isOn: $store.settings.bounceOnLaunch)
                Toggle("Ripple when clicking", isOn: $store.settings.clickRipple)
                SettingSlider(title: "Animation speed", value: $store.settings.animationSpeed, range: DockSettings.animationSpeedRange) {
                    String(format: "%.1f×", $0)
                }
            } header: {
                Text("Motion")
            } footer: {
                FooterText("With “Reduce motion” turned on in Accessibility settings, MarDock skips bounces and particle effects automatically.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Behaviour

struct BehaviorPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var loginItem: LoginItemManager

    var body: some View {
        Form {
            Section("Position") {
                Picker("Position on screen", selection: $store.settings.position) {
                    Text("Left").tag(DockPosition.left)
                    Text("Bottom").tag(DockPosition.bottom)
                    Text("Right").tag(DockPosition.right)
                }
                .pickerStyle(.segmented)
                Picker("Display", selection: $store.settings.display) {
                    Text("Main display").tag(DisplayPreference.main)
                    Text("Follow the pointer").tag(DisplayPreference.followMouse)
                }
            }

            Section {
                Picker("Automatically hide", selection: $store.settings.autoHide) {
                    Text("Never").tag(AutoHideMode.off)
                    Text("Always").tag(AutoHideMode.always)
                    Text("When a window overlaps").tag(AutoHideMode.smart)
                }
                SettingSlider(title: "Reveal delay", value: $store.settings.revealDelay, range: DockSettings.revealDelayRange) {
                    String(format: "%.2f s", $0)
                }
                .disabled(store.settings.autoHide == .off)
                Toggle("Show in full-screen spaces", isOn: $store.settings.showInFullScreen)
            } header: {
                Text("Hiding")
            } footer: {
                FooterText("“When a window overlaps” keeps the dock visible until the app you're using puts a window over it. Push the pointer against the screen edge to bring a hidden dock back.")
            }

            Section("Contents") {
                Toggle("Show running apps that aren't kept in the dock", isOn: $store.settings.showRunningApps)
                Toggle("Show the Trash", isOn: $store.settings.showTrash)
                Toggle("Clicking the frontmost app hides it", isOn: $store.settings.clickToHide)
            }

            Section {
                Toggle("Open MarDock at login", isOn: Binding(
                    get: { loginItem.isEnabled || loginItem.needsApproval },
                    set: { loginItem.setEnabled($0) }
                ))
                if loginItem.needsApproval {
                    HStack {
                        Text("Approve MarDock in System Settings to finish.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items…") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginItem.refresh() }
    }
}

// MARK: - Apps

struct AppsPane: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var pins: PinStore
    @State private var importMessage: String?

    var body: some View {
        Form {
            Section {
                AppRow(name: "Finder", path: "Always first", icon: icon(forBundle: DockIdentity.finderBundleIdentifier), removable: false) {}
                ForEach(pins.pins) { pin in
                    AppRow(name: pin.name, path: pin.path, icon: NSWorkspace.shared.icon(forFile: pin.path), removable: true) {
                        withAnimation { pins.unpin(pin.id) }
                    }
                }
                .onMove { from, to in
                    var list = pins.pins
                    list.move(fromOffsets: from, toOffset: to)
                    pins.setPins(list)
                }
            } header: {
                Text("Kept in the dock")
            } footer: {
                FooterText("Drag rows to reorder. You can also drag apps from Finder onto the dock, drag icons along the dock, or drag one off to remove it.")
            }

            Section {
                HStack(spacing: 10) {
                    Button {
                        addApps()
                    } label: {
                        Label("Add Apps…", systemImage: "plus")
                    }
                    Button {
                        Task {
                            let count = await coordinator.importFromSystemDock()
                            importMessage = count > 0 ? "Imported \(count) apps from the macOS Dock." : "Couldn't read the macOS Dock's apps."
                        }
                    } label: {
                        Label("Import from macOS Dock", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                }
                if let importMessage {
                    Text(importMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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

private struct AppRow: View {
    let name: String
    let path: String
    let icon: NSImage
    let removable: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if removable {
                Button(action: remove) {
                    Image(systemName: "minus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Remove from dock")
                .accessibilityLabel(Text("Remove \(name)"))
            }
        }
    }
}

// MARK: - macOS Dock

struct SystemDockPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var systemDock: SystemDockManager
    @State private var draft = SystemDockDraft()
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $store.settings.hideSystemDock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Replace the macOS Dock")
                        Text("Hides the built-in Dock while MarDock runs. Your original settings are saved first and put back when you turn this off.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Restore the macOS Dock when MarDock quits", isOn: $store.settings.restoreSystemDockOnQuit)
                    .disabled(!store.settings.hideSystemDock)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        if systemDock.isBusy { ProgressView().controlSize(.small) }
                        Text(statusText).foregroundStyle(.secondary)
                    }
                }
                if systemDock.isHiddenByMarDock && !store.settings.hideSystemDock {
                    Button("Restore the macOS Dock Now") {
                        Task { await systemDock.restore() }
                    }
                }
            } header: {
                Text("Replace")
            }

            Section {
                Picker("Minimize effect", selection: $draft.minimizeEffect) {
                    Text("Genie").tag("genie")
                    Text("Scale").tag("scale")
                    Text("Suck").tag("suck")
                }
                Toggle("Minimize windows into their app's icon", isOn: $draft.minimizeToApp)
                Toggle("Show suggested and recent apps", isOn: $draft.showRecents)
                Toggle("Animate opening apps", isOn: $draft.launchAnimation)
                Toggle("Show indicators for open apps", isOn: $draft.indicators)
                Toggle("Make icons of hidden apps translucent", isOn: $draft.dimHidden)
                Toggle("Scroll up on an icon to show its windows", isOn: $draft.scrollToOpen)
                SettingSlider(title: "Auto-hide delay", value: $draft.autohideDelay, range: 0...2) { String(format: "%.2f s", $0) }
                    .disabled(store.settings.hideSystemDock)
                SettingSlider(title: "Auto-hide animation", value: $draft.autohideSpeed, range: 0...2) { String(format: "%.2f s", $0) }
                HStack {
                    Button("Apply Changes") {
                        Task {
                            await systemDock.apply(draft.changes(comparedTo: systemDock.values, keepHidingKeys: store.settings.hideSystemDock))
                            draft = SystemDockDraft(values: systemDock.values)
                        }
                    }
                    .disabled(systemDock.isBusy || draft.changes(comparedTo: systemDock.values, keepHidingKeys: store.settings.hideSystemDock).isEmpty)
                    Button("Reset to macOS Defaults") {
                        Task {
                            await systemDock.resetTweaks()
                            draft = SystemDockDraft(values: systemDock.values)
                        }
                    }
                    .disabled(systemDock.isBusy)
                    Spacer()
                }
            } header: {
                Text("Tune the macOS Dock")
            } footer: {
                FooterText("Applying restarts the macOS Dock, which takes a moment. MarDock's helper can only change the settings shown here — it refuses anything else.")
            }

            if let error = systemDock.lastError, !systemDock.isAvailable {
                Section {
                    StatusRow(title: "The helper isn't reachable", ok: false, detail: error)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await systemDock.refresh()
            if !loaded {
                draft = SystemDockDraft(values: systemDock.values)
                loaded = true
            }
        }
    }

    private var statusText: String {
        if !systemDock.isAvailable { return "Unknown" }
        if systemDock.looksHidden { return systemDock.isHiddenByMarDock ? "Hidden by MarDock" : "Hidden" }
        return "Visible"
    }
}

/// Editable copy of the macOS Dock tweaks, compared against the live values
/// so only real changes are sent.
struct SystemDockDraft: Equatable {
    var minimizeEffect = "genie"
    var minimizeToApp = false
    var showRecents = true
    var launchAnimation = true
    var indicators = true
    var dimHidden = false
    var scrollToOpen = false
    var autohideDelay = 0.5
    var autohideSpeed = 0.5

    init() {}

    init(values: [String: SystemDockValue]) {
        if case let .string(v)? = values["mineffect"] { minimizeEffect = v }
        if case let .bool(v)? = values["minimize-to-application"] { minimizeToApp = v }
        if case let .bool(v)? = values["show-recents"] { showRecents = v }
        if case let .bool(v)? = values["launchanim"] { launchAnimation = v }
        if case let .bool(v)? = values["show-process-indicators"] { indicators = v }
        if case let .bool(v)? = values["showhidden"] { dimHidden = v }
        if case let .bool(v)? = values["scroll-to-open"] { scrollToOpen = v }
        if case let .number(v)? = values["autohide-delay"], v <= 2 { autohideDelay = v }
        if case let .number(v)? = values["autohide-time-modifier"], v <= 2 { autohideSpeed = v }
    }

    func changes(comparedTo values: [String: SystemDockValue], keepHidingKeys: Bool) -> [SystemDockChange] {
        let defaults = SystemDockDraft(values: values)
        var changes: [SystemDockChange] = []
        func add(_ key: String, _ value: SystemDockValue, _ changed: Bool) {
            if changed { changes.append(SystemDockChange(key: key, value: value)) }
        }
        add("mineffect", .string(minimizeEffect), minimizeEffect != defaults.minimizeEffect)
        add("minimize-to-application", .bool(minimizeToApp), minimizeToApp != defaults.minimizeToApp)
        add("show-recents", .bool(showRecents), showRecents != defaults.showRecents)
        add("launchanim", .bool(launchAnimation), launchAnimation != defaults.launchAnimation)
        add("show-process-indicators", .bool(indicators), indicators != defaults.indicators)
        add("showhidden", .bool(dimHidden), dimHidden != defaults.dimHidden)
        add("scroll-to-open", .bool(scrollToOpen), scrollToOpen != defaults.scrollToOpen)
        if !keepHidingKeys {
            add("autohide-delay", .number((autohideDelay * 100).rounded() / 100), abs(autohideDelay - defaults.autohideDelay) > 0.004)
        }
        add("autohide-time-modifier", .number((autohideSpeed * 100).rounded() / 100), abs(autohideSpeed - defaults.autohideSpeed) > 0.004)
        return changes
    }
}

// MARK: - Privacy & Security

struct PrivacyPane: View {
    @EnvironmentObject private var security: SecurityStatus

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(LinearGradient(colors: [.green, .teal], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .green.opacity(0.3), radius: 8, y: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Private and secure by design").font(.title3.weight(.semibold))
                        Text("MarDock never connects to the internet, collects nothing, and needs no special permissions. Everything below is read live from macOS — not just claimed.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("This app") {
                let snapshot = security.snapshot
                StatusRow(
                    title: "App Sandbox",
                    ok: snapshot.sandboxed,
                    detail: snapshot.sandboxed
                        ? "On. MarDock can't read your files, your other apps' data or anything outside its own container."
                        : "Off. This looks like a development build run outside its app bundle."
                )
                StatusRow(
                    title: "Network access",
                    ok: !snapshot.networkEntitled,
                    detail: snapshot.networkEntitled
                        ? "This build is entitled to use the network."
                        : "None. MarDock has no network entitlement, so the sandbox blocks every connection."
                )
                StatusRow(title: "Code signature", ok: snapshot.signature.isValid, detail: signatureText(snapshot.signature))
                StatusRow(
                    title: "Hardened Runtime",
                    ok: snapshot.signature.hasHardenedRuntime,
                    detail: snapshot.signature.hasHardenedRuntime
                        ? "On, with no exceptions. Code injection, unsigned libraries and debugger attachment are blocked."
                        : "Off for this build."
                )
            }

            Section {
                if let helper = security.helper {
                    StatusRow(
                        title: "Helper connection",
                        ok: !helper.isSandboxed,
                        detail: "Connected (protocol v\(helper.protocolVersion)). It only accepts connections from code matching this exact app’s signature."
                    )
                } else {
                    StatusRow(title: "Helper connection", ok: security.helperError == nil ? nil : false, detail: security.helperError ?? "Checking…")
                }
                StatusRow(
                    title: "What the helper may do",
                    ok: true,
                    detail: "Quit, hide or show an app you choose, change the 15 macOS Dock settings listed in this window, read which apps are in your macOS Dock, and open the Trash. Every request is validated; anything else is refused."
                )
                HStack {
                    Button {
                        Task { await security.verify() }
                    } label: {
                        Label("Verify App Integrity", systemImage: "checkmark.shield")
                    }
                    .disabled(security.isVerifying)
                    if security.isVerifying { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let report = security.integrity {
                    StatusRow(
                        title: report.appSignatureValid && report.helperSignatureValid ? "Integrity verified" : "Integrity problem",
                        ok: report.appSignatureValid && report.helperSignatureValid,
                        detail: integrityText(report)
                    )
                }
            } header: {
                Text("Helper")
            } footer: {
                FooterText("The sandbox stops MarDock from quitting or hiding other apps and from changing the macOS Dock, so a tiny helper does exactly those things and nothing more.")
            }

            Section("Permissions MarDock never asks for") {
                Text("Accessibility · Screen Recording · Input Monitoring · Full Disk Access · Automation · Contacts, Calendars, Photos, Location, Camera and Microphone")
                    .foregroundStyle(.secondary)
            }

            Section("Your data") {
                Text("Your settings and the list of apps in your dock are stored only on this Mac, inside MarDock’s sandbox container. No analytics, no crash reporting, no update checks, no accounts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await security.refreshHelper() }
    }

    private func signatureText(_ signature: CodeSignatureInfo) -> String {
        guard signature.isValid else { return "Not valid: \(signature.status)" }
        if signature.isAdHoc {
            return "Valid, signed on this Mac (ad-hoc). Build with a Developer ID to distribute."
        }
        if let team = signature.teamIdentifier {
            return "Valid, signed with Developer ID (team \(team))."
        }
        return "Valid."
    }

    private func integrityText(_ report: IntegrityReport) -> String {
        var parts = [
            report.appSignatureValid ? "App bundle unmodified" : "App bundle signature invalid: \(report.detail)",
            report.helperSignatureValid ? "helper unmodified" : "helper signature invalid",
            report.hardenedRuntime ? "Hardened Runtime on" : "Hardened Runtime off",
        ]
        if let team = report.teamIdentifier, !report.isAdHoc {
            parts.append("team \(team)")
        } else {
            parts.append("ad-hoc signature")
        }
        return parts.joined(separator: " · ") + "."
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 20)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
            Text("MarDock")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Version \(AppInfo.version) (\(AppInfo.build))")
                .foregroundStyle(.secondary)
            Text("A dock that's fluid, beautiful — and private by design.")
                .font(.title3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Text("Built with Swift, AppKit and Core Animation. No third-party code, no network access.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer(minLength: 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
