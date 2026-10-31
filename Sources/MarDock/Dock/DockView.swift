import AppKit
import MarDockCore
import QuartzCore

@MainActor
protocol DockViewDelegate: AnyObject {
    func dockView(_ view: DockView, mouseDown event: NSEvent)
    func dockView(_ view: DockView, mouseDragged event: NSEvent)
    func dockView(_ view: DockView, mouseUp event: NSEvent)
    func dockView(_ view: DockView, rightMouseDown event: NSEvent)
    func dockView(_ view: DockView, draggingUpdated info: NSDraggingInfo) -> NSDragOperation
    func dockView(_ view: DockView, draggingEnded info: NSDraggingInfo?)
    func dockView(_ view: DockView, performDrop info: NSDraggingInfo) -> Bool
    func dockView(_ view: DockView, dragSession session: NSDraggingSession, movedTo screenPoint: NSPoint)
    func dockView(_ view: DockView, dragSessionEndedAt screenPoint: NSPoint, operation: NSDragOperation)
    func dockView(_ view: DockView, accessibilityPress id: String)
    func dockViewPointerMoved(_ view: DockView)
}

extension NSPasteboard.PasteboardType {
    /// Private type for tiles dragged within the dock. Deliberately not a file
    /// URL, so dropping a tile on Finder can never move or copy an app.
    static let mardockTile = NSPasteboard.PasteboardType("io.github.aliraza47.mardock.tile")
}

/// Renders `DockFrame`s with Core Animation: glass shelf, tiles, indicators,
/// reflections, label and effects. It holds no state about apps; the
/// controller feeds it frames and receives its events.
@MainActor
final class DockView: NSView {
    struct Configuration {
        var position: DockPosition = .bottom
        /// Identifies the theme's glass; the backdrop is rebuilt when it changes.
        var themeKey = ""
        var style: ThemeStyle = .style(for: .glass)
        var accent: NSColor = .controlAccentColor
        var indicatorStyle: IndicatorStyle = .glow
        var reflections = false
        var metrics = DockMetrics()
        var blending: NSVisualEffectView.BlendingMode = .behindWindow
        var reduceMotion = false
        var increaseContrast = false
    }

    weak var delegate: DockViewDelegate?
    /// Returns the icon for a tile, rendered at the given pixel size.
    var imageProvider: ((String, Int) -> CGImage?)?
    var nameProvider: ((String) -> String)?

    private(set) var configuration = Configuration()
    private(set) var lastFrame = DockFrame()
    private(set) var pixelSize = 128

    private let shadowHost = LayerHostView()
    private let decorHost = LayerHostView()
    private var backdrop: NSView?
    private let labelView = DockLabelView()

    private let shadowLayer = CALayer()
    private let shelfDecor = CALayer()
    private let shelfMask = CAShapeLayer()
    private let tintLayer = CAGradientLayer()
    private let auroraLayer = CAGradientLayer()
    private let highlightLayer = CAGradientLayer()
    private let specularLayer = CAGradientLayer()
    private let borderLayer = CAGradientLayer()
    private let borderMask = CAShapeLayer()
    private let glowLayer = CAShapeLayer()
    private let indicatorsLayer = CALayer()
    private let tilesLayer = CALayer()
    private var tiles: [String: TileLayer] = [:]

    private var maskKey = ""
    private var labelSize = NSSize.zero
    private var specularAlpha: Float = 0
    private var specularPoint: (u: Double, v: Double)?
    private var accessibilityItems: [DockAccessibilityElement] = []

    // Colours resolved for the current appearance.
    private var neutralIndicator = NSColor.white
    private var separatorColor = NSColor.white

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false

        shadowHost.frame = bounds
        decorHost.frame = bounds
        addSubview(shadowHost)
        addSubview(decorHost)
        labelView.alphaValue = 0
        addSubview(labelView)

        buildLayers()
        registerForDraggedTypes([.fileURL, .mardockTile])
        rebuildBackdrop()
        refreshStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Configuration

