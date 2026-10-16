import Carbon.HIToolbox
import Testing
@testable import PasteMeApp

/// 注册的是 ⌃⌥⇧⌘ 加 F16…F19，不会和常用快捷键冲突。测试并行运行，同一个组合不能同时注册两次，
/// 所以每个测试用不同的键。按下快捷键的事件由测试直接调用 `dispatch` 模拟。
@MainActor
@Suite struct HotKeyCenterTests {
    let center = HotKeyCenter()
    let modifiers = cmdKey | shiftKey | optionKey | controlKey

    @Test func eachHotKeyRunsOnlyItsOwnAction() throws {
        var pressed: [String] = []
        _ = try #require(center.register(keyCode: kVK_F18, modifiers: modifiers) { pressed.append("F18") })
        _ = try #require(center.register(keyCode: kVK_F19, modifiers: modifiers) { pressed.append("F19") })

        #expect(center.dispatch(EventHotKeyID(signature: HotKeyCenter.signature, id: 2)))
        #expect(center.dispatch(EventHotKeyID(signature: HotKeyCenter.signature, id: 1)))
        #expect(pressed == ["F19", "F18"])
    }

    @Test func ignoresHotKeysRegisteredElsewhere() throws {
        var pressed = 0
        _ = try #require(center.register(keyCode: kVK_F17, modifiers: modifiers) { pressed += 1 })

        #expect(!center.dispatch(EventHotKeyID(signature: OSType(0x4F54_4852), id: 1)))
        #expect(!center.dispatch(EventHotKeyID(signature: HotKeyCenter.signature, id: 99)))
        #expect(pressed == 0)
    }

    @Test func unregisteredHotKeyNoLongerRuns() throws {
        var pressed = 0
        let id = try #require(center.register(keyCode: kVK_F16, modifiers: modifiers) { pressed += 1 })

        center.unregister(id)

        #expect(!center.dispatch(EventHotKeyID(signature: HotKeyCenter.signature, id: 1)))
        #expect(pressed == 0)
    }
}
