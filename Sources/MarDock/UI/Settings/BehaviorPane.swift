import MarDockCore
import SwiftUI

struct BehaviorPane: View {
    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        SettingsPage(.behavior) {
            SettingsSection("Position") {
                RowBox {
                    HStack(spacing: 12) {
                        ForEach([DockPosition.left, .bottom, .right]) { position in
                            PositionChoice(position: position, selected: store.settings.position == position) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    store.update { $0.position = position }
                                }
                            }
                        }
                    }
                }
                .settingAnchor("position")
                PickerRow("Display", detail: displayDetail, selection: $store.settings.display) {
                    Text("Main display").tag(DisplayPreference.main)
                    Text("Follow the pointer").tag(DisplayPreference.followMouse)
                }
                .settingAnchor("display")
            }

            SettingsSection(
                "Hiding",
                footer: "“When a window overlaps” keeps the dock visible until the app you're using puts a window over it. Push the pointer against the screen edge to bring a hidden dock back."
            ) {
                PickerRow("Automatically hide", selection: $store.settings.autoHide) {
                    Text("Never").tag(AutoHideMode.off)
                    Text("Always").tag(AutoHideMode.always)
                    Text("When a window overlaps").tag(AutoHideMode.smart)
                }
                .settingAnchor("autoHide")
                if store.settings.autoHide != .off {
                    SliderRow(title: "Reveal delay", value: $store.settings.revealDelay, range: DockSettings.revealDelayRange) {
                        String(format: "%.2f s", $0)
                    }
                }
                ToggleRow("Show in full-screen spaces", isOn: $store.settings.showInFullScreen)
                    .settingAnchor("fullScreen")
            }

            SettingsSection("Contents") {
                ToggleRow("Show running apps that aren't kept in the dock", isOn: $store.settings.showRunningApps)
                    .settingAnchor("runningApps")
                ToggleRow("Show recently used apps", isOn: $store.settings.showRecentApps)
                    .settingAnchor("recentApps")
                if store.settings.showRecentApps {
                    SettingRow("Recent apps to show") {
                        Stepper(value: $store.settings.recentAppsCount, in: DockSettings.recentAppsRange) {
                            Text("\(store.settings.recentAppsCount)")
                                .font(.system(size: 12))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .controlSize(.small)
                    }
                }
                ToggleRow("Show the Trash", isOn: $store.settings.showTrash)
                    .settingAnchor("trash")
            }

            SettingsSection("Clicking") {
                ToggleRow(
                    "Clicking the frontmost app hides it",
                    detail: "With double-click shortcuts on, it hides a moment after the click, once it's clear no second click is coming.",
                    isOn: $store.settings.clickToHide
                )
                .settingAnchor("clickToHide")
            }
        }
    }

    private var displayDetail: String? {
        store.settings.display == .followMouse ? "Moves to the display where you push the pointer against the edge." : nil
    }
}

/// A small screen with the dock along one edge.
private struct PositionChoice: View {
    let position: DockPosition
    let selected: Bool
    let action: () -> Void

    private var title: String {
        switch position {
        case .left: return "Left"
        case .bottom: return "Bottom"
        case .right: return "Right"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    shelf
                }
                .frame(height: 66)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : SettingsStyle.hairline, lineWidth: selected ? 2 : 1)
                )
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Dock on the \(title.lowercased())"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shelf: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        return Group {
            switch position {
            case .bottom:
                shape.frame(width: 62, height: 9).frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 5)
            case .left:
                shape.frame(width: 9, height: 44).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 5)
            case .right:
                shape.frame(width: 9, height: 44).frame(maxWidth: .infinity, alignment: .trailing).padding(.trailing, 5)
            }
        }
        .foregroundStyle(selected ? Color.accentColor : Color.primary.opacity(0.42))
    }
}