    func setConfiguration(_ new: Configuration) {
        let old = configuration
        configuration = new
        let backdropChanged = old.themeKey != new.themeKey || old.blending != new.blending
        if backdropChanged {
            rebuildBackdrop()
        }
        let newPixels = Self.pixelSize(for: new.metrics, scale: window?.backingScaleFactor ?? 2)
        if newPixels != pixelSize {
            pixelSize = newPixels
            reloadImages()
        }
        if old.position != new.position {
            for tile in tiles.values { tile.anchorPoint = anchorPoint(for: new.position) }
        }
        maskKey = ""
        refreshStyle()
        apply(lastFrame)
    }

    /// Badge labels by tile id (unread counts and the like).
    var badges: [String: String] = [:]

    /// Forces every tile to fetch its icon again (icons changed or scale changed).
    func reloadImages() {
        for tile in tiles.values { tile.imageKey = "" }
    }

    static func pixelSize(for metrics: DockMetrics, scale: CGFloat) -> Int {
        let needed = metrics.iconSize * max(metrics.peakScale, 1.15) * Double(scale)
        return min(512, max(64, Int((needed / 32).rounded(.up)) * 32))
    }

    // MARK: - Layers

    private func buildLayers() {
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOffset = CGSize(width: 0, height: -5)
        shadowHost.layer?.addSublayer(shadowLayer)

        guard let root = decorHost.layer else { return }
        shelfMask.fillColor = NSColor.black.cgColor
        shelfDecor.mask = shelfMask
        root.addSublayer(shelfDecor)

        auroraLayer.startPoint = CGPoint(x: 0, y: 0.5)
        auroraLayer.endPoint = CGPoint(x: 1, y: 0.5)
        tintLayer.startPoint = CGPoint(x: 0, y: 0.5)
        tintLayer.endPoint = CGPoint(x: 1, y: 0.5)
        specularLayer.type = .radial
        specularLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        specularLayer.endPoint = CGPoint(x: 1, y: 1)
        specularLayer.colors = [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0).cgColor]
        specularLayer.opacity = 0
        for layer in [tintLayer, auroraLayer, highlightLayer, specularLayer] {
            shelfDecor.addSublayer(layer)
        }

        glowLayer.fillColor = nil
        glowLayer.shadowOffset = .zero
        glowLayer.opacity = 0
        root.addSublayer(glowLayer)

        borderMask.fillColor = nil
        borderMask.strokeColor = NSColor.black.cgColor
        borderLayer.mask = borderMask
        root.addSublayer(borderLayer)

