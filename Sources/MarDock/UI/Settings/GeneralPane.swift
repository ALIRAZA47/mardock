import AppKit
import MarDockCore
import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var navigator: SettingsNavigator
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var systemDock: SystemDockManager
    @State private var backupMessage: String?

    var body: some View {
        SettingsPage(.general) {
            HStack(alignment: .top, spacing: 14) {
                FeatureTile(
                    symbol: "power",
                    colors: [.green, .teal],
                    title: "Open at login",
                    detail: loginItem.summary,
                    isOn: Binding(get: { loginItem.isOn }, set: { loginItem.setEnabled($0) })
                )
                .settingAnchor("openAtLogin")
                FeatureTile(
                    symbol: "dock.rectangle",
                    colors: [.indigo, .purple],
                    title: "Replace the macOS Dock",
                    detail: dockSummary,
                    isOn: $store.settings.hideSystemDock
                )
                .settingAnchor("replaceDock")
            }

            if loginItem.needsApproval {
                Callout(text: "Approve MarDock in System Settings to finish.") {
                    Button("Open Login Items…") { loginItem.openSystemSettings() }
                }
            }
            if let error = loginItem.lastError {
                Callout(text: "macOS wouldn't add MarDock to your login items: \(error)")
            }
            if loginItem.isOn && !loginItem.isInApplicationsFolder {
                Callout(symbol: "folder.fill", text: "MarDock is running from outside your Applications folder. Move it there so it's still around at your next login.")
            }

            SettingsSection("macOS Dock") {
                ToggleRow(
                    "Restore the macOS Dock when MarDock quits",
                    detail: "Otherwise it stays hidden until MarDock next opens.",
                    isOn: $store.settings.restoreSystemDockOnQuit
                )
                .disabled(!store.settings.hideSystemDock)
                .settingAnchor("restoreOnQuit")
                SettingRow("Tune the macOS Dock", detail: "Its minimize effect, recent apps and other settings.") {
                    Button("Open…") { navigator.show(.systemDock) }
                        .controlSize(.small)
                }
            }

            SettingsSection("Updates") {
                UpdatesRows()
            }
            .settingAnchor("updates")

            SettingsSection(
                "Move to another Mac",
                footer: "Saves your dock, settings, themes, shortcuts and custom icons in one file. Importing replaces them; whether MarDock hides the macOS Dock stays as you set it on each Mac."
            ) {
                RowBox {
                    HStack(spacing: 10) {
                        Button {
                            exportSettings()
                        } label: {
                            Label("Export Settings…", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            importSettings()
                        } label: {
                            Label("Import Settings…", systemImage: "square.and.arrow.down")
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.small)
                }
                if let backupMessage {
                    RowBox {
                        Text(backupMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .settingAnchor("backup")
        }
        .onAppear { loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .task { await systemDock.refresh() }
    }

    private var dockSummary: String {
        if !systemDock.isAvailable, systemDock.lastError != nil {
            return "MarDock's helper isn't reachable, so this can't change anything yet."
        }
        if store.settings.hideSystemDock {
            return systemDock.looksHidden ? "Hidden. It's kept away from every screen, even when an app bounces for attention." : "Hiding it…"
        }
        return systemDock.looksHidden ? "Hidden." : "Showing alongside MarDock."
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MarDock Settings.json"
        panel.message = "MarDock saves your dock, settings, themes, shortcuts and custom icons to this file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = coordinator.makeBackup().encoded() else {
            backupMessage = "Couldn't put the settings together."
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            backupMessage = "Saved to “\(url.lastPathComponent)”."
        } catch {
            backupMessage = error.localizedDescription
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a file saved with Export Settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= MarDockBackup.maxBytes, let data = try? Data(contentsOf: url) else {
            backupMessage = "That file is empty or too large."
            return
        }
        let backup: MarDockBackup
        do {
            backup = try MarDockBackup.decode(data)
        } catch MarDockBackup.ReadError.newerVersion {
            backupMessage = "That file comes from a newer MarDock. Update MarDock to import it."
            return
        } catch {
            backupMessage = "That file isn't a MarDock settings file."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Replace your dock and settings?"
        alert.informativeText = "MarDock will use the \(backup.items.count) items, settings, \(backup.themes.count) themes and \(backup.icons.count) icons in “\(url.lastPathComponent)”. Your choices for the macOS Dock, the display and the extras stay as they are."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.apply(backup)
        backupMessage = "Imported “\(url.lastPathComponent)”."
    }
}

/// Check for Updates, the daily check, and an available update.
struct UpdatesRows: View {
    @EnvironmentObject private var updates: UpdateController

    var body: some View {
        RowBox {
            HStack(spacing: 10) {
                status
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                action
                    .controlSize(.small)
            }
        }
        ToggleRow(
            "Check for updates once a day",
            detail: "Asks GitHub for MarDock's newest release and sends nothing about you. A separate, sandboxed part of MarDock does it; the dock itself stays offline.",
            isOn: $updates.checksAutomatically
        )
    }

    @ViewBuilder private var status: some View {
        switch updates.phase {
        case .idle:
            Label(lastCheckedText ?? "Not checked yet", systemImage: "arrow.down.circle")
        case .checking:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…") }
        case .upToDate:
            Label("Up to date" + (lastCheckedText.map { " · \($0)" } ?? ""), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .available(release):
            Label("MarDock \(release.version) is available", systemImage: "sparkles")
                .foregroundStyle(.blue)
        case .downloading:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Downloading…") }
        case .installing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking and installing…") }
        case .relaunching:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Relaunching…") }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var action: some View {
        if case let .available(release) = updates.phase {
            Button("Release Notes") { updates.openReleasePage(release) }
            Button(release.installable ? "Install and Relaunch" : "Download…") { updates.install(release) }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Check Now") { Task { await updates.check(announce: .never) } }
                .disabled(updates.phase.isBusy)
        }
    }

    private var lastCheckedText: String? {
        guard let date = updates.lastChecked else { return nil }
        return "checked " + date.formatted(.relative(presentation: .named))
    }
}
