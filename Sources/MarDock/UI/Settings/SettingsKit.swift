import AppKit
import MarDockCore
import SwiftUI

/// Where Settings is. It lives outside the views, so anything can send
/// Settings somewhere before its window has drawn, or while it's closed.
@MainActor
final class SettingsNavigator: ObservableObject {
    /// An app to show on the Shortcuts pane.
    struct ShortcutsTarget: Equatable {
        let bundleIdentifier: String
        let name: String
    }

    @Published var pane: SettingsView.Pane = .general
    /// The setting to scroll to and point out, for a moment.
    @Published private(set) var spotlight: String?
    @Published var shortcutsTarget: ShortcutsTarget?

    private var clearing: Task<Void, Never>?

    func show(_ pane: SettingsView.Pane, spotlight key: String? = nil) {
        self.pane = pane
        clearing?.cancel()
        spotlight = key
        guard key != nil else { return }
        clearing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.spotlight = nil
        }
    }
}

/// The look shared by every pane.
enum SettingsStyle {
    static let gutter: CGFloat = 32
    static let cardRadius: CGFloat = 12
    /// Past this, rows would stretch further than the eye can follow.
    static let contentWidth: CGFloat = 720

    private static func color(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(white: dark, alpha: 1) : NSColor(white: light, alpha: 1) })
    }

    static let canvas = color(light: 0.953, dark: 0.118)
    static let card = color(light: 1, dark: 0.165)
    static let hairline = Color.primary.opacity(0.085)
}

/// A pane: its title, then whatever scrolls. `pinned` stays put above the
/// scrolling part, for a preview to watch while changing settings below it.
struct SettingsPage<Pinned: View, Content: View>: View {
    @EnvironmentObject private var navigator: SettingsNavigator
    private let pane: SettingsView.Pane
    private let pinned: Pinned
    private let content: Content

    init(_ pane: SettingsView.Pane, @ViewBuilder pinned: () -> Pinned, @ViewBuilder content: () -> Content) {
        self.pane = pane
        self.pinned = pinned()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title)
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.3)
                Text(pane.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SettingsStyle.gutter)
            .padding(.top, 34)
            .padding(.bottom, 14)
            pinned
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        content
                    }
                    .frame(maxWidth: SettingsStyle.contentWidth, alignment: .leading)
                    .padding(.horizontal, SettingsStyle.gutter)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { reveal(navigator.spotlight, in: proxy) }
                .onChange(of: navigator.spotlight) { reveal(navigator.spotlight, in: proxy) }
            }
        }
    }

    private func reveal(_ key: String?, in proxy: ScrollViewProxy) {
        guard let key else { return }
        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(key, anchor: .center) }
    }
}

extension SettingsPage where Pinned == EmptyView {
    init(_ pane: SettingsView.Pane, @ViewBuilder content: () -> Content) {
        self.init(pane, pinned: { EmptyView() }, content: content)
    }
}

/// A group of rows in a card, with a title above and a note below.
struct SettingsSection<Content: View>: View {
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 3)
            }
            // Each row draws a line along its top; the card cuts off the first.
            VStack(spacing: 0) {
                content
            }
            .padding(.top, -1)
            .settingsCard()
            if let footer {
                FooterText(footer)
                    .padding(.horizontal, 3)
            }
        }
    }
}

extension View {
    func settingsCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
        return background(SettingsStyle.card)
            .clipShape(shape)
            .overlay(shape.strokeBorder(SettingsStyle.hairline))
    }

    /// Lets search lead to this setting: it scrolls into view and lights up.
    func settingAnchor(_ key: String) -> some View {
        modifier(SettingAnchor(key: key))
    }
}

private struct SettingAnchor: ViewModifier {
    @EnvironmentObject private var navigator: SettingsNavigator
    let key: String

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: SettingsStyle.cardRadius, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(navigator.spotlight == key ? 0.16 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: 0.35), value: navigator.spotlight)
            }
            .id(key)
    }
}

/// One row's frame: the padding and the line above it.
struct RowBox<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(SettingsStyle.hairline)
                    .frame(height: 0.5)
                    .padding(.leading, 14)
            }
    }
}

/// A title, an optional explanation, and a control on the right.
struct SettingRow<Control: View>: View {
    private let title: String
    private let detail: String?
    private let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        RowBox {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                control
            }
        }
    }
}

struct ToggleRow: View {
    private let title: String
    private let detail: String?
    @Binding private var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        SettingRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A row with a menu of choices.
struct PickerRow<Selection: Hashable, Options: View>: View {
    private let title: String
    private let detail: String?
    @Binding private var selection: Selection
    private let options: Options

    init(_ title: String, detail: String? = nil, selection: Binding<Selection>, @ViewBuilder options: () -> Options) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.options = options()
    }

    var body: some View {
        SettingRow(title, detail: detail) {
            Picker(title, selection: $selection) {
                options
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// A row with a slider and a live read-out. `step` rounds the value rather
/// than going to the slider, which would draw a tick mark for every step.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var format: (Double) -> String

    private var rounded: Binding<Double> {
        Binding(get: { value }, set: { new in
            value = step.map { (new / $0).rounded() * $0 } ?? new
        })
    }

    var body: some View {
        SettingRow(title) {
            HStack(spacing: 10) {
                Slider(value: rounded, in: range)
                Text(format(value))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .controlSize(.small)
            .labelsHidden()
            .frame(width: 280)
        }
    }
}

/// One of the big switches at the top of General.
struct FeatureTile: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8.5, style: .continuous).fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)))
                Spacer()
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .settingsCard()
    }
}

/// Something that wants attention, in place of a row or between sections.
struct Callout<Action: View>: View {
    private let symbol: String
    private let text: String
    private let action: Action

    init(symbol: String = "exclamationmark.triangle.fill", text: String, @ViewBuilder action: () -> Action) {
        self.symbol = symbol
        self.text = text
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

extension Callout where Action == EmptyView {
    init(symbol: String = "exclamationmark.triangle.fill", text: String) {
        self.init(symbol: symbol, text: text) { EmptyView() }
    }
}

/// The sidebar's see-through backing.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
