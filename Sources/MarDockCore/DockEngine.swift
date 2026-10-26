import Foundation

/// The dock's animation and layout engine.
///
/// It owns every spring (magnification, presence of tiles as they come and
/// go, bounces, press feedback, auto-hide…) and produces a `DockFrame` per
/// display refresh. It has no UI dependencies, so all of the motion is unit
/// tested; renderers only map the frame onto layers.
public final class DockEngine {
    public private(set) var metrics: DockMetrics
    public var bounceEnabled = true
    public var dimHiddenApps = true
    public var labelsEnabled = true
    /// Multiplies the speed of every animation.
    public var speed: Double = 1
    /// Centre of the row along `u`.
    public var stripCenter: Double = 0

    struct Item {
        var spec: DockItemSpec
        var presence: Spring
        var removing = false
        var indicator: Spring
        var active: Spring
        var hover: Spring
        var press: Spring
        var highlight: Spring
        var dim: Spring
        var bounceStart: Double?
        var bounceStop: Double?

        var isAnimating: Bool {
            !presence.isAtRest || !indicator.isAtRest || !active.isAtRest || !hover.isAtRest
                || !press.isAtRest || !highlight.isAtRest || !dim.isAtRest || bounceStart != nil
        }

        mutating func step(_ dt: Double) {
            presence.step(dt)
            indicator.step(dt)
            active.step(dt)
            hover.step(dt)
            press.step(dt)
            highlight.step(dt)
            dim.step(dt)
        }
    }

    struct Gap {
        var index: Int
        var presence: Spring
        var closing = false
    }

    private(set) var items: [Item] = []
    private var gaps: [Gap] = []
    private var focus = Spring(0, response: 0.07, dampingFraction: 1, precision: 0.01)
    private var amount = Spring(0, response: 0.22, dampingFraction: 0.95, precision: 0.0005)
    private var reveal = Spring(1, response: 0.36, dampingFraction: 0.88, precision: 0.0005)
    private var labelAlpha = Spring(0, response: 0.16, dampingFraction: 1, precision: 0.003)
    private var pointer: DockPointer?
    private var hovered: String?
    private var labelID: String?
    private var pressedID: String?
    private var highlightedID: String?
    private var draggedID: String?
    private var clock: Double = 0
    public private(set) var lastFrame = DockFrame()

    public init(metrics: DockMetrics = DockMetrics()) {
        self.metrics = metrics
    }

    // MARK: - Inputs

    public func setMetrics(_ metrics: DockMetrics) {
        self.metrics = metrics
        if metrics.peakScale <= 1.001 {
            amount.target = 0
        } else if pointer != nil {
            amount.target = 1
        }
    }

    /// Replaces the tiles. New tiles grow in, missing ones shrink away in
    /// place, and existing ones keep their animation state.
    public func setItems(_ specs: [DockItemSpec], animated: Bool) {
        var seen = Set<String>()
        let specs = specs.filter { seen.insert($0.id).inserted }

        var existing: [String: Item] = [:]
        var removingAfter: [String?: [Item]] = [:]
        var lastSurvivor: String?
        for var item in items {
            if seen.contains(item.spec.id) {
                existing[item.spec.id] = item
                lastSurvivor = item.spec.id
            } else {
                if !item.removing {
                    item.removing = true
                    item.presence.dampingFraction = 1
                    item.presence.target = 0
                    item.hover.target = 0
                    item.press.target = 0
                }
                removingAfter[lastSurvivor, default: []].append(item)
            }
        }

        var result = removingAfter[nil] ?? []
        for spec in specs {
            var item = existing[spec.id] ?? makeItem(spec, animated: animated)
            apply(spec, to: &item)
            if !animated { settle(&item) }
            result.append(item)
            result += removingAfter[spec.id] ?? []
        }
        if !animated {
            result.removeAll(where: \.removing)
        }
        items = result
    }

