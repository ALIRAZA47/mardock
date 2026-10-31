import AppKit
import MarDockCore
import SwiftUI

struct AboutPane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var themes: ThemeStore

    var body: some View {
        SettingsPage(.about) {
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 104, height: 104)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 7)
                Text("MarDock")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Version \(AppInfo.version) (\(AppInfo.build))")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .textSelection(.enabled)
                    .opacity(0.8)
                Text("A dock that's fluid, beautiful — and private by design.")
                    .font(.system(size: 13.5))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: heroColors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .settingAnchor("aboutHero")

            SettingsSection("Updates") {
                UpdatesRows()
            }

            SettingsSection(footer: "Built with Swift, AppKit and Core Animation. No third-party code. The dock itself has no network access.") {
                link("Release notes", symbol: "doc.text", url: UpdateSource.releasesPage)
                link("MarDock on GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: UpdateSource.repositoryPage)
            }
        }
    }

    /// The theme in use, darkened enough to read white text on.
    private var heroColors: [Color] {
        let swatch = themes.recipe(for: store.settings).swatch.map { NSColor(themeColor: $0) }
        let colors = swatch.count >= 2 ? swatch : [NSColor.systemIndigo, NSColor.systemPurple]
        return colors.map { Color(nsColor: $0.mixed(with: .black, amount: 0.35)) }
    }

    private func link(_ title: String, symbol: String, url: URL) -> some View {
        SettingRow(title) {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Open \(title)"))
        }
    }
}
