import AppKit
import MarDockCore
import SwiftUI

struct ExtrasPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var extras: ExtrasMonitor

    var body: some View {
        SettingsPage(.extras) {
            SettingsSection(footer: "These stay off until you turn them on. Badges and minimized windows need Accessibility, which lets MarDock's helper read the badges on the macOS Dock and the titles of minimized windows, and bring a window back when you click it. Previews need Screen Recording: MarDock takes small pictures of the app you're pointing at, shows them and keeps nothing.") {
                ToggleRow(
                    "Show when the Trash is full",
                    detail: "Reads only how many items are in the Trash, never what they are.",
                    isOn: $store.settings.showTrashFull
                )
                .settingAnchor("trashFull")
                ExtraToggle(
                    title: "Notification badges",
                    detail: "The numbers apps put on their Dock icons, such as unread mail.",
                    isOn: $store.settings.showBadges,
                    permission: .accessibility
                )
                .settingAnchor("badges")
                ExtraToggle(
                    title: "Minimized windows in the dock",
                    detail: "Next to the Trash, as in the macOS Dock. Click one to bring it back.",
                    isOn: $store.settings.showMinimizedWindows,
                    permission: .accessibility
                )
                .settingAnchor("minimized")
                ExtraToggle(
                    title: "Window previews",
                    detail: "Rest the pointer on a running app to see its windows, and click one to bring it forward.",
                    isOn: $store.settings.windowPreviews,
                    permission: .screenRecording
                )
                .settingAnchor("previews")
            }
        }
        .onAppear { extras.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            extras.refreshPermissions()
        }
    }
}

/// A switch for an extra that needs a permission, which says when the
/// permission is missing and where to give it.
private struct ExtraToggle: View {
    enum Permission { case accessibility, screenRecording }

    let title: String
    let detail: String
    @Binding var isOn: Bool
    let permission: Permission
    @EnvironmentObject private var extras: ExtrasMonitor

    private var allowed: Bool {
        permission == .accessibility ? extras.accessibilityTrusted : extras.screenRecordingAllowed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title, detail: detail, isOn: Binding(get: { isOn }, set: { on in
                isOn = on
                if on && !allowed { request() }
            }))
            if isOn && !allowed {
                Callout(text: permission == .accessibility ? "Allow MarDock in Accessibility to use this." : "Allow MarDock in Screen Recording to use this.") {
                    Button("Open System Settings…") {
                        ExtrasMonitor.openPrivacySettings(permission == .accessibility ? "Accessibility" : "ScreenCapture")
                    }
                }
                .padding([.horizontal, .bottom], 10)
            }
        }
    }

    private func request() {
        switch permission {
        case .accessibility: extras.requestAccessibility()
        case .screenRecording: extras.requestScreenRecording()
        }
    }
}
