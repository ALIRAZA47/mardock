import AppKit
import MarDockCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits one of the user's themes with a live preview. Nothing changes until
/// Save, so Cancel always leaves things as they were.
struct ThemeEditor: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var themes: ThemeStore
    @Environment(\.dismiss) private var dismiss
    @State var recipe: ThemeRecipe

    var body: some View {
        VStack(spacing: 0) {
            DockPreviewCard(settings: store.settings, recipe: recipe)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                .padding([.horizontal, .top], 16)

            Form {
                Section {
                    TextField("Name", text: $recipe.name)
                }

                Section("Glass") {
                    Picker("Glass", selection: $recipe.glass) {
                        Text("Frosted").tag(ThemeRecipe.Glass.frosted)
                        Text("Smoked").tag(ThemeRecipe.Glass.smoked)
                        Text("Liquid").tag(ThemeRecipe.Glass.liquid)
                        Text("None").tag(ThemeRecipe.Glass.none)
                    }
                    Picker("Light or dark", selection: $recipe.tone) {
                        Text("Follow the system").tag(ThemeRecipe.Tone.system)
                        Text("Light").tag(ThemeRecipe.Tone.light)
                        Text("Dark").tag(ThemeRecipe.Tone.dark)
                    }
                    ColorRow(title: "Tint", colors: $recipe.tint, limit: ThemeRecipe.maxTint)
                    UnitSlider(title: "Tint strength", value: $recipe.tintOpacity)
                        .disabled(recipe.tint.isEmpty)
                    ColorRow(title: "Drifting colours", colors: $recipe.aurora, limit: ThemeRecipe.maxAurora)
                    UnitSlider(title: "Drift strength", value: $recipe.auroraOpacity)
                        .disabled(recipe.aurora.isEmpty)
                    UnitSlider(title: "Inner light", value: $recipe.innerHighlight)
                    UnitSlider(title: "Pointer highlight", value: $recipe.specular)
                }

                Section("Edge") {
                    ColorPicker("Border, top", selection: $recipe.borderStart.color, supportsOpacity: true)
                    ColorPicker("Border, bottom", selection: $recipe.borderEnd.color, supportsOpacity: true)
                    SettingSlider(title: "Border width", value: $recipe.borderWidth, range: ThemeRecipe.borderWidthRange) {
                        String(format: "%.1f pt", $0)
                    }
                    OptionalColorRow(title: "Neon glow", color: $recipe.edgeGlow, fallback: ThemeColor(hex: 0x00E5FF))
                    SettingSlider(title: "Corner roundness", value: $recipe.cornerFactor, range: ThemeRecipe.cornerRange) {
                        "\(Int(($0 / ThemeRecipe.cornerRange.upperBound * 100).rounded()))%"
                    }
                }

                Section("Shadows and lines") {
                    UnitSlider(title: "Shadow", value: $recipe.shadowOpacity)
                    SettingSlider(title: "Shadow softness", value: $recipe.shadowRadius, range: ThemeRecipe.shadowRadiusRange) {
                        "\(Int($0)) pt"
                    }
                    UnitSlider(title: "Icon shadows", value: $recipe.iconShadow)
                    UnitSlider(title: "Separator lines", value: $recipe.separatorOpacity)
                    Toggle("Reflections", isOn: $recipe.reflections)
                    Toggle("Glossy floor (bottom of the screen only)", isOn: $recipe.floor)
                }

                Section("Colour") {
                    OptionalColorRow(title: "Accent", color: $recipe.accent, fallback: ThemeColor(hex: 0x0A84FF), offLabel: "System accent colour")
                    UnitSlider(title: "Indicator glow", value: $recipe.indicatorGlow)
                    ColorPicker("Swatch, top", selection: swatch(0), supportsOpacity: false)
                    ColorPicker("Swatch, bottom", selection: swatch(1), supportsOpacity: false)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Export…") { export() }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    themes.save(recipe)
                    store.update { $0.customTheme = recipe.id }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 600, height: 760)
    }

    private func swatch(_ index: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(themeColor: recipe.swatch.indices.contains(index) ? recipe.swatch[index] : .white(1))) },
            set: { color in
                var colors = recipe.swatch
                while colors.count < 2 { colors.append(.white(1)) }
                colors[index] = ThemeColor(nsColor: NSColor(color))
                recipe.swatch = colors
            }
        )
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = recipe.name + ".json"
        panel.message = "Save this theme as a file you can share."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try themes.export(recipe, to: url)
        } catch {
            NSSound.beep()
        }
    }
}

/// A slider from 0 to 100%.
private struct UnitSlider: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        SettingSlider(title: title, value: $value, range: ThemeRecipe.opacityRange) { "\(Int(($0 * 100).rounded()))%" }
    }
}

/// Up to `limit` colours, each with its own picker.
private struct ColorRow: View {
    let title: String
    @Binding var colors: [ThemeColor]
    let limit: Int

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                ForEach(colors.indices, id: \.self) { index in
                    ColorPicker("", selection: color(at: index), supportsOpacity: false)
                        .labelsHidden()
                }
                if colors.count < limit {
                    Button {
                        colors.append(colors.last ?? ThemeColor(hex: 0x7B5CFF))
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add a colour")
                }
                if !colors.isEmpty {
                    Button {
                        colors.removeLast()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the last colour")
                }
            }
        }
    }

    private func color(at index: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(themeColor: colors.indices.contains(index) ? colors[index] : .white(1))) },
            set: { color in
                guard colors.indices.contains(index) else { return }
                colors[index] = ThemeColor(nsColor: NSColor(color))
            }
        )
    }
}

/// A colour that can be turned off.
private struct OptionalColorRow: View {
    let title: String
    @Binding var color: ThemeColor?
    let fallback: ThemeColor
    var offLabel = "Off"

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Toggle(color == nil ? offLabel : "On", isOn: Binding(
                    get: { color != nil },
                    set: { color = $0 ? (color ?? fallback) : nil }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
                if color != nil {
                    ColorPicker("", selection: Binding(
                        get: { Color(nsColor: NSColor(themeColor: color ?? fallback)) },
                        set: { color = ThemeColor(nsColor: NSColor($0)) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
            }
        }
    }
}

extension Binding where Value == ThemeColor {
    /// The same colour as a SwiftUI colour, for `ColorPicker`.
    var color: Binding<Color> {
        Binding<Color>(
            get: { Color(nsColor: NSColor(themeColor: wrappedValue)) },
            set: { wrappedValue = ThemeColor(nsColor: NSColor($0)) }
        )
    }
}