    /// The pointer position while it is over the dock, or nil once it leaves.
    public func setPointer(_ newPointer: DockPointer?) {
        if let newPointer {
            if pointer == nil && amount.value < 0.02 {
                focus.snap(to: newPointer.u)
            } else {
                focus.target = newPointer.u
            }
            amount.target = metrics.peakScale > 1.001 ? 1 : 0
        } else {
            amount.target = 0
        }
        pointer = newPointer
    }

    public var isPointerInside: Bool { pointer != nil }
    public var hoveredID: String? { hovered }

    /// Slides the dock in or out (auto-hide).
    public func setRevealed(_ shown: Bool, animated: Bool) {
        if animated {
            reveal.target = shown ? 1 : 0
        } else {
            reveal.snap(to: shown ? 1 : 0)
        }
    }

    public var isRevealed: Bool { reveal.target >= 1 }

    /// Opens a gap before the live tile at `index` (nil closes all gaps).
    public func setDropGap(at index: Int?, animated: Bool = true) {
        for i in gaps.indices where gaps[i].index != index && !gaps[i].closing {
            gaps[i].closing = true
            gaps[i].presence.target = 0
        }
        if let index {
            if let i = gaps.firstIndex(where: { $0.index == index }) {
                gaps[i].closing = false
                gaps[i].presence.target = 1
            } else {
                var gap = Gap(index: index, presence: Spring(0, response: 0.3, dampingFraction: 0.9, precision: 0.001))
                gap.presence.target = 1
                gaps.append(gap)
            }
        }
        if !animated {
            gaps.removeAll(where: \.closing)
            for i in gaps.indices { gaps[i].presence.snap(to: gaps[i].presence.target) }
        }
    }

    /// Hides a tile while it is being dragged (its slot collapses). Without
    /// animation the slot vanishes at once — pair it with a gap at the same
    /// index so nothing visibly moves when a drag starts.
    public func setDraggedItem(_ id: String?, animated: Bool = true) {
        let previous = draggedID
        draggedID = id
        for i in items.indices where !items[i].removing {
            if items[i].spec.id == id {
                if animated {
                    items[i].presence.target = 0
                } else {
                    items[i].presence.snap(to: 0)
                }
                items[i].hover.target = 0
                items[i].press.snap(to: 0)
            } else if items[i].spec.id == previous {
                items[i].presence.target = 1
            }
        }
    }

    public var draggedItemID: String? { draggedID }

    /// True while a drop gap is open (not closing).
    public var hasOpenGap: Bool { gaps.contains { !$0.closing } }

    /// Completes a drop: the dragged (or newly inserted) tile takes the place
    /// of the open gap without any visible jump. Call after `setItems`.
    public func commitDrop(insertedID: String? = nil) {
        let ids = Set([draggedID, insertedID].compactMap { $0 })
        for i in items.indices where ids.contains(items[i].spec.id) && !items[i].removing {
            items[i].presence.dampingFraction = 0.82
            items[i].presence.snap(to: 1)
        }
        draggedID = nil
        gaps.removeAll()
    }

    public func setPressed(_ id: String?) {
        pressedID = id
        for i in items.indices {
            items[i].press.target = items[i].spec.id == id ? 1 : 0
        }
    }

    public func setHighlighted(_ id: String?) {
        highlightedID = id
        for i in items.indices {
            items[i].highlight.target = items[i].spec.id == id ? 1 : 0
        }
    }

    /// A single hop, independent of launching (used for previews and feedback).
    public func bounceOnce(_ id: String) {
        guard bounceEnabled, let i = items.firstIndex(where: { $0.spec.id == id }) else { return }
        if items[i].bounceStart == nil {
            items[i].bounceStart = clock
        }
        if let start = items[i].bounceStart {
            items[i].bounceStop = BounceCurve.stopTime(start: start, request: clock)
        }
    }

    // MARK: - Simulation

    public var isAnimating: Bool {
        !focus.isAtRest || !amount.isAtRest || !reveal.isAtRest || !labelAlpha.isAtRest
            || gaps.contains { !$0.presence.isAtRest }
            || items.contains { $0.isAnimating }
    }

