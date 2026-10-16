import Testing
@testable import PasteMeApp

@Suite struct PanelMotionTests {
    private func samples(_ motion: PanelMotion, until end: Double) -> [Double] {
        stride(from: 0, through: end, by: 1.0 / 120).map { motion.state(at: $0).progress }
    }

    /// 第一次进入终点附近（误差 1%）的时间。
    private func arrival(_ motion: PanelMotion) -> Double {
        var t = 0.0
        while abs(motion.state(at: t).progress - motion.target) > 0.01 { t += 1.0 / 240 }
        return t
    }

    @Test func showStartsWhereItIsAndBouncesSlightly() {
        let show = PanelMotion(spring: .show, from: 0, target: 1, velocity: 0)
        #expect(show.state(at: 0).progress == 0)

        let peak = samples(show, until: 0.6).max() ?? 0
        #expect(peak > 1.005)
        #expect(peak < 1.05)
    }

    @Test func showArrivesWithinIssueRangeAndSettles() {
        let show = PanelMotion(spring: .show, from: 0, target: 1, velocity: 0)
        #expect(arrival(show) > 0.15)
        #expect(arrival(show) < 0.35)
        #expect(show.isSettled(at: 0.6, tolerance: 0.001))
        #expect(!show.isSettled(at: 0.1, tolerance: 0.001))
    }

    @Test func hideIsFasterThanShowAndNeverBounces() {
        let hide = PanelMotion(spring: .hide, from: 1, target: 0, velocity: 0)
        #expect(arrival(hide) < 0.2)
        #expect(arrival(hide) < arrival(PanelMotion(spring: .show, from: 0, target: 1, velocity: 0)))
        #expect(samples(hide, until: 0.5).allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func reversingMidwayKeepsPositionAndVelocity() {
        let hide = PanelMotion(spring: .hide, from: 1, target: 0, velocity: 0)
        let midway = hide.state(at: 0.05)
        let back = PanelMotion(spring: .show, from: midway.progress, target: 1, velocity: midway.velocity)

        #expect(abs(back.state(at: 0).progress - midway.progress) < 1e-9)
        #expect(abs(back.state(at: 0).velocity - midway.velocity) < 1e-6)
        #expect(back.isSettled(at: 0.8, tolerance: 0.001))
    }

    @Test func fadeForReducedMotionDoesNotBounce() {
        let fade = PanelMotion(spring: .fade, from: 0, target: 1, velocity: 0)
        #expect(samples(fade, until: 0.6).allSatisfy { $0 <= 1 })
    }
}

