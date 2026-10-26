import AppKit
import QuartzCore

/// The puff of smoke when a tile is dragged off the dock.
@MainActor
enum PoofEffect {
    private static var windows: [NSWindow] = []

    static func show(at screenPoint: NSPoint, icon: CGImage?, size: CGFloat, reduceMotion: Bool) {
        let side = max(size * 3, 160)
        let window = NSPanel(
            contentRect: NSRect(x: screenPoint.x - side / 2, y: screenPoint.y - side / 2, width: side, height: side),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.isReleasedWhenClosed = false

        let host = LayerHostView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        window.contentView = host
        let root = host.layer!
        let scale = window.backingScaleFactor
        let center = CGPoint(x: side / 2, y: side / 2)

        // The icon pops and fades...
        let iconLayer = CALayer()
        iconLayer.contents = icon
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = scale
        iconLayer.bounds = CGRect(x: 0, y: 0, width: size, height: size)
        iconLayer.position = center
        iconLayer.opacity = 0
        root.addSublayer(iconLayer)
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 1
        pop.toValue = reduceMotion ? 1 : 1.35
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [pop, fade]
        group.duration = reduceMotion ? 0.2 : 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        iconLayer.add(group, forKey: "pop")

        // ...into a cloud of soft particles.
        if !reduceMotion {
            let emitter = CAEmitterLayer()
            emitter.frame = root.bounds
            emitter.emitterPosition = center
            emitter.emitterShape = .circle
            emitter.emitterMode = .volume
            emitter.emitterSize = CGSize(width: size * 0.5, height: size * 0.5)
            emitter.renderMode = .unordered
            let cell = CAEmitterCell()
            cell.contents = softDot()
            cell.birthRate = 160
            cell.lifetime = 0.55
            cell.lifetimeRange = 0.2
            cell.velocity = size * 1.15
            cell.velocityRange = size * 0.45
            cell.emissionRange = .pi * 2
            cell.scale = 0.22
            cell.scaleRange = 0.12
            cell.scaleSpeed = 0.9
            cell.alphaSpeed = -1.7
            cell.spin = 0.8
            cell.spinRange = 3
            cell.color = NSColor(white: 0.97, alpha: 0.95).cgColor
            emitter.emitterCells = [cell]
            emitter.beginTime = CACurrentMediaTime()
            root.addSublayer(emitter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) {
                emitter.birthRate = 0
            }
        }

        window.orderFrontRegardless()
        windows.append(window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated {
                window.orderOut(nil)
                windows.removeAll { $0 === window }
            }
        }
    }

    private static var dot: CGImage?

    private static func softDot() -> CGImage? {
        if let dot { return dot }
        let pixels = 64
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: space,
                                        colors: [NSColor(white: 1, alpha: 1).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                                        locations: [0, 1])
        else { return nil }
        let c = CGPoint(x: pixels / 2, y: pixels / 2)
        context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(pixels) / 2, options: [])
        dot = context.makeImage()
        return dot
    }
}

/// Finds out whether the frontmost app has a window over the dock, for the
/// "smart" auto-hide mode. Only window bounds are read — no screen content,
/// so no Screen Recording permission is involved.
@MainActor
enum WindowOverlapDetector {
    static func frontmostAppOverlaps(_ rect: NSRect) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        // Window bounds use a top-left origin on the primary display.
        let target = CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: rect.width, height: rect.height)
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == Int(front.processIdentifier),
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsInfo as CFDictionary)
            else { continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            if alpha > 0.05, bounds.width > 40, bounds.height > 40, bounds.intersects(target) {
                return true
            }
        }
        return false
    }
}
