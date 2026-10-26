import XCTest
@testable import MarDockCore

final class EngineTests: XCTestCase {
    private func specs(_ ids: [String]) -> [DockItemSpec] {
        ids.map { DockItemSpec(id: $0) }
    }

    private func settle(_ engine: DockEngine, seconds: Double = 3) -> DockFrame {
        var frame = engine.tick(0)
        var t = 0.0
        while t < seconds {
            frame = engine.tick(1.0 / 120)
            t += 1.0 / 120
        }
        return frame
    }

    func testRestingLayoutIsCenteredAndEvenlySpaced() {
        let metrics = DockMetrics(iconSize: 50, spacing: 10)
        let engine = DockEngine(metrics: metrics)
        engine.stripCenter = 500
        engine.setItems(specs(["a", "b", "c", "d"]), animated: false)
        let frame = engine.tick(0)

        XCTAssertEqual(frame.items.count, 4)
        XCTAssertEqual(frame.items.map(\.size), [50, 50, 50, 50])
        let centers = frame.items.map(\.center)
        XCTAssertEqual(centers[1] - centers[0], 60, accuracy: 1e-9)
        XCTAssertEqual((centers[0] + centers[3]) / 2, 500, accuracy: 1e-9)
        XCTAssertEqual((frame.shelfStart + frame.shelfEnd) / 2, 500, accuracy: 1e-9)
        XCTAssertLessThan(frame.shelfStart, centers[0] - 25)
        XCTAssertGreaterThan(frame.shelfEnd, centers[3] + 25)
    }

