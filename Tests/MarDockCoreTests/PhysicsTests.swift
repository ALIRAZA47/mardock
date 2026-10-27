import XCTest
@testable import MarDockCore

final class SpringTests: XCTestCase {
    func testSettlesOnTargetForEveryDampingRegime() {
        for damping in [0.3, 0.86, 1.0, 1.6] {
            var spring = Spring(0, response: 0.3, dampingFraction: damping)
            spring.target = 100
            for _ in 0..<600 { spring.step(1.0 / 120) }
            XCTAssertTrue(spring.isAtRest, "ζ=\(damping) did not come to rest")
            XCTAssertEqual(spring.value, 100)
        }
    }

    func testUnderdampedOvershootsAndCriticalDoesNot() {
        var bouncy = Spring(0, response: 0.3, dampingFraction: 0.5)
        var critical = Spring(0, response: 0.3, dampingFraction: 1)
        bouncy.target = 1
        critical.target = 1
        var bouncyMax = 0.0
        var criticalMax = 0.0
        for _ in 0..<240 {
            bouncy.step(1.0 / 120)
            critical.step(1.0 / 120)
            bouncyMax = max(bouncyMax, bouncy.value)
            criticalMax = max(criticalMax, critical.value)
        }
        XCTAssertGreaterThan(bouncyMax, 1.05)
        XCTAssertLessThanOrEqual(criticalMax, 1.0 + 1e-9)
    }

    func testStepSizeIndependence() {
        // The closed-form solution means one big step equals many small ones.
        var coarse = Spring(0, response: 0.4, dampingFraction: 0.7, precision: 1e-9)
        var fine = coarse
        coarse.target = 50
        fine.target = 50
        coarse.step(0.2)
        for _ in 0..<200 { fine.step(0.001) }
        XCTAssertEqual(coarse.value, fine.value, accuracy: 1e-6)
        XCTAssertEqual(coarse.velocity, fine.velocity, accuracy: 1e-5)
    }

    func testHugeAndInvalidTimeStepsStayFinite() {
        var spring = Spring(0, response: 0.2, dampingFraction: 0.6)
        spring.target = 10
        spring.step(10_000)
        XCTAssertTrue(spring.value.isFinite)
        spring.step(-1)
        spring.step(.nan)
        XCTAssertTrue(spring.value.isFinite)
        spring.value = .infinity
        spring.step(0.016)
        XCTAssertEqual(spring.value, 10)
    }

    func testRestingSpringDoesNothing() {
        var spring = Spring(3)
        XCTAssertTrue(spring.isAtRest)
        spring.step(0.016)
        XCTAssertEqual(spring.value, 3)
    }
}

final class MagnifierTests: XCTestCase {
    func testFocusIsAFixedPoint() {
        let m = Magnifier(focus: 312.5, peakScale: 2, radius: 180)
        XCTAssertEqual(m.warp(312.5), 312.5, accuracy: 1e-9)
    }

    func testWarpIsMonotonicAndBoundedGrowth() {
        let m = Magnifier(focus: 0, peakScale: 2.4, radius: 150)
        var previous = -Double.infinity
        for u in stride(from: -500.0, through: 500, by: 0.5) {
            let x = m.warp(u)
            XCTAssertGreaterThan(x, previous)
            previous = x
        }
        // Far from the focus everything is shifted by exactly half the total growth.
        XCTAssertEqual(m.warp(400) - 400, m.maxGrowthPerSide, accuracy: 1e-9)
        XCTAssertEqual(m.warp(-400) + 400, -m.maxGrowthPerSide, accuracy: 1e-9)
    }

    func testDerivativeOfWarpIsScale() {
        let m = Magnifier(focus: 10, peakScale: 1.9, radius: 120)
        for u in stride(from: -150.0, through: 170, by: 7.3) {
            let h = 1e-4
            let derivative = (m.warp(u + h) - m.warp(u - h)) / (2 * h)
            XCTAssertEqual(derivative, m.scale(at: u), accuracy: 1e-5)
        }
        XCTAssertEqual(m.scale(at: 10), 1.9, accuracy: 1e-12)
        XCTAssertEqual(m.scale(at: 500), 1)
    }

