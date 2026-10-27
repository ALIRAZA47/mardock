import AppKit
import MarDockCore
import SwiftUI

/// A coloured, rounded icon like the ones in System Settings' sidebar.
struct PaneIcon: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

/// Explanatory text under a settings section, aligned with the rows above.
struct FooterText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A labelled slider with a live value read-out.
struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
            .frame(maxWidth: 320)
        }
    }
}

/// A row in the Privacy & Security pane: a verdict, a title and an explanation.
struct StatusRow: View {
    let title: String
    let ok: Bool?
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch ok {
        case .some(true): return "checkmark.seal.fill"
        case .some(false): return "exclamationmark.triangle.fill"
        case .none: return "circle.dashed"
        }
    }

    private var color: Color {
        switch ok {
        case .some(true): return .green
        case .some(false): return .orange
        case .none: return .secondary
        }
    }
}

/// A feature line on the welcome screen.
struct FeatureRow: View {
    let symbol: String
    let color: Color
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.gradient))
                .shadow(color: color.opacity(0.35), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Theme gallery

struct ThemeGallery: View {
    /// The built-in theme in use, or nil while one of the user's own is.
    let selection: ThemeID?
    let select: (ThemeID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 118, maximum: 160), spacing: 14)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(ThemeID.allCases) { theme in
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { select(theme) }
                } label: {
                    ThemeCard(theme: theme, selected: selection == theme)
                }
                .buttonStyle(.plain)
                .help(theme.tagline)
                .accessibilityLabel(Text("\(theme.displayName) theme"))
                .accessibilityAddTraits(selection == theme ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThemeCard: View {
    let theme: ThemeID
    let selected: Bool

    var body: some View {
        VStack(spacing: 7) {
            ThemeSwatch(theme: theme)
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                )
                .shadow(color: .black.opacity(selected ? 0.22 : 0.08), radius: selected ? 8 : 3, y: 2)
                .scaleEffect(selected ? 1.03 : 1)
            Text(theme.displayName)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .contentShape(Rectangle())
    }
}

struct ThemeSwatch: View {
    let theme: ThemeID

    var body: some View {
        let style = ThemeStyle.style(for: theme)
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(nsColor: style.swatch.0), Color(nsColor: style.swatch.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 54, height: 54)
                .blur(radius: 16)
                .offset(x: -34, y: -24)
            MiniDock(theme: theme)
                .padding(.bottom, 7)
        }
    }
}

/// A tiny drawing of a dock in a given theme.
struct MiniDock: View {
    let theme: ThemeID
    private let sizes: [CGFloat] = [13, 16, 22, 16, 13]
    private let tiles: [[Color]] = [
        [Color(red: 0.25, green: 0.6, blue: 1), Color(red: 0.1, green: 0.35, blue: 0.95)],
        [Color(red: 1, green: 0.45, blue: 0.5), Color(red: 1, green: 0.6, blue: 0.3)],
        [Color(red: 0.62, green: 0.45, blue: 1), Color(red: 0.35, green: 0.3, blue: 0.95)],
        [Color(red: 0.3, green: 0.85, blue: 0.6), Color(red: 0.1, green: 0.65, blue: 0.5)],
        [Color(red: 1, green: 0.8, blue: 0.3), Color(red: 1, green: 0.6, blue: 0.15)],
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: sizes[i] * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: tiles[i], startPoint: .top, endPoint: .bottom))
                    .frame(width: sizes[i], height: sizes[i])
                    .shadow(color: .black.opacity(theme == .minimal ? 0.35 : 0.18), radius: 1.5, y: 1)
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            shelf.frame(height: 25)
        }
    }

    @ViewBuilder private var shelf: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        switch theme {
        case .glass:
            shape.fill(Color.white.opacity(0.38)).overlay(shape.strokeBorder(Color.white.opacity(0.75), lineWidth: 0.8))
        case .liquid:
            RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(0.95), lineWidth: 1))
        case .aurora:
            shape.fill(LinearGradient(colors: [Color(red: 0.48, green: 0.36, blue: 1).opacity(0.75), Color(red: 0.13, green: 0.76, blue: 1).opacity(0.75), Color(red: 1, green: 0.37, blue: 0.66).opacity(0.75)],
                                      startPoint: .leading, endPoint: .trailing))
                .overlay(shape.strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8))
        case .midnight:
            shape.fill(Color(red: 0.03, green: 0.05, blue: 0.14).opacity(0.88))
                .overlay(shape.strokeBorder(LinearGradient(colors: [Color(red: 0, green: 0.9, blue: 1), Color(red: 1, green: 0.17, blue: 0.84)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 1.2))
                .shadow(color: Color(red: 0, green: 0.9, blue: 1).opacity(0.7), radius: 4)
        case .sunset:
            shape.fill(LinearGradient(colors: [Color(red: 1, green: 0.7, blue: 0.36).opacity(0.6), Color(red: 1, green: 0.44, blue: 0.57).opacity(0.6), Color(red: 0.62, green: 0.42, blue: 1).opacity(0.6)],
                                      startPoint: .leading, endPoint: .trailing))
                .overlay(shape.strokeBorder(Color.white.opacity(0.7), lineWidth: 0.8))
        case .mirror:
            Trapezoid(inset: 0.12)
                .fill(LinearGradient(colors: [Color.white.opacity(0.2), Color.white.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .overlay(Trapezoid(inset: 0.12).stroke(Color.white.opacity(0.85), lineWidth: 0.8))
        case .minimal:
            Color.clear
        }
    }
}

/// A card for one of the user's own themes.
struct RecipeCard: View {
    let recipe: ThemeRecipe
    let selected: Bool

    var body: some View {
        VStack(spacing: 7) {
            RecipeSwatch(recipe: recipe)
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 2.5 : 1)
                )
                .shadow(color: .black.opacity(selected ? 0.22 : 0.08), radius: selected ? 8 : 3, y: 2)
                .scaleEffect(selected ? 1.03 : 1)
            Text(recipe.name)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}

/// A theme's swatch with a tiny dock drawn from its recipe.
struct RecipeSwatch: View {
    let recipe: ThemeRecipe

    var body: some View {
        let colors = recipe.swatch.map { Color(nsColor: NSColor(themeColor: $0)) }
        ZStack(alignment: .bottom) {
            LinearGradient(colors: colors.count >= 2 ? colors : [.gray, .gray], startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 54, height: 54)
                .blur(radius: 16)
                .offset(x: -34, y: -24)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach([13, 16, 22, 16, 13].indices, id: \.self) { i in
                    let size = CGFloat([13, 16, 22, 16, 13][i])
                    RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                        .frame(width: size, height: size)
                        .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                }
            }
            .padding(.horizontal, 7)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .background(alignment: .bottom) { shelf.frame(height: 25) }
            .padding(.bottom, 7)
        }
    }

    @ViewBuilder private var shelf: some View {
        let shape = RoundedRectangle(cornerRadius: 25 * recipe.cornerFactor, style: .continuous)
        let border = LinearGradient(
            colors: [Color(nsColor: NSColor(themeColor: recipe.borderStart)), Color(nsColor: NSColor(themeColor: recipe.borderEnd))],
            startPoint: .top, endPoint: .bottom
        )
        let colors = (recipe.aurora.isEmpty ? recipe.tint : recipe.aurora).map { Color(nsColor: NSColor(themeColor: $0)) }
        let base: Color = recipe.tone == .dark || recipe.glass == .smoked ? Color.black.opacity(0.45) : Color.white.opacity(0.38)
        if recipe.glass == .none {
            Color.clear
        } else {
            shape.fill(base)
                .overlay(shape.fill(LinearGradient(colors: colors.count >= 2 ? colors : [colors.first ?? .clear, colors.first ?? .clear], startPoint: .leading, endPoint: .trailing))
                    .opacity(max(recipe.tintOpacity, recipe.auroraOpacity)))
                .overlay(shape.strokeBorder(border, lineWidth: max(recipe.borderWidth, 0.5)))
                .shadow(color: recipe.edgeGlow.map { Color(nsColor: NSColor(themeColor: $0)) } ?? .clear, radius: 4)
        }
    }
}

struct Trapezoid: Shape {
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let i = rect.width * inset
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - i, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + i, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Colour swatches for the accent colour.
struct AccentPicker: View {
    @Binding var selection: AccentChoice

    var body: some View {
        LabeledContent("Accent colour") {
            HStack(spacing: 7) {
                ForEach(AccentChoice.allCases) { choice in
                    Button {
                        selection = choice
                    } label: {
                        swatch(for: choice)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(selection == choice ? 0.85 : 0.15), lineWidth: selection == choice ? 2 : 1))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .help(title(for: choice))
                    .accessibilityLabel(Text(title(for: choice)))
                }
            }
        }
    }

    @ViewBuilder private func swatch(for choice: AccentChoice) -> some View {
        switch choice {
        case .theme:
            Circle().fill(AngularGradient(colors: [.purple, .blue, .teal, .pink, .purple], center: .center))
        case .system:
            Circle().fill(Color(nsColor: .controlAccentColor))
                .overlay(Image(systemName: "applelogo").font(.system(size: 8)).foregroundStyle(.white))
        default:
            Circle().fill(Color(nsColor: ThemeStyle.accentColor(for: choice, theme: .style(for: .glass))))
        }
    }

    private func title(for choice: AccentChoice) -> String {
        switch choice {
        case .theme: return "Theme colour"
        case .system: return "System accent colour"
        default: return choice.rawValue.capitalized
        }
    }
}