    /// Advances all animations by `dt` seconds and lays out a new frame.
    @discardableResult
    public func tick(_ dt: Double) -> DockFrame {
        let dt = max(0, dt.isFinite ? dt : 0) * max(0.1, speed)
        if dt > 0 {
            clock += dt
            focus.step(dt)
            amount.step(dt)
            reveal.step(dt)
            labelAlpha.step(dt)
            for i in items.indices {
                items[i].step(dt)
                if let stop = items[i].bounceStop, clock >= stop {
                    items[i].bounceStart = nil
                    items[i].bounceStop = nil
                } else if let start = items[i].bounceStart, items[i].bounceStop == nil, clock - start > 20 {
                    // Some apps never report that they finished launching.
                    items[i].bounceStop = BounceCurve.stopTime(start: start, request: clock)
                }
            }
            for i in gaps.indices { gaps[i].presence.step(dt) }
            gaps.removeAll { $0.closing && $0.presence.isAtRest }
            items.removeAll { $0.removing && $0.presence.isAtRest }
        }

        let frame = layout()
        updateHover(frame.hoveredID)
        lastFrame = frame
        return frame
    }

    // MARK: - Private

    private func makeItem(_ spec: DockItemSpec, animated: Bool) -> Item {
        var item = Item(
            spec: spec,
            presence: Spring(animated ? 0 : 1, response: 0.42, dampingFraction: 0.82, precision: 0.001),
            indicator: Spring(spec.isRunning ? 1 : 0, response: 0.3, dampingFraction: 1, precision: 0.002),
            active: Spring(spec.isActive ? 1 : 0, response: 0.35, dampingFraction: 0.75, precision: 0.002),
            hover: Spring(0, response: 0.22, dampingFraction: 0.8, precision: 0.002),
            press: Spring(0, response: 0.16, dampingFraction: 0.55, precision: 0.002),
            highlight: Spring(0, response: 0.25, dampingFraction: 1, precision: 0.002),
            dim: Spring(dimHiddenApps && spec.isHidden ? 1 : 0, response: 0.3, dampingFraction: 1, precision: 0.002)
        )
        item.presence.target = 1
        return item
    }

    private func apply(_ spec: DockItemSpec, to item: inout Item) {
        item.spec = spec
        if item.removing {
            item.removing = false
            item.presence.dampingFraction = 0.82
        }
        item.presence.target = spec.id == draggedID ? 0 : 1
        item.indicator.target = spec.isRunning ? 1 : 0
        item.active.target = spec.isActive ? 1 : 0
        item.dim.target = dimHiddenApps && spec.isHidden ? 1 : 0
        item.highlight.target = spec.id == highlightedID ? 1 : 0
        item.press.target = spec.id == pressedID ? 1 : 0

        if spec.isLaunching && bounceEnabled {
            if item.bounceStart == nil {
                item.bounceStart = clock
            }
            item.bounceStop = nil
        } else if let start = item.bounceStart, item.bounceStop == nil {
            item.bounceStop = BounceCurve.stopTime(start: start, request: clock)
        }
    }

    private func settle(_ item: inout Item) {
        item.presence.snap(to: item.presence.target)
        item.indicator.snap(to: item.indicator.target)
        item.active.snap(to: item.active.target)
        item.dim.snap(to: item.dim.target)
        item.highlight.snap(to: item.highlight.target)
    }

    private func updateHover(_ id: String?) {
        if id != hovered {
            hovered = id
            for i in items.indices {
                items[i].hover.target = items[i].spec.id == id ? 1 : 0
            }
        }
        if let id { labelID = id }
        labelAlpha.target = (id != nil && draggedID == nil && labelsEnabled) ? 1 : 0
    }