        root.addSublayer(indicatorsLayer)
        root.addSublayer(tilesLayer)
    }

    private func rebuildBackdrop() {
        backdrop?.removeFromSuperview()
        backdrop = nil
        let style = configuration.style
        let view: NSView?
        switch style.backdrop {
        case .none:
            view = nil
        case let .material(material):
            view = makeEffectView(material)
        case let .liquidGlass(fallback):
            view = makeLiquidGlass() ?? makeEffectView(fallback)
        }
        if let view {
            addSubview(view, positioned: .above, relativeTo: shadowHost)
            backdrop = view
        }
        maskKey = ""
    }

    private func makeEffectView(_ material: NSVisualEffectView.Material) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = configuration.blending
        view.state = .active
        view.isEmphasized = false
        view.appearance = configuration.style.appearance.flatMap(NSAppearance.init(named:))
        return view
    }

    private func makeLiquidGlass() -> NSView? {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.appearance = configuration.style.appearance.flatMap(NSAppearance.init(named:))
            return glass
        }
        #endif
        return nil
    }

    /// True when the backdrop is the system's Liquid Glass (macOS 26+).
    private var usesSystemGlass: Bool {
        guard let backdrop else { return false }
        return !(backdrop is NSVisualEffectView)
    }

    private var resolvedAppearance: NSAppearance {
        configuration.style.appearance.flatMap(NSAppearance.init(named:)) ?? effectiveAppearance
    }

    /// Applies everything that only changes with the theme or appearance.
    private func refreshStyle() {
        let style = configuration.style
        let appearance = resolvedAppearance
        let dark = appearance.isDark
        let scale = window?.backingScaleFactor ?? 2

        neutralIndicator = dark ? NSColor(white: 1, alpha: 0.85) : NSColor(white: 0, alpha: 0.62)
        separatorColor = dark ? NSColor(white: 1, alpha: 1) : NSColor(white: 0, alpha: 1)

        appearance.performAsCurrentDrawingAppearance {
            tintLayer.colors = style.tintColors.map(\.cgColor)
            tintLayer.opacity = style.tintColors.isEmpty ? 0 : style.tintOpacity

            // System Liquid Glass draws its own edge light; don't double it.
            let highlightStrength = usesSystemGlass ? 0 : CGFloat(style.innerHighlight) * (dark ? 0.7 : 1)
            highlightLayer.colors = [NSColor(white: 1, alpha: highlightStrength).cgColor, NSColor(white: 1, alpha: 0).cgColor]

            let contrast: CGFloat = configuration.increaseContrast ? 1.6 : 1
            borderLayer.colors = [
                style.borderStart.withAlphaComponent(min(1, style.borderStart.alphaComponent * contrast)).cgColor,
                style.borderEnd.withAlphaComponent(min(1, style.borderEnd.alphaComponent * contrast)).cgColor,
            ]
            if let glow = style.edgeGlow {
                glowLayer.strokeColor = glow.withAlphaComponent(0.5).cgColor
                glowLayer.shadowColor = glow.cgColor
                glowLayer.shadowRadius = 7
                glowLayer.shadowOpacity = 0.9
                glowLayer.lineWidth = 1.5
            }
        }
        setGradientDirections()
        updateAurora()

        for layer in [shadowLayer, shelfDecor, shelfMask, tintLayer, auroraLayer, highlightLayer, specularLayer,
                      borderLayer, borderMask, glowLayer, indicatorsLayer, tilesLayer] as [CALayer] {
            layer.contentsScale = scale
        }
        for tile in tiles.values {
            tile.setScale(scale)
            styleTile(tile)
        }
        if let effect = backdrop as? NSVisualEffectView {
            effect.blendingMode = configuration.blending
            effect.appearance = style.appearance.flatMap(NSAppearance.init(named:))
        }
        labelView.configure(appearance: style.appearance, blending: configuration.blending)
    }

    /// Gradients run from the inner (screen-facing away) side of the shelf.
    private func setGradientDirections() {
        let floor = configuration.style.floor && configuration.position == .bottom
        let points: (start: CGPoint, end: CGPoint)
        switch configuration.position {
        case .bottom:
            points = floor ? (CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)) : (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        case .left:
            points = (CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))
        case .right:
            points = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        }
        let start = points.start
        let end = points.end
        borderLayer.startPoint = start
        borderLayer.endPoint = end
        highlightLayer.startPoint = start
        highlightLayer.endPoint = CGPoint(x: start.x + (end.x - start.x) * 0.55, y: start.y + (end.y - start.y) * 0.55)
        if configuration.position.isVertical {
            tintLayer.startPoint = CGPoint(x: 0.5, y: 1)
            tintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        } else {
            tintLayer.startPoint = CGPoint(x: 0, y: 0.5)
            tintLayer.endPoint = CGPoint(x: 1, y: 0.5)
        }
    }

    private func updateAurora() {
        auroraLayer.removeAllAnimations()
        let colors = configuration.style.auroraColors.map(\.cgColor)
        guard colors.count >= 2 else {
            auroraLayer.opacity = 0
            return
        }
        auroraLayer.colors = colors
        auroraLayer.opacity = configuration.style.auroraOpacity
        guard !configuration.reduceMotion else { return }

        // Drifting colour: runs entirely in the render server, so it costs
        // the app no CPU.
        let shifted = Array(colors.dropFirst()) + [colors[0]]
        let drift = CABasicAnimation(keyPath: "colors")
        drift.fromValue = colors
        drift.toValue = shifted
        drift.duration = 7
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        auroraLayer.add(drift, forKey: "drift")

        let start = CABasicAnimation(keyPath: "startPoint")
        start.fromValue = NSValue(point: NSPoint(x: 0, y: 0.2))
        start.toValue = NSValue(point: NSPoint(x: 0.35, y: 1))
        start.duration = 9
        start.autoreverses = true
        start.repeatCount = .infinity
        start.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        auroraLayer.add(start, forKey: "start")

        let end = CABasicAnimation(keyPath: "endPoint")
        end.fromValue = NSValue(point: NSPoint(x: 1, y: 0.8))
        end.toValue = NSValue(point: NSPoint(x: 0.65, y: 0))
        end.duration = 11
        end.autoreverses = true
        end.repeatCount = .infinity
        end.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        auroraLayer.add(end, forKey: "end")
    }

    private func anchorPoint(for position: DockPosition) -> CGPoint {
        switch position {
        case .bottom: return CGPoint(x: 0.5, y: 0)
        case .left: return CGPoint(x: 0, y: 0.5)
        case .right: return CGPoint(x: 1, y: 0.5)
        }
    }

    private func makeTile() -> TileLayer {
        let tile = TileLayer()
        tile.anchorPoint = anchorPoint(for: configuration.position)
        tile.setScale(window?.backingScaleFactor ?? 2)
        styleTile(tile)
        tilesLayer.addSublayer(tile)
        indicatorsLayer.addSublayer(tile.indicator)
        return tile
    }

    private func styleTile(_ tile: TileLayer) {
        let style = configuration.style
        tile.shadowColor = NSColor.black.cgColor
        tile.shadowOpacity = style.iconShadow
        tile.shadowRadius = 5
        tile.shadowOffset = CGSize(width: 0, height: -3)
        let accent = configuration.accent.cgColor
        tile.glow.colors = [configuration.accent.withAlphaComponent(0.7).cgColor, configuration.accent.withAlphaComponent(0).cgColor]
        tile.indicator.shadowColor = accent
        tile.line.colors = [
            separatorColor.withAlphaComponent(0).cgColor,
            separatorColor.withAlphaComponent(CGFloat(style.separatorOpacity)).cgColor,
            separatorColor.withAlphaComponent(0).cgColor,
        ]
        tile.setIndicatorColor(neutralIndicator.cgColor, key: -2)
    }

    // MARK: - Frames

    func apply(_ frame: DockFrame) {
        lastFrame = frame
        let axis = DockAxis(position: configuration.position, width: Double(bounds.width), height: Double(bounds.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutShelf(frame, axis: axis)
        layoutTiles(frame, axis: axis)
        CATransaction.commit()
        layoutLabel(frame, axis: axis)
    }

    private var usesFloor: Bool { configuration.style.floor && configuration.position == .bottom }

    private func layoutShelf(_ frame: DockFrame, axis: DockAxis) {
        let m = configuration.metrics
        let style = configuration.style
        let floor = usesFloor
        let thickness = floor ? m.insetBottom + m.iconSize * 0.3 : frame.shelfThickness
        let r = axis.rect(u0: frame.shelfStart, u1: frame.shelfEnd, v0: frame.shelfBaseline, v1: frame.shelfBaseline + thickness)
        let rect = backingAlignedRect(CGRect(x: r.x, y: r.y, width: max(r.width, 0), height: max(r.height, 0)), options: .alignAllEdgesNearest)
        let radius = floor ? 0 : (CGFloat(frame.shelfThickness) * style.cornerFactor).rounded()
        let floorInset: CGFloat? = floor ? (CGFloat(thickness) * 0.6).rounded() : nil
        let path = Self.shelfPath(rect, radius: radius, floorInset: floorInset)
        let opacity = Float(frame.opacity)

        if let backdrop {
            backdrop.frame = rect
            backdrop.alphaValue = CGFloat(frame.opacity)
            updateBackdropMask(radius: radius, floorInset: floorInset, height: rect.height)
        }

        shadowLayer.frame = bounds
        shadowLayer.shadowPath = path
        shadowLayer.shadowRadius = style.shadowRadius
        shadowLayer.shadowOpacity = style.shadowOpacity * opacity

        shelfDecor.frame = bounds
        shelfMask.frame = bounds
        shelfMask.path = path
        shelfDecor.opacity = opacity
        tintLayer.frame = rect
        auroraLayer.frame = rect
        highlightLayer.frame = rect

        // Specular highlight that follows the pointer along the glass.
        if let pointer = frame.pointer {
            specularPoint = (pointer.u, frame.shelfBaseline + thickness * 0.85)
        }
        let target: Float = frame.pointer == nil ? 0 : style.specular
        specularAlpha += (target - specularAlpha) * 0.22
        if abs(specularAlpha - target) < 0.004 { specularAlpha = target }
        if let point = specularPoint, specularAlpha > 0 {
            let size = CGFloat(m.iconSize) * 4.2
            let p = axis.toView(u: point.u, v: point.v)
            specularLayer.frame = CGRect(x: CGFloat(p.x) - size / 2, y: CGFloat(p.y) - size / 2, width: size, height: size)
            specularLayer.opacity = specularAlpha
        } else {
            specularLayer.opacity = 0
        }

        let lineWidth = usesSystemGlass ? 0 : style.borderWidth * (configuration.increaseContrast ? 1.5 : 1)
        if lineWidth > 0, rect.width > lineWidth * 2 {
            borderLayer.isHidden = false
            borderLayer.frame = rect
            borderMask.frame = borderLayer.bounds
            borderMask.lineWidth = lineWidth
            borderMask.path = Self.shelfPath(
                borderLayer.bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
                radius: max(0, radius - lineWidth / 2),
                floorInset: floorInset.map { max(0, $0 - lineWidth / 2) }
            )
            borderLayer.opacity = opacity
        } else {
            borderLayer.isHidden = true
        }

        if style.edgeGlow != nil {
            glowLayer.frame = bounds
            glowLayer.path = path
            glowLayer.shadowPath = path.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 10)
            glowLayer.opacity = opacity * 0.85
        } else {
            glowLayer.opacity = 0
        }
    }

    private func updateBackdropMask(radius: CGFloat, floorInset: CGFloat?, height: CGFloat) {
        let key = "\(radius)|\(floorInset ?? -1)|\(floorInset == nil ? 0 : height)"
        guard key != maskKey, let backdrop else { return }
        maskKey = key
        if let effect = backdrop as? NSVisualEffectView {
            if let floorInset {
                effect.maskImage = Self.floorMask(height: max(height, 1), inset: floorInset)
            } else {
                effect.maskImage = Self.roundedMask(radius: radius)
            }
        } else {
            setGlassCornerRadius(backdrop, radius: radius)
        }
    }

    private func setGlassCornerRadius(_ view: NSView, radius: CGFloat) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
            glass.cornerRadius = radius
        }
        #endif
    }

    private func layoutTiles(_ frame: DockFrame, axis: DockAxis) {
        let m = configuration.metrics
        let style = configuration.style
        let reflections = (style.reflections || configuration.reflections) && configuration.position == .bottom
        var seen = Set<String>()

        for item in frame.items {
            seen.insert(item.id)
            let tile: TileLayer
            if let existing = tiles[item.id] {
                tile = existing
            } else {
                tile = makeTile()
                tiles[item.id] = tile
            }

            if item.kind.isNarrow {
                tile.setBadge(nil, size: 0)
                layoutSeparator(tile, item: item, frame: frame, axis: axis)
                continue
            }
            if item.kind == .spacer {
                // An empty slot: nothing to draw.
                tile.setBadge(nil, size: 0)
                tile.icon.isHidden = true
                tile.line.isHidden = true
                tile.reflection.isHidden = true
                tile.indicator.opacity = 0
                tile.glow.opacity = 0
                continue
            }
            tile.line.isHidden = true
            tile.icon.isHidden = false

            let size = CGFloat(max(item.size, 0))
            let (sx, sy) = configuration.position == .bottom
                ? (CGFloat(item.mainScale), CGFloat(item.crossScale))
                : (CGFloat(item.crossScale), CGFloat(item.mainScale))
            let base = axis.toView(u: item.center, v: item.baseline + item.lift)
            tile.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            tile.position = CGPoint(x: base.x, y: base.y)
            tile.transform = CATransform3DMakeScale(max(sx, 0.01), max(sy, 0.01), 1)
            tile.opacity = Float(item.alpha * frame.opacity)
            tile.icon.frame = tile.bounds
            tile.setBadge(badges[item.id], size: size)

            let key = "\(item.id)#\(pixelSize)"
            if tile.imageKey != key, let image = imageProvider?(item.id, pixelSize) {
                tile.setImage(image, key: key)
            }

            if reflections {
                let lift = CGFloat(item.lift)
                tile.reflection.isHidden = false
                tile.reflection.bounds = tile.bounds
                tile.reflection.position = CGPoint(x: size / 2, y: -size / 2 - 2 * lift)
                tile.reflectionMask.frame = tile.reflection.bounds
                tile.reflection.opacity = Float(max(0, 1 - lift / max(size * 0.9, 1)))
            } else {
                tile.reflection.isHidden = true
            }

            if item.highlight > 0.001 {
                tile.glow.frame = tile.bounds.insetBy(dx: -size * 0.32, dy: -size * 0.32)
                tile.glow.opacity = Float(item.highlight)
            } else {
                tile.glow.opacity = 0
            }

            layoutIndicator(tile, item: item, frame: frame, axis: axis, metrics: m)
        }

        for (id, tile) in tiles where !seen.contains(id) {
            tile.removeFromSuperlayer()
            tile.indicator.removeFromSuperlayer()
            tiles[id] = nil
        }
    }

    private func layoutSeparator(_ tile: TileLayer, item: DockFrame.Item, frame: DockFrame, axis: DockAxis) {
        tile.icon.isHidden = true
        tile.reflection.isHidden = true
        tile.indicator.opacity = 0
        tile.glow.opacity = 0
        tile.line.isHidden = false
        let length = CGFloat(item.size) * 0.62
        let mid = axis.toView(u: item.center, v: item.baseline + item.size / 2)
        tile.transform = CATransform3DIdentity
        if configuration.position.isVertical {
            tile.bounds = CGRect(x: 0, y: 0, width: length, height: 1)
            tile.line.startPoint = CGPoint(x: 0, y: 0.5)
            tile.line.endPoint = CGPoint(x: 1, y: 0.5)
        } else {
            tile.bounds = CGRect(x: 0, y: 0, width: 1, height: length)
            tile.line.startPoint = CGPoint(x: 0.5, y: 0)
            tile.line.endPoint = CGPoint(x: 0.5, y: 1)
        }
        let anchor = tile.anchorPoint
        tile.position = CGPoint(
            x: CGFloat(mid.x) + (anchor.x - 0.5) * tile.bounds.width,
            y: CGFloat(mid.y) + (anchor.y - 0.5) * tile.bounds.height
        )
        tile.line.frame = tile.bounds
        tile.opacity = Float(item.alpha * frame.opacity)
    }

    private func layoutIndicator(_ tile: TileLayer, item: DockFrame.Item, frame: DockFrame, axis: DockAxis, metrics m: DockMetrics) {
        let style = configuration.indicatorStyle
        guard style != .none, item.kind == .app, item.indicator > 0.001 else {
            tile.indicator.opacity = 0
            return
        }
        let dot = max(3, (CGFloat(m.iconSize) * 0.075).rounded())
        let active = CGFloat(min(max(item.activeness, 0), 1.2))
        let length: CGFloat
        let thickness: CGFloat
        switch style {
        case .glow:
            length = dot + dot * 2.6 * active
            thickness = dot
        case .dot:
            length = dot
            thickness = dot
        case .line:
            length = CGFloat(item.size) * (0.26 + 0.3 * active)
            thickness = max(2.5, dot * 0.7)
        case .none:
            return
        }
        let v = usesFloor ? frame.shelfBaseline + Double(dot) : frame.shelfBaseline + m.insetBottom * 0.45
        let p = axis.toView(u: item.center, v: v)
        let rect = configuration.position.isVertical
            ? CGRect(x: CGFloat(p.x) - thickness / 2, y: CGFloat(p.y) - length / 2, width: thickness, height: length)
            : CGRect(x: CGFloat(p.x) - length / 2, y: CGFloat(p.y) - thickness / 2, width: length, height: thickness)
        tile.indicator.frame = rect
        tile.indicator.cornerRadius = thickness / 2
        tile.indicator.opacity = Float(item.indicator * frame.opacity)

        let mix = min(active, 1)
        let colorKey = Int((mix * 20).rounded())
        if style == .dot && mix < 0.5 {
            tile.setIndicatorColor(neutralIndicator.cgColor, key: 0)
        } else {
            tile.setIndicatorColor(neutralIndicator.mixed(with: configuration.accent, amount: CGFloat(colorKey) / 20).cgColor, key: colorKey)
        }

        if style == .glow {
            tile.indicator.shadowOpacity = configuration.style.indicatorGlow * Float(0.35 + 0.65 * mix)
            tile.indicator.shadowRadius = 2.5 + 3.5 * mix
            tile.indicator.shadowPath = CGPath(
                roundedRect: tile.indicator.bounds,
                cornerWidth: min(thickness / 2, rect.width / 2),
                cornerHeight: min(thickness / 2, rect.height / 2),
                transform: nil
            )
        } else {
            tile.indicator.shadowOpacity = 0
        }
    }

    private func layoutLabel(_ frame: DockFrame, axis: DockAxis) {
        guard let label = frame.label, label.alpha > 0.001 else {
            labelView.alphaValue = 0
            return
        }
        if labelView.currentID != label.id {
            labelSize = labelView.setText(nameProvider?(label.id) ?? "", id: label.id)
        }
        let rise = (1 - label.alpha) * 6
        let anchor = axis.toView(u: label.u, v: label.v - rise)
        let w = labelSize.width
        let h = labelSize.height
        var origin: CGPoint
        switch configuration.position {
        case .bottom: origin = CGPoint(x: CGFloat(anchor.x) - w / 2, y: CGFloat(anchor.y))
        case .left: origin = CGPoint(x: CGFloat(anchor.x), y: CGFloat(anchor.y) - h / 2)
        case .right: origin = CGPoint(x: CGFloat(anchor.x) - w, y: CGFloat(anchor.y) - h / 2)
        }
        origin.x = min(max(origin.x, 4), max(4, bounds.width - w - 4))
        origin.y = min(max(origin.y, 4), max(4, bounds.height - h - 4))
        labelView.frame = backingAlignedRect(NSRect(origin: origin, size: labelSize), options: .alignAllEdgesNearest)
        labelView.alphaValue = CGFloat(label.alpha * frame.opacity)
    }

    // MARK: - Geometry helpers

    /// Where a tile is, or with `resting` where it comes back to from a bounce.
    func iconRect(for id: String, resting: Bool = false) -> CGRect? {
        guard let item = lastFrame.item(id: id) else { return nil }
        let axis = DockAxis(position: configuration.position, width: Double(bounds.width), height: Double(bounds.height))
        let lift = resting ? 0 : item.lift
        let r = axis.rect(
            u0: item.center - item.size / 2, u1: item.center + item.size / 2,
            v0: item.baseline + lift, v1: item.baseline + lift + item.size
        )
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
    }

    func screenRect(forItem id: String, resting: Bool = false) -> NSRect {
        guard let rect = iconRect(for: id, resting: resting), let window else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }

    func dockPoint(for viewPoint: NSPoint) -> DockPointer {
        DockAxis(position: configuration.position, width: Double(bounds.width), height: Double(bounds.height))
            .toDock(x: Double(viewPoint.x), y: Double(viewPoint.y))
    }

    static func shelfPath(_ rect: CGRect, radius: CGFloat, floorInset: CGFloat?) -> CGPath {
        guard rect.width > 0, rect.height > 0 else { return CGPath(rect: .zero, transform: nil) }
        if let inset = floorInset {
            let i = min(inset, rect.width / 2)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - i, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + i, y: rect.maxY))
            path.closeSubpath()
            return path
        }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    /// A stretchable rounded-rectangle mask for `NSVisualEffectView`.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let r = max(radius, 1)
        let edge = r * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }

    /// A horizontally stretchable trapezoid mask (the Mirror theme's floor).
    static func floorMask(height: CGFloat, inset: CGFloat) -> NSImage {
        let width = inset * 2 + 3
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: rect.width, y: 0))
            path.line(to: NSPoint(x: rect.width - inset, y: rect.height))
            path.line(to: NSPoint(x: inset, y: rect.height))
            path.close()
            NSColor.black.setFill()
            path.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: 0, left: inset + 1, bottom: 0, right: inset + 1)
        image.resizingMode = .stretch
        return image
    }

    // MARK: - Effects

    /// A ring that ripples out from a tile when it is clicked.
    func ripple(for id: String) {
        guard !configuration.reduceMotion, let item = lastFrame.item(id: id), let root = decorHost.layer else { return }
        let axis = DockAxis(position: configuration.position, width: Double(bounds.width), height: Double(bounds.height))
        let center = axis.toView(u: item.center, v: item.baseline + item.lift + item.size / 2)
        let radius = CGFloat(item.size) * 0.56
        let ring = CAShapeLayer()
        ring.contentsScale = window?.backingScaleFactor ?? 2
        let circle = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.path = circle
        ring.position = CGPoint(x: center.x, y: center.y)
        ring.fillColor = nil
        ring.strokeColor = configuration.accent.withAlphaComponent(0.9).cgColor
        ring.lineWidth = 2
        ring.shadowColor = configuration.accent.cgColor
        ring.shadowRadius = 5
        ring.shadowOpacity = 0.8
        ring.shadowOffset = .zero
        ring.shadowPath = circle.copy(strokingWithWidth: 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
        ring.opacity = 0
        root.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.72
        grow.toValue = 1.55
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.95
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "ripple")
        CATransaction.commit()
    }

    // MARK: - Accessibility

    func updateAccessibility(items: [(id: String, label: String)]) {
        let existing = Dictionary(accessibilityItems.map { ($0.itemID, $0) }, uniquingKeysWith: { a, _ in a })
        accessibilityItems = items.map { item in
            if let element = existing[item.id] {
                element.setAccessibilityLabel(item.label)
                return element
            }
            return DockAccessibilityElement(itemID: item.id, label: item.label, dockView: self)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityLabel() -> String? { "MarDock" }
    override func accessibilityChildren() -> [Any]? { accessibilityItems }

    // MARK: - Window & appearance

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let newPixels = Self.pixelSize(for: configuration.metrics, scale: window?.backingScaleFactor ?? 2)
        if newPixels != pixelSize {
            pixelSize = newPixels
            reloadImages()
        }
        refreshStyle()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        viewDidMoveToWindow()
        apply(lastFrame)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshStyle()
        apply(lastFrame)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        shadowHost.frame = bounds
        decorHost.frame = bounds
    }

    // MARK: - Events

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// While the window accepts the mouse, a tracking area delivers full-rate
    /// pointer movement even though MarDock is never the active app (the
    /// controller's event monitors pick these events up).
    private var pointerTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseMoved(with event: NSEvent) { delegate?.dockViewPointerMoved(self) }
    override func mouseEntered(with event: NSEvent) { delegate?.dockViewPointerMoved(self) }
    override func mouseExited(with event: NSEvent) { delegate?.dockViewPointerMoved(self) }

    override func mouseDown(with event: NSEvent) { delegate?.dockView(self, mouseDown: event) }
    override func mouseDragged(with event: NSEvent) { delegate?.dockView(self, mouseDragged: event) }
    override func mouseUp(with event: NSEvent) { delegate?.dockView(self, mouseUp: event) }
    override func rightMouseDown(with event: NSEvent) { delegate?.dockView(self, rightMouseDown: event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.dockView(self, draggingUpdated: sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        delegate?.dockView(self, draggingUpdated: sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        delegate?.dockView(self, draggingEnded: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        delegate?.dockView(self, performDrop: sender) ?? false
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        delegate?.dockView(self, draggingEnded: sender)
    }
}

extension DockView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        delegate?.dockView(self, dragSession: session, movedTo: screenPoint)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        delegate?.dockView(self, dragSessionEndedAt: screenPoint, operation: operation)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
