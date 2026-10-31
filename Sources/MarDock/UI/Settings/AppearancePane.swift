import AppKit
import MarDockCore
import SwiftUI
import UniformTypeIdentifiers

struct AppearancePane: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var themes: ThemeStore
    @State private var editing: ThemeRecipe?
    @State private var themeMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 150), spacing: 12)]

    var body: some View {
        let current = themes.recipe(for: store.settings)
        SettingsPage(.appearance) {
            DockPreviewCard(settings: store.settings, recipe: current)
                .frame(maxWidth: SettingsStyle.contentWidth)
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(SettingsStyle.hairline))
                .padding(.horizontal, SettingsStyle.gutter)
                .padding(.bottom, 12)
        } content: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Theme")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(current.isBuiltIn ? store.settings.theme.tagline : "One of your own. Right-click it to edit, duplicate, export or delete it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Import…") { importTheme() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 3)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ThemeCards(selection: current.isBuiltIn ? store.settings.theme : nil) { theme in
                        store.update {
                            $0.theme = theme
                            $0.customTheme = nil
                        }
                    }
                    ForEach(themes.custom) { recipe in
                        customCard(recipe, selected: current.id == recipe.id)
                    }
                    NewThemeCard {
                        editing = current.duplicate(named: current.isBuiltIn ? "My \(current.name)" : current.name + " Copy")
                    }
                }
                .padding(14)
                .settingsCard()
                if let themeMessage {
                    FooterText(themeMessage)
                        .padding(.horizontal, 3)
                }
            }
            .settingAnchor("themes")
            .sheet(item: $editing) { recipe in
                ThemeEditor(recipe: recipe)
                    .environmentObject(store)
                    .environmentObject(themes)
            }

            SettingsSection("Icons") {
                SliderRow(title: "Size", value: $store.settings.iconSize, range: DockSettings.iconSizeRange, step: 2) { "\(Int($0)) pt" }
                    .settingAnchor("iconSize")
                ToggleRow("Magnification", detail: "Icons grow as the pointer passes over them.", isOn: $store.settings.magnificationEnabled)
                    .settingAnchor("magnification")
                if store.settings.magnificationEnabled {
                    SliderRow(title: "Amount", value: $store.settings.magnification, range: DockSettings.magnificationRange) {
                        String(format: "%.1f×", $0)
                    }
                    SliderRow(title: "Reach", value: $store.settings.magnificationSpread, range: DockSettings.spreadRange) {
                        String(format: "%.1f", $0)
                    }
                }
            }

            SettingsSection("Details") {
                PickerRow("Running indicators", selection: $store.settings.indicatorStyle) {
                    Text("Glow").tag(IndicatorStyle.glow)
                    Text("Dots").tag(IndicatorStyle.dot)
                    Text("Lines").tag(IndicatorStyle.line)
                    Text("None").tag(IndicatorStyle.none)
                }
                .settingAnchor("indicators")
                SettingRow("Accent colour") {
                    AccentSwatches(selection: $store.settings.accent)
                }
                .settingAnchor("accent")
                ToggleRow("Show app names on hover", isOn: $store.settings.showLabels)
                    .settingAnchor("labels")
                ToggleRow("Reflections", isOn: $store.settings.reflections)
                    .disabled(current.reflections || store.settings.position != .bottom)
                    .settingAnchor("reflections")
                ToggleRow("Dim icons of hidden apps", isOn: $store.settings.dimHiddenApps)
                    .settingAnchor("dimHidden")
            }

            SettingsSection(
                "Motion",
                footer: "With “Reduce motion” turned on in Accessibility settings, MarDock skips bounces and particle effects automatically."
            ) {
                ToggleRow("Bounce when opening apps", isOn: $store.settings.bounceOnLaunch)
                    .settingAnchor("bounce")
                ToggleRow("Ripple when clicking", isOn: $store.settings.clickRipple)
                    .settingAnchor("ripple")
                SliderRow(title: "Animation speed", value: $store.settings.animationSpeed, range: DockSettings.animationSpeedRange) {
                    String(format: "%.1f×", $0)
                }
                .settingAnchor("speed")
            }
        }
    }

    private func customCard(_ recipe: ThemeRecipe, selected: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                store.update { $0.customTheme = recipe.id }
            }
        } label: {
            RecipeCard(recipe: recipe, selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Edit…") { editing = recipe }
            Button("Duplicate") { themes.save(recipe.duplicate(named: recipe.name + " Copy")) }
            Button("Export…") { export(recipe) }
            Divider()
            Button("Delete", role: .destructive) { themes.delete(recipe.id) }
        }
        .accessibilityLabel(Text("\(recipe.name) theme"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.message = "Choose a MarDock theme file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let recipe = try themes.importTheme(from: url)
            store.update { $0.customTheme = recipe.id }
            themeMessage = "Added “\(recipe.name)”."
        } catch {
            themeMessage = error.localizedDescription
        }
    }

    private func export(_ recipe: ThemeRecipe) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = recipe.name + ".json"
        panel.message = "Save this theme as a file you can share."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try themes.export(recipe, to: url)
        } catch {
            themeMessage = error.localizedDescription
        }
    }
}

/// Starts a new theme from the one in use.
private struct NewThemeCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.4 : 0.22))
                    .frame(height: 72)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                Text("New Theme")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start from the theme you're using and change the glass, colours, edge and shadows")
    }
}

/// The accent colours as swatches, for a row's right-hand side.
private struct AccentSwatches: View {
    @Binding var selection: AccentChoice

    var body: some View {
        AccentPicker(selection: $selection)
            .labelsHidden()
    }
}
