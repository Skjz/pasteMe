import Carbon.HIToolbox
import CoreGraphics
import Testing
@testable import PasteMeApp

@Suite struct PasteStackKeysTests {
    func action(_ keyCode: Int, _ flags: CGEventFlags, autorepeat: Bool = false, fromPasteMe: Bool = false) -> PasteStackKeyAction {
        PasteStackKeys.action(keyCode: keyCode, flags: flags, isAutorepeat: autorepeat, isFromPasteMe: fromPasteMe)
    }

    @Test func commandVTakesTheNextEntry() {
        #expect(action(kVK_ANSI_V, .maskCommand) == .pasteNext)
        // 大写锁定、数字键盘这类标记不影响判断。
        #expect(action(kVK_ANSI_V, [.maskCommand, .maskAlphaShift]) == .pasteNext)
    }

    @Test func otherShortcutsWithVAreLeftAlone() {
        #expect(action(kVK_ANSI_V, [.maskCommand, .maskShift]) == .ignore)
        #expect(action(kVK_ANSI_V, [.maskCommand, .maskAlternate, .maskShift]) == .ignore)
        #expect(action(kVK_ANSI_V, []) == .ignore)
        #expect(action(kVK_ANSI_C, .maskCommand) == .ignore)
    }

    @Test func holdingCommandVDoesNotDrainTheStack() {
        #expect(action(kVK_ANSI_V, .maskCommand, autorepeat: true) == .ignore)
    }

    @Test func pasteMeOwnCommandVIsIgnored() {
        #expect(action(kVK_ANSI_V, .maskCommand, fromPasteMe: true) == .ignore)
        #expect(action(kVK_Escape, [], fromPasteMe: true) == .ignore)
    }

    @Test func escapeExits() {
        #expect(action(kVK_Escape, []) == .exit)
        #expect(action(kVK_Escape, .maskCommand) == .ignore)
    }
}
