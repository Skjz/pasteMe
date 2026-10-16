import Foundation
import Testing
@testable import PasteMeApp

/// 删除和撤销动画的场景测试：在 `PanelSimulator` 的虚拟时钟上逐帧检查颗粒和卡片是否对齐、
/// 卡片有没有滑进颗粒的范围。每个场景都是以前在真实使用中出过问题的操作。
@MainActor
@Suite struct DeleteAnimationScenarioTests {
    func expectNoProblems(_ panel: PanelSimulator, sourceLocation: SourceLocation = #_sourceLocation) {
        panel.settle()
        #expect(panel.problems.isEmpty, "\(panel.problems.prefix(5).joined(separator: "\n"))", sourceLocation: sourceLocation)
    }

    @Test func deletingSeveralCardsInARow() async throws {
        let panel = try await PanelSimulator.make()
        for _ in 0..<3 {
            panel.deleteSelected()
            panel.wait(0.1)
        }
        expectNoProblems(panel)
    }

    @Test func deletingWhileTheCardsAreStillSlidingIntoPlace() async throws {
        let panel = try await PanelSimulator.make()
        panel.deleteSelected()
        // 颗粒散完（约 1.44 秒）后右边的卡片开始补位，补位途中再删。
        panel.wait(1.5)
        panel.deleteSelected()
        panel.wait(0.08)
        panel.deleteSelected()
        expectNoProblems(panel)
    }

    @Test func undoingSeveralCardsBeforeTheDustIsGone() async throws {
        let panel = try await PanelSimulator.make()
        for _ in 0..<3 {
            panel.deleteSelected()
            panel.wait(0.1)
        }
        panel.wait(0.6)
        for _ in 0..<3 {
            panel.undo()
            panel.wait(0.15)
        }
        expectNoProblems(panel)
    }

    @Test func undoingSeveralCardsAfterTheCardsHaveSlidIn() async throws {
        let panel = try await PanelSimulator.make()
        for _ in 0..<3 {
            panel.deleteSelected()
            panel.wait(0.1)
        }
        panel.wait(2.5)
        for _ in 0..<3 {
            panel.undo()
            panel.wait(0.15)
        }
        expectNoProblems(panel)
    }

    /// 连删两张后撤销第二张，第二张还在聚拢时第一张散完了：第一个空位要等第二张拼好再去掉，
    /// 否则第二张聚拢途中右边的卡片就开始补位。
    @Test func earlierGapWaitsForTheUndoneCardToReassemble() async throws {
        let panel = try await PanelSimulator.make()
        panel.deleteSelected()
        panel.wait(0.1)
        panel.deleteSelected()
        panel.wait(1.1)
        panel.undo()
        expectNoProblems(panel)
    }

    @Test func deletingFromTheContextMenuAndMovingTheSelection() async throws {
        let panel = try await PanelSimulator.make()
        panel.delete(atPosition: 3)
        panel.moveSelection(by: 2)
        panel.wait(0.2)
        panel.deleteSelected()
        panel.wait(0.3)
        panel.undo()
        panel.moveSelection(by: -1)
        panel.wait(0.1)
        panel.undo()
        expectNoProblems(panel)
    }

    /// 平时跑 60 个种子，约 3 秒。改了删除动画的逻辑后，用 `PASTEME_FUZZ_SEEDS=2000 swift test --filter randomSequences` 多跑一些。
    nonisolated static let seeds = 0..<(ProcessInfo.processInfo.environment["PASTEME_FUZZ_SEEDS"].flatMap(UInt64.init) ?? 60)

    /// 随机的删除、撤销、移动选中项和等待，每个种子 25 步。出问题时报告种子和操作，方便重现；
    /// 用 `PM_TRACE=<种子>` 逐帧打印那个种子的状态。
    @Test(arguments: seeds)
    func randomSequences(seed: UInt64) async throws {
        let panel = try await PanelSimulator.make(count: 14)
        panel.trace = ProcessInfo.processInfo.environment["PM_TRACE"] == "\(seed)"
        var random = SeededGenerator(seed: seed)
        var steps: [String] = []
        for _ in 0..<25 {
            switch Int.random(in: 0..<100, using: &random) {
            case 0..<30:
                if panel.trace { print("[TRACE] op 删除选中") }
                steps.append("删除选中")
                panel.deleteSelected()
            case 30..<40:
                let position = Int.random(in: 0..<6, using: &random)
                steps.append("右键删除第 \(position) 格")
                if panel.trace { print("[TRACE] op 右键删除第 \(position) 格") }
                panel.delete(atPosition: position)
            case 40..<65:
                steps.append("撤销")
                if panel.trace { print("[TRACE] op 撤销") }
                panel.undo()
            case 65..<75:
                let offset = Bool.random(using: &random) ? 1 : -1
                steps.append("选中项移动 \(offset)")
                if panel.trace { print("[TRACE] op 选中项移动 \(offset)") }
                panel.moveSelection(by: offset)
            case 75..<95:
                let seconds = Double.random(in: 0.02...0.4, using: &random)
                steps.append(String(format: "等 %.2f 秒", seconds))
                panel.wait(seconds)
            default:
                let seconds = Double.random(in: 1...2, using: &random)
                steps.append(String(format: "等 %.2f 秒", seconds))
                panel.wait(seconds)
            }
        }
        panel.settle()
        #expect(
            panel.problems.isEmpty,
            "种子 \(seed)：\(steps.joined(separator: "，"))\n\(panel.problems.prefix(5).joined(separator: "\n"))"
        )
    }
}
