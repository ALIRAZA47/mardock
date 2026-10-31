import MarDockCore
import SwiftUI

struct SystemDockPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var systemDock: SystemDockManager
    @State private var draft = SystemDockDraft()
    @State private var loaded = false

    var body: some View {
        SettingsPage(.systemDock) {
            SettingsSection(
                "Replace",
                footer: "Hiding it takes more than auto-hide: MarDock also stops the Dock coming up when an app bounces for attention, and stops it moving between displays. Your original settings are saved first and put back when you turn this off."
            ) {
                ToggleRow(
                    "Replace the macOS Dock",
                    detail: "Hides the built-in Dock while MarDock runs.",
                    isOn: $store.settings.hideSystemDock
                )
                ToggleRow("Restore the macOS Dock when MarDock quits", isOn: $store.settings.restoreSystemDockOnQuit)
                    .disabled(!store.settings.hideSystemDock)
                SettingRow("Status") {
                    HStack(spacing: 6) {
                        if systemDock.isBusy { ProgressView().controlSize(.small) }
                        Text(statusText)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                if systemDock.isHiddenByMarDock && !store.settings.hideSystemDock {
                    RowBox {
                        Button("Restore the macOS Dock Now") {
                            Task { await systemDock.restore() }
                        }
                        .controlSize(.small)
                    }
                }
            }

            SettingsSection(
                "Tune the macOS Dock",
                footer: "Applying restarts the macOS Dock, which takes a moment. MarDock's helper can only change the settings shown here — it refuses anything else."
            ) {
                PickerRow("Minimize effect", selection: $draft.minimizeEffect) {
                    Text("Genie").tag("genie")
                    Text("Scale").tag("scale")
                    Text("Suck").tag("suck")
                }
                ToggleRow("Minimize windows into their app's icon", isOn: $draft.minimizeToApp)
                ToggleRow("Show suggested and recent apps", isOn: $draft.showRecents)
                ToggleRow("Animate opening apps", isOn: $draft.launchAnimation)
                ToggleRow("Show indicators for open apps", isOn: $draft.indicators)
                ToggleRow("Make icons of hidden apps translucent", isOn: $draft.dimHidden)
                ToggleRow("Scroll up on an icon to show its windows", isOn: $draft.scrollToOpen)
                SliderRow(title: "Auto-hide delay", value: $draft.autohideDelay, range: 0...2) { String(format: "%.2f s", $0) }
                    .disabled(store.settings.hideSystemDock)
                SliderRow(title: "Auto-hide animation", value: $draft.autohideSpeed, range: 0...2) { String(format: "%.2f s", $0) }
                RowBox {
                    HStack(spacing: 10) {
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
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }
            }
            .settingAnchor("tune")

            if let error = systemDock.lastError, !systemDock.isAvailable {
                SettingsSection {
                    RowBox {
                        StatusRow(title: "The helper isn't reachable", ok: false, detail: error)
                    }
                }
            }
        }
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
