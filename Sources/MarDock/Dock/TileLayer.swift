import AppKit
import MarDockCore
import QuartzCore

/// Layers for one dock tile: the icon, its reflection, a drop-target glow, the
/// running indicator (kept in a separate, unscaled layer) and, for separator
/// tiles, the divider line.
final class TileLayer: CALayer {
    let icon = CALayer()
    let reflection = CALayer()
    let reflectionMask = CAGradientLayer()
    let glow = CAGradientLayer()
    let indicator = CALayer()
    let line = CAGradientLayer()
    /// A badge such as an unread count, at the icon's top-right corner.
    let badge = CALayer()
    let badgeText = CATextLayer()
    var imageKey = ""
    private var indicatorColorKey: Int = -1
    private var badgeKey = ""

    override init() {
        super.init()
        configure()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        masksToBounds = false
        anchorPoint = CGPoint(x: 0.5, y: 0)

        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.opacity = 0
        addSublayer(glow)

        reflection.contentsGravity = .resizeAspect
        reflection.minificationFilter = .trilinear
        reflection.transform = CATransform3DMakeScale(1, -1, 1)
        reflection.isHidden = true
        // In the reflection's own (un-flipped) space, y = 0 is the edge that
        // touches the icon, so that's where it's most visible.
        reflectionMask.colors = [NSColor(white: 0, alpha: 0.5).cgColor, NSColor(white: 0, alpha: 0).cgColor]
        reflectionMask.startPoint = CGPoint(x: 0.5, y: 0)
        reflectionMask.endPoint = CGPoint(x: 0.5, y: 0.42)
        reflection.mask = reflectionMask
        addSublayer(reflection)

        icon.contentsGravity = .resizeAspect
        icon.minificationFilter = .trilinear
        icon.magnificationFilter = .linear
        addSublayer(icon)

        line.isHidden = true
        line.startPoint = CGPoint(x: 0.5, y: 0)
        line.endPoint = CGPoint(x: 0.5, y: 1)
        addSublayer(line)

        indicator.opacity = 0
        indicator.shadowOffset = .zero

        badge.isHidden = true
        badge.backgroundColor = NSColor.systemRed.cgColor
        badge.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        badge.shadowColor = NSColor.black.cgColor
        badge.shadowOpacity = 0.3
        badge.shadowRadius = 2
        badge.shadowOffset = CGSize(width: 0, height: -1)
        badgeText.alignmentMode = .center
        badgeText.foregroundColor = NSColor.white.cgColor
        badgeText.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        badge.addSublayer(badgeText)
        addSublayer(badge)
    }

    /// Shows `label` as a badge for an icon `size` points wide, or hides it.
    func setBadge(_ label: String?, size: CGFloat) {
        guard let label, !label.isEmpty, size > 0 else {
            badge.isHidden = true
            badgeKey = ""
            return
        }
        let key = "\(label)#\(size)"
        badge.isHidden = false
        guard key != badgeKey else { return }
        badgeKey = key
        let height = (size * 0.36).rounded()
        let fontSize = height * 0.62
        let textWidth = ceil((label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)]).width)
        let width = max(height, textWidth + height * 0.6)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = CGRect(x: size - width * 0.82, y: size - height * 0.86, width: width, height: height)
        badge.cornerRadius = height / 2
        badge.borderWidth = max(1, height * 0.06)
        badgeText.fontSize = fontSize
        badgeText.string = label
        let lineHeight = ceil(fontSize * 1.2)
        badgeText.frame = CGRect(x: 0, y: (height - lineHeight) / 2, width: width, height: lineHeight)
        CATransaction.commit()
    }

    func setScale(_ scale: CGFloat) {
        for layer in [self, icon, reflection, reflectionMask, glow, indicator, line, badge, badgeText] as [CALayer] {
            layer.contentsScale = scale
        }
    }

    func setImage(_ image: CGImage?, key: String) {
        icon.contents = image
        reflection.contents = image
        imageKey = key
    }

    func setIndicatorColor(_ color: CGColor, key: Int) {
        guard key != indicatorColorKey else { return }
        indicatorColorKey = key
        indicator.backgroundColor = color
    }
}

/// The floating name label above a hovered tile.
final class DockLabelView: NSView {
    private let background = NSVisualEffectView()
    private let text = NSTextField(labelWithString: "")
    private(set) var currentID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = DockView.roundedMask(radius: 8)
        addSubview(background)

        text.font = .systemFont(ofSize: 13, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .center
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.setAccessibilityElement(false)
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(appearance: NSAppearance.Name?, blending: NSVisualEffectView.BlendingMode) {
        background.appearance = appearance.flatMap(NSAppearance.init(named:))
        text.appearance = appearance.flatMap(NSAppearance.init(named:))
        background.blendingMode = blending
    }

    /// Sets the text and returns the size the label wants.
    func setText(_ value: String, id: String) -> NSSize {
        currentID = id
        text.stringValue = value
        layoutContent()
        let size = text.intrinsicContentSize
        return NSSize(width: min(ceil(size.width) + 30, 360), height: ceil(size.height) + 10)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutContent()
    }

    private func layoutContent() {
        background.frame = bounds
        let height = text.intrinsicContentSize.height
        text.frame = NSRect(x: 11, y: (bounds.height - height) / 2, width: max(bounds.width - 22, 0), height: height)
    }
}

/// An accessibility element per tile, so VoiceOver users can explore and
/// press dock items like buttons.
final class DockAccessibilityElement: NSAccessibilityElement {
    let itemID: String
    weak var dockView: DockView?

    init(itemID: String, label: String, dockView: DockView) {
        self.itemID = itemID
        self.dockView = dockView
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription("dock item")
        setAccessibilityLabel(label)
        setAccessibilityParent(dockView)
    }

    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { dockView?.screenRect(forItem: itemID) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let dockView else { return false }
            dockView.delegate?.dockView(dockView, accessibilityPress: itemID)
            return true
        }
    }

    override func isAccessibilityElement() -> Bool { true }
}
