import MarDockCore
import SwiftUI

/// First-run onboarding: a live preview, the three promises, three choices.
struct WelcomeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var store: SettingsStore
    @State private var importDock = true
    @State private var hideSystemDock = true
    @State private var openAtLogin = true
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                DockPreviewCard(settings: store.settings)
                    .frame(height: 230)
                LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .center)
                    .allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to MarDock")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("A dock that's fluid, beautiful — and private by design.")
                        .font(.title3)
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .padding(.horizontal, 28)
                .padding(.top, 34)
                .allowsHitTesting(false)
            }
            .frame(height: 230)

            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    symbol: "sparkles",
                    color: .purple,
                    title: "Fluid and alive",
                    text: "Physically based magnification, launch bounces and ripples, rendered at your display's full refresh rate — and close to zero CPU when idle."
                )
                FeatureRow(
                    symbol: "paintpalette.fill",
                    color: .orange,
                    title: "Seven themes",
                    text: "Frosted glass, Liquid, Aurora, Midnight neon, Sunset, Mirror and Minimal. Right-click the dock to switch any time."
                )
                FeatureRow(
                    symbol: "lock.shield.fill",
                    color: .green,
                    title: "Secure by design",
                    text: "The dock runs in the App Sandbox with no network access and no special permissions. A tiny, locked-down helper does the few things the sandbox can't."
                )

                Divider().padding(.vertical, 2)

                Toggle("Bring over the apps from my current Dock", isOn: $importDock)
                Toggle("Hide the macOS Dock while MarDock is running", isOn: $hideSystemDock)
                Toggle("Open MarDock at login", isOn: $openAtLogin)
                Text("You can change all of this later in Settings. MarDock saves your macOS Dock settings before changing them and restores them when you quit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 12)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button {
                    coordinator.completeOnboarding(importDock: importDock, hideSystemDock: hideSystemDock, openAtLogin: openAtLogin)
                } label: {
                    Text("Get Started")
                        .frame(minWidth: 140)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
        .frame(minWidth: 680, minHeight: 620)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.15)) { appeared = true }
        }
    }
}