    func testHoverMagnifiesTheTileUnderThePointer() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 50, spacing: 10, peakScale: 2))
        engine.stripCenter = 300
        engine.setItems(specs(["a", "b", "c", "d", "e"]), animated: false)
        let resting = engine.tick(0)
        let target = resting.items[2]
        engine.setPointer(DockPointer(u: target.center, v: 30))
        let frame = settle(engine)

        XCTAssertEqual(frame.hoveredID, "c")
        let hovered = frame.items[2]
        XCTAssertGreaterThan(hovered.size, 85)
        XCTAssertLessThanOrEqual(hovered.size, 100.0001)
        // The pointer stays over the tile it was over: the warp fixes the focus.
        XCTAssertTrue(hovered.slotStart <= target.center && target.center <= hovered.slotEnd)
        // Neighbours grow less, and nothing overlaps.
        XCTAssertLessThan(frame.items[1].size, hovered.size)
        for (a, b) in zip(frame.items, frame.items.dropFirst()) {
            XCTAssertLessThanOrEqual(a.slotEnd, b.slotStart + 1e-9)
        }
        // The shelf grew around the magnified tiles.
        XCTAssertGreaterThan(frame.shelfLength, resting.shelfLength)
        XCTAssertEqual(frame.label?.id, "c")
        XCTAssertEqual(frame.label?.alpha ?? 0, 1, accuracy: 1e-6)
    }

    func testMagnificationRelaxesWhenThePointerLeaves() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 50, spacing: 10, peakScale: 2))
        engine.setItems(specs(["a", "b", "c"]), animated: false)
        let base = engine.tick(0)
        engine.setPointer(DockPointer(u: base.items[1].center, v: 20))
        _ = settle(engine)
        engine.setPointer(nil)
        let frame = settle(engine)
        XCTAssertEqual(frame.items.map(\.size), [50, 50, 50])
        XCTAssertNil(frame.hoveredID)
        XCTAssertFalse(engine.isAnimating)
    }

    func testDisabledMagnificationNeverScales() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 40, spacing: 8, peakScale: 1))
        engine.setItems(specs(["a", "b"]), animated: false)
        let base = engine.tick(0)
        engine.setPointer(DockPointer(u: base.items[0].center, v: 20))
        let frame = settle(engine)
        XCTAssertEqual(frame.items.map(\.size), [40, 40])
        XCTAssertEqual(frame.hoveredID, "a")
    }

    func testInsertedTilesGrowInAndRemovedTilesShrinkAway() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 50, spacing: 10))
        engine.setItems(specs(["a", "b"]), animated: false)
        engine.setItems(specs(["a", "x", "b"]), animated: true)
        var frame = engine.tick(0)
        XCTAssertEqual(frame.items.map(\.id), ["a", "x", "b"])
        XCTAssertEqual(frame.items[1].size, 0)
        frame = settle(engine)
        XCTAssertEqual(frame.items[1].size, 50, accuracy: 1e-6)

        engine.setItems(specs(["a", "b"]), animated: true)
        frame = engine.tick(1.0 / 60)
        XCTAssertEqual(frame.items.map(\.id), ["a", "x", "b"], "removed tile animates out in place")
        XCTAssertFalse(frame.items[1].isLive)
        frame = settle(engine)
        XCTAssertEqual(frame.items.map(\.id), ["a", "b"])
        XCTAssertFalse(engine.isAnimating)
    }

    func testReAddingADisappearingTileRevivesIt() {
        let engine = DockEngine()
        engine.setItems(specs(["a", "b"]), animated: false)
        engine.setItems(specs(["a"]), animated: true)
        _ = engine.tick(0.05)
        engine.setItems(specs(["a", "b"]), animated: true)
        let frame = settle(engine)
        XCTAssertEqual(frame.items.map(\.id), ["a", "b"])
        XCTAssertTrue(frame.items.allSatisfy(\.isLive))
    }

    func testDuplicateIDsAreIgnored() {
        let engine = DockEngine()
        engine.setItems(specs(["a", "a", "b"]), animated: false)
        XCTAssertEqual(engine.tick(0).items.map(\.id), ["a", "b"])
    }

    func testLaunchBounceRunsUntilLaunchedThenFinishesTheHop() {
        let engine = DockEngine()
        engine.setItems([DockItemSpec(id: "a", isRunning: true, isLaunching: true)], animated: false)
        var maxLift = 0.0
        for _ in 0..<120 {
            maxLift = max(maxLift, engine.tick(1.0 / 120).items[0].lift)
        }
        XCTAssertGreaterThan(maxLift, engine.metrics.bounceHeight * 0.9)
        engine.setItems([DockItemSpec(id: "a", isRunning: true, isLaunching: false)], animated: true)
        let frame = settle(engine)
        XCTAssertEqual(frame.items[0].lift, 0)
        XCTAssertFalse(engine.isAnimating)
    }

    func testNoBounceWhenReduceMotion() {
        let engine = DockEngine()
        engine.bounceEnabled = false
        engine.setItems([DockItemSpec(id: "a", isLaunching: true)], animated: false)
        for _ in 0..<60 {
            XCTAssertEqual(engine.tick(1.0 / 60).items[0].lift, 0)
        }
    }

    func testAutoHideSlidesTheShelfOffScreen() {
        let engine = DockEngine()
        engine.setItems(specs(["a"]), animated: false)
        engine.setRevealed(false, animated: true)
        let hidden = settle(engine)
        XCTAssertLessThan(hidden.shelfTop, 0)
        XCTAssertEqual(hidden.opacity, 0)
        XCTAssertFalse(hidden.contains(u: hidden.items[0].center, v: 2))
        engine.setRevealed(true, animated: true)
        let shown = settle(engine)
        XCTAssertEqual(shown.shelfBaseline, engine.metrics.edgeGap, accuracy: 1e-6)
        XCTAssertTrue(shown.contains(u: shown.items[0].center, v: 20))
    }

    func testDropGapOpensWhereRequestedAndCommitIsSeamless() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 50, spacing: 10))
        engine.stripCenter = 400
        engine.setItems(specs(["a", "b", "c"]), animated: false)
        engine.setDraggedItem("a")
        engine.setDropGap(at: 2)
        var frame = settle(engine)
        // "a" collapsed, a slot-wide gap sits between b and c.
        let b = frame.items[1], c = frame.items[2]
        XCTAssertEqual(c.center - b.center, 120, accuracy: 1e-6)
        XCTAssertEqual(frame.items[0].size, 0, accuracy: 1e-6)

        let before = frame.items.filter { $0.id != "a" }.map(\.center)
        engine.setItems(specs(["b", "a", "c"]), animated: true)
        engine.commitDrop()
        frame = engine.tick(1.0 / 60)
        let after = frame.items.filter { $0.id != "a" }.map(\.center)
        for (x, y) in zip(before, after) {
            XCTAssertEqual(x, y, accuracy: 1e-6, "neighbours must not jump on drop")
        }
        XCTAssertEqual(frame.item(id: "a")?.size ?? 0, 50, accuracy: 1e-6)
    }

    func testInsertionIndexFollowsTileCenters() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 50, spacing: 10))
        engine.setItems(specs(["a", "b", "c"]), animated: false)
        let frame = engine.tick(0)
        let ids = ["a", "b", "c"]
        XCTAssertEqual(frame.insertionIndex(u: frame.items[0].center - 1, among: ids), 0)
        XCTAssertEqual(frame.insertionIndex(u: frame.items[0].center + 1, among: ids), 1)
        XCTAssertEqual(frame.insertionIndex(u: frame.items[2].center + 100, among: ids), 3)
    }

    func testHitTestingIgnoresSeparatorsAndEmptySpace() {
        let engine = DockEngine(metrics: DockMetrics(iconSize: 50, spacing: 10))
        engine.setItems([DockItemSpec(id: "a"), DockItemSpec(id: "sep", kind: .separator), DockItemSpec(id: "t", kind: .trash)], animated: false)
        let frame = engine.tick(0)
        XCTAssertEqual(frame.item(atU: frame.items[0].center, v: 20)?.id, "a")
        XCTAssertNil(frame.item(atU: frame.items[1].center, v: 20))
        XCTAssertEqual(frame.item(atU: frame.items[2].center, v: 20)?.id, "t")
        XCTAssertNil(frame.item(atU: frame.items[0].center, v: 500))
        XCTAssertFalse(frame.contains(u: frame.shelfEnd + 50, v: 10))
    }

    func testIdleEngineStopsAnimating() {
        let engine = DockEngine()
        engine.setItems(specs(["a", "b"]), animated: true)
        _ = settle(engine)
        XCTAssertFalse(engine.isAnimating)
    }
}

final class AxisTests: XCTestCase {
    func testRoundTripForEveryPosition() {
        for position in DockPosition.allCases {
            let axis = DockAxis(position: position, width: 1440, height: 900)
            let p = axis.toDock(x: 100, y: 40)
            let back = axis.toView(u: p.u, v: p.v)
            XCTAssertEqual(back.x, 100, accuracy: 1e-9)
            XCTAssertEqual(back.y, 40, accuracy: 1e-9)
        }
    }

    func testVAlwaysGrowsAwayFromTheEdge() {
        XCTAssertEqual(DockAxis(position: .bottom, width: 800, height: 600).toDock(x: 10, y: 0).v, 0)
        XCTAssertEqual(DockAxis(position: .left, width: 800, height: 600).toDock(x: 0, y: 10).v, 0)
        XCTAssertEqual(DockAxis(position: .right, width: 800, height: 600).toDock(x: 800, y: 10).v, 0)
        // Side docks run top to bottom.
        let left = DockAxis(position: .left, width: 800, height: 600)
        XCTAssertLessThan(left.toDock(x: 0, y: 590).u, left.toDock(x: 0, y: 10).u)
    }
}