    func testIdentityWhenDisabled() {
        let m = Magnifier(focus: 0, peakScale: 1, radius: 100)
        XCTAssertEqual(m.warp(42), 42)
        XCTAssertEqual(m.scale(at: 0), 1)
    }
}

final class BounceTests: XCTestCase {
    func testHopsReturnToTheGround() {
        XCTAssertEqual(BounceCurve.sample(elapsed: 0).height, 0)
        XCTAssertEqual(BounceCurve.sample(elapsed: BounceCurve.period / 2).height, 1, accuracy: 1e-9)
        XCTAssertEqual(BounceCurve.sample(elapsed: BounceCurve.period * 3).height, 0, accuracy: 1e-9)
    }

    func testSquashIsSubtle() {
        for t in stride(from: 0.0, through: 2.0, by: 0.01) {
            let s = BounceCurve.sample(elapsed: t)
            XCTAssertTrue((0.85...1.15).contains(s.mainScale))
            XCTAssertTrue((0.85...1.15).contains(s.crossScale))
        }
    }

    func testStopsAtTheEndOfAHopAndNeverBeforeOne() {
        let p = BounceCurve.period
        XCTAssertEqual(BounceCurve.stopTime(start: 1, request: 1), 1 + p, accuracy: 1e-9)
        XCTAssertEqual(BounceCurve.stopTime(start: 1, request: 1 + p * 1.2), 1 + 2 * p, accuracy: 1e-9)
    }
}

final class AutoHideTests: XCTestCase {
    func testOffModeIsAlwaysShown() {
        var logic = AutoHideLogic(mode: .off)
        XCTAssertTrue(logic.update(.init(now: 0)))
        XCTAssertTrue(logic.update(.init(now: 10)))
    }

    func testAlwaysModeHidesAfterDelayAndRevealsAtEdge() {
        var logic = AutoHideLogic(mode: .always, revealDelay: 0.2, hideDelay: 0.5)
        XCTAssertTrue(logic.update(.init(now: 0)))
        XCTAssertTrue(logic.update(.init(now: 0.4)))
        XCTAssertFalse(logic.update(.init(now: 0.51)))
        // Touching the edge only reveals after the delay.
        XCTAssertFalse(logic.update(.init(now: 1, pointerAtEdge: true)))
        XCTAssertTrue(logic.hasPendingTransition)
        XCTAssertTrue(logic.update(.init(now: 1.25, pointerAtEdge: true)))
        // Staying over the dock keeps it open.
        XCTAssertTrue(logic.update(.init(now: 5, pointerInDock: true)))
    }

    func testBrushingTheEdgeDoesNotReveal() {
        var logic = AutoHideLogic(mode: .always, revealDelay: 0.3, hideDelay: 0)
        _ = logic.update(.init(now: 0))
        XCTAssertFalse(logic.isShown)
        XCTAssertFalse(logic.update(.init(now: 1, pointerAtEdge: true)))
        XCTAssertFalse(logic.update(.init(now: 1.1, pointerAtEdge: false)))
        XCTAssertFalse(logic.update(.init(now: 1.5, pointerAtEdge: true)))
        XCTAssertFalse(logic.update(.init(now: 1.7, pointerAtEdge: true)))
        XCTAssertTrue(logic.update(.init(now: 1.85, pointerAtEdge: true)))
    }

    func testSmartModeOnlyHidesForOverlappingWindows() {
        var logic = AutoHideLogic(mode: .smart, revealDelay: 0, hideDelay: 0)
        XCTAssertTrue(logic.update(.init(now: 0, windowOverlaps: false)))
        XCTAssertFalse(logic.update(.init(now: 1, windowOverlaps: true)))
        XCTAssertTrue(logic.update(.init(now: 2, windowOverlaps: false)))
    }

    func testHoldOpenWins() {
        var logic = AutoHideLogic(mode: .always, hideDelay: 0)
        XCTAssertTrue(logic.update(.init(now: 0, holdOpen: true)))
        XCTAssertTrue(logic.update(.init(now: 9, holdOpen: true)))
    }
}