    private func layout() -> DockFrame {
        let m = metrics

        // The un-magnified row: tiles (and open gaps) as contiguous slots.
        var slots: [(width: Double, item: Int?)] = []
        slots.reserveCapacity(items.count + gaps.count)
        var live = 0
        func appendGaps(at index: Int) {
            for gap in gaps where gap.index == index {
                slots.append((m.slot * max(0, gap.presence.value), nil))
            }
        }
        for (i, item) in items.enumerated() {
            if !item.removing {
                appendGaps(at: live)
                live += 1
            }
            let base = item.spec.kind == .separator ? m.separatorWidth : m.slot
            slots.append((base * max(0, item.presence.value), i))
        }
        appendGaps(at: live)
        for gap in gaps where gap.index > live {
            slots.append((m.slot * max(0, gap.presence.value), nil))
        }

        let total = slots.reduce(0) { $0 + $1.width }
        let start = stripCenter - total / 2
        let progress = min(max(amount.value, 0), 1)
        let magnifier = Magnifier(
            focus: focus.value,
            peakScale: 1 + (m.peakScale - 1) * progress,
            radius: m.radius
        )
        let revealValue = min(max(reveal.value, 0), 1.05)
        let shelfBaseline = m.edgeGap - (1 - revealValue) * m.hideDistance
        let iconBaseline = shelfBaseline + m.insetBottom
        let magnifying = m.peakScale > 1.001

        var frameItems: [DockFrame.Item] = []
        frameItems.reserveCapacity(items.count)
        var cursor = start
        for slot in slots {
            let a = cursor
            let b = cursor + slot.width
            cursor = b
            guard let index = slot.item else { continue }
            let item = items[index]
            let lo = magnifier.warp(a)
            let hi = magnifier.warp(b)
            let presence = max(0, item.presence.value)
            let localScale = (b - a) > 1e-6 ? (hi - lo) / (b - a) : magnifier.scale(at: a)

            var lift = 0.0
            var mainScale = 1.0
            var crossScale = 1.0
            if bounceEnabled, let bounceStart = item.bounceStart {
                let sample = BounceCurve.sample(elapsed: clock - bounceStart)
                lift += sample.height * m.bounceHeight
                mainScale *= sample.mainScale
                crossScale *= sample.crossScale
            }
            let hover = item.hover.value
            lift += hover * (magnifying ? 2 : 5)
            if !magnifying {
                mainScale *= 1 + 0.06 * hover
                crossScale *= 1 + 0.06 * hover
            }
            let press = item.press.value
            mainScale *= 1 - 0.1 * press
            crossScale *= 1 - 0.1 * press

            let alpha = min(1, presence * 1.5) * (1 - 0.45 * min(max(item.dim.value, 0), 1))
            frameItems.append(DockFrame.Item(
                id: item.spec.id,
                kind: item.spec.kind,
                center: (lo + hi) / 2,
                size: m.iconSize * localScale * min(presence, 1.08),
                slotStart: lo,
                slotEnd: hi,
                baseline: iconBaseline,
                lift: lift,
                mainScale: mainScale,
                crossScale: crossScale,
                alpha: alpha,
                indicator: min(max(item.indicator.value, 0), 1) * min(1, presence * 1.5),
                activeness: min(max(item.active.value, 0), 1.2),
                highlight: min(max(item.highlight.value, 0), 1),
                isLive: !item.removing
            ))
        }

        let padding = m.endPadding - m.spacing / 2
        var frame = DockFrame(
            items: frameItems,
            shelfStart: magnifier.warp(start) - padding,
            shelfEnd: magnifier.warp(start + total) + padding,
            shelfBaseline: shelfBaseline,
            shelfThickness: m.shelfThickness,
            opacity: min(1, max(0, revealValue * 2.2)),
            reveal: revealValue,
            focus: focus.value,
            magnification: progress,
            pointer: pointer
        )

        if let pointer, draggedID == nil, let hit = frame.item(atU: pointer.u, v: pointer.v) {
            frame.hoveredID = hit.id
        }
        if let labelID, let item = frame.item(id: labelID), labelAlpha.value > 0.001 {
            frame.label = DockFrame.Label(id: labelID, u: item.center, v: item.top + 8, alpha: min(max(labelAlpha.value, 0), 1))
        }
        return frame
    }
}
