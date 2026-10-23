import Foundation
import Testing
@testable import PasteMeCore

/// 全局快捷键的保存和录制时的检查（#50）。
@Suite final class ShortcutsTests {
    let suiteName = "PasteMeTests.Shortcuts.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    static let optionCommandK = KeyCombo(keyCode: 40, modifiers: [.option, .command])

    @Test func shortcutsStartAtTheirDefaults() {
        let settings = Settings(defaults: defaults)
        for action in GlobalAction.allCases {
            #expect(settings.shortcut(for: action) == action.defaultCombo)
        }
        #expect(GlobalAction.panel.defaultCombo == KeyCombo(keyCode: 9, modifiers: [.shift, .command]))
    }

    @Test func aRecordedShortcutPersists() {
        Settings(defaults: defaults).setShortcut(Self.optionCommandK, for: .panel)
        #expect(Settings(defaults: defaults).shortcut(for: .panel) == Self.optionCommandK)
        #expect(Settings(defaults: defaults).shortcut(for: .pause) == GlobalAction.pause.defaultCombo)
    }

    @Test func clearingAndResetting() {
        let settings = Settings(defaults: defaults)
        settings.setShortcut(nil, for: .pasteStack)
        #expect(Settings(defaults: defaults).shortcut(for: .pasteStack) == nil)
        settings.resetShortcut(for: .pasteStack)
        #expect(Settings(defaults: defaults).shortcut(for: .pasteStack) == GlobalAction.pasteStack.defaultCombo)
    }

    @Test func unreadableValuesFallBackToTheDefault() {
        defaults.set(["keyCode": "v"], forKey: "shortcut.panel")
        defaults.set("⇧⌘V", forKey: "shortcut.pause")
        #expect(Settings(defaults: defaults).shortcut(for: .panel) == GlobalAction.panel.defaultCombo)
        #expect(Settings(defaults: defaults).shortcut(for: .pause) == GlobalAction.pause.defaultCombo)
    }

    private func problem(_ combo: KeyCombo, for action: GlobalAction = .panel, reserved: Set<KeyCombo> = []) -> String? {
        let current = Dictionary(uniqueKeysWithValues: GlobalAction.allCases.map { ($0, $0.defaultCombo) })
        return ShortcutRules.problem(with: combo, for: action, current: current, isReservedBySystem: reserved.contains)
    }

    @Test func aShortcutNeedsCommandControlOrOption() {
        #expect(problem(KeyCombo(keyCode: 9, modifiers: [])) == "要带上 ⌘、⌃ 或 ⌥ 中的至少一个")
        #expect(problem(KeyCombo(keyCode: 9, modifiers: [.shift])) == "要带上 ⌘、⌃ 或 ⌥ 中的至少一个")
        #expect(problem(KeyCombo(keyCode: 9, modifiers: [.control])) == nil)
        #expect(problem(Self.optionCommandK) == nil)
    }

    @Test func twoActionsCannotShareAShortcut() {
        #expect(problem(GlobalAction.pause.defaultCombo, for: .panel) == "和「暂停或恢复记录」的快捷键相同")
        // 录回自己现在的组合不算重复。
        #expect(problem(GlobalAction.panel.defaultCombo, for: .panel) == nil)
    }

    @Test func systemShortcutsAreRejected() {
        let commandSpace = KeyCombo(keyCode: 49, modifiers: [.command])
        #expect(problem(commandSpace, reserved: [commandSpace]) == "系统已经用了这个组合")
    }
}
