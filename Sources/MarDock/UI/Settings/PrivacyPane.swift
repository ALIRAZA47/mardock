import MarDockCore
import SwiftUI

struct PrivacyPane: View {
    @EnvironmentObject private var security: SecurityStatus
    @EnvironmentObject private var updates: UpdateController
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var extras: ExtrasMonitor

    var body: some View {
        SettingsPage(.privacy) {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(LinearGradient(colors: [.green, .teal], startPoint: .top, endPoint: .bottom))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Private and secure by design")
                        .font(.system(size: 15, weight: .semibold))
                    Text("The dock never connects to the internet, MarDock collects nothing, and it needs no special permissions unless you use something that does. Everything below is read live from macOS — not just claimed.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsCard()

            SettingsSection("This app") {
                let snapshot = security.snapshot
                status(
                    title: "App Sandbox",
                    ok: snapshot.sandboxed,
                    detail: snapshot.sandboxed
                        ? "On. MarDock can't read your files, your other apps' data or anything outside its own container, except files you pick yourself in an Open or Save panel."
                        : "Off. This looks like a development build run outside its app bundle."
                )
                status(
                    title: "Network access",
                    ok: !snapshot.networkEntitled,
                    detail: snapshot.networkEntitled
                        ? "This build is entitled to use the network."
                        : "None. The dock has no network entitlement, so the sandbox blocks every connection."
                )
                status(
                    title: "Update checks",
                    ok: true,
                    detail: updates.checksAutomatically
                        ? "Once a day, and when you choose Check for Updates. A separate sandboxed updater asks GitHub for MarDock’s newest release; it can reach nothing else and sends nothing about you."
                        : "Only when you choose Check for Updates. A separate sandboxed updater asks GitHub for MarDock’s newest release; it can reach nothing else and sends nothing about you."
                )
                status(title: "Code signature", ok: snapshot.signature.isValid, detail: signatureText(snapshot.signature))
                status(
                    title: "Hardened Runtime",
                    ok: snapshot.signature.hasHardenedRuntime,
                    detail: snapshot.signature.hasHardenedRuntime
                        ? "On, with no exceptions. Code injection, unsigned libraries and debugger attachment are blocked."
                        : "Off for this build."
                )
            }
            .settingAnchor("thisApp")

            SettingsSection(
                "Helper",
                footer: "The sandbox stops MarDock from quitting or hiding other apps and from changing the macOS Dock, so a tiny helper does exactly those things and nothing more."
            ) {
                if let helper = security.helper {
                    status(
                        title: "Helper connection",
                        ok: !helper.isSandboxed,
                        detail: "Connected (protocol v\(helper.protocolVersion)). It only accepts connections from code matching this exact app’s signature."
                    )
                } else {
                    status(title: "Helper connection", ok: security.helperError == nil ? nil : false, detail: security.helperError ?? "Checking…")
                }
                status(
                    title: "What the helper may do",
                    ok: true,
                    detail: "Quit, hide or show an app you choose, change the \(SystemDockSchema.keys.count) macOS Dock settings it knows, read which apps are in your macOS Dock, open the Trash and say whether it's empty, and install an update you chose once it has checked the download and its signature. With Accessibility allowed it also reads the macOS Dock's badges and the titles of minimized windows and brings back the window you click, for the extras you turn on, and lists the New and Open commands in an app's File menu when you double-click it, and chooses the one you click. Every request is validated; anything else is refused."
                )
                RowBox {
                    HStack(spacing: 10) {
                        Button {
                            Task { await security.verify() }
                        } label: {
                            Label("Verify App Integrity", systemImage: "checkmark.shield")
                        }
                        .controlSize(.small)
                        .disabled(security.isVerifying)
                        if security.isVerifying { ProgressView().controlSize(.small) }
                        Spacer(minLength: 0)
                    }
                }
                if let report = security.integrity {
                    status(
                        title: report.appSignatureValid && report.helperSignatureValid ? "Integrity verified" : "Integrity problem",
                        ok: report.appSignatureValid && report.helperSignatureValid,
                        detail: integrityText(report)
                    )
                }
            }
            .settingAnchor("helper")

            SettingsSection("Permissions", footer: "Turn these on or off in Extras and Shortcuts.") {
                let s = store.settings
                let usesAccessibility = s.showBadges || s.showMinimizedWindows
                status(
                    title: "Accessibility",
                    ok: usesAccessibility ? extras.accessibilityTrusted : true,
                    detail: accessibilityText(usesExtras: usesAccessibility)
                )
                status(
                    title: "Screen Recording",
                    ok: s.windowPreviews ? extras.screenRecordingAllowed : true,
                    detail: s.windowPreviews
                        ? (extras.screenRecordingAllowed ? "Allowed, for window previews, which you turned on. Pictures are taken only while you point at an app, and never kept." : "Not allowed yet; window previews need it.")
                        : "Not used. Only window previews need it, and they're off."
                )
                status(
                    title: "Automation",
                    ok: true,
                    detail: "Only for Finder, and only the first time you choose Empty Trash: MarDock asks Finder to empty it, as the macOS Dock does. The sandbox lets MarDock send Finder that command and no other."
                )
                RowBox {
                    Text("Never asked for: Input Monitoring · Full Disk Access · Contacts, Calendars, Photos, Location, Camera and Microphone")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingAnchor("permissions")

            SettingsSection("Your data") {
                RowBox {
                    Text("Your settings, what you keep in your dock, the recent apps list and any icons you pick are stored only on this Mac, inside MarDock’s sandbox container. No analytics, no crash reporting, no accounts, and no update checks unless you ask for one or turn on the daily check.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task { await security.refreshHelper() }
        .onAppear { extras.refreshPermissions() }
    }

    private func status(title: String, ok: Bool?, detail: String) -> some View {
        RowBox {
            StatusRow(title: title, ok: ok, detail: detail)
        }
    }

    private func accessibilityText(usesExtras: Bool) -> String {
        if usesExtras {
            return extras.accessibilityTrusted
                ? "Allowed, for badges and minimized windows, which you turned on, and for apps' own commands on the shortcuts panel."
                : "Not allowed yet; badges and minimized windows need it."
        }
        return extras.accessibilityTrusted
            ? "Allowed, for apps' own commands on the shortcuts panel."
            : "Not used unless you turn on badges or minimized windows, or allow it for apps' own commands on the shortcuts panel."
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
