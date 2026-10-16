import AppKit
import Carbon.HIToolbox

/// PasteMe 的全局快捷键：注册用的键码和修饰键，以及在菜单里显示的样子。
struct GlobalShortcut {
    var keyCode: Int
    /// Carbon 修饰键组合，例如 `cmdKey | shiftKey`。
    var carbonModifiers: Int
    /// 菜单项上显示的按键。
    var keyEquivalent: String
    var modifierMask: NSEvent.ModifierFlags
    /// 写在提示文字里的样子，例如 "⇧⌘V"。
    var symbol: String

    /// 呼出或收起面板。
    static let panel = GlobalShortcut(
        keyCode: kVK_ANSI_V, carbonModifiers: cmdKey | shiftKey,
        keyEquivalent: "v", modifierMask: [.command, .shift], symbol: "⇧⌘V"
    )
    /// 暂停或恢复记录。不用 ⌥⇧⌘V：很多应用用它“粘贴并匹配样式”。
    static let pause = GlobalShortcut(
        keyCode: kVK_ANSI_V, carbonModifiers: cmdKey | shiftKey | controlKey,
        keyEquivalent: "v", modifierMask: [.command, .shift, .control], symbol: "⌃⇧⌘V"
    )
    /// 开启或退出 Paste Stack。
    static let pasteStack = GlobalShortcut(
        keyCode: kVK_ANSI_C, carbonModifiers: cmdKey | shiftKey | controlKey,
        keyEquivalent: "c", modifierMask: [.command, .shift, .control], symbol: "⌃⇧⌘C"
    )
}

extension NSMenuItem {
    /// 在菜单项右侧显示全局快捷键。只是提示，快捷键本身由 `HotKeyCenter` 注册。
    func showShortcut(_ shortcut: GlobalShortcut) {
        keyEquivalent = shortcut.keyEquivalent
        keyEquivalentModifierMask = shortcut.modifierMask
    }
}

/// 用 Carbon 的 `RegisterEventHotKey` 注册全局快捷键。
/// 这个 API 不需要辅助功能权限，是目前注册系统级快捷键最简单可靠的方式。
///
/// 所有快捷键共用一个事件处理器：每个处理器都会收到所有快捷键事件，所以按事件里的快捷键 id 分发，
/// 而不是每个快捷键各装一个处理器。
@MainActor
final class HotKeyCenter {
    /// 注册时分配的编号，用于注销。
    struct ID: Hashable {
        fileprivate let value: UInt32
    }

    /// 写进每个快捷键 id 的签名，用来认出 PasteMe 自己注册的快捷键。"PME1"
    static let signature = OSType(0x504D_4531)

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// 注册一个全局快捷键。快捷键已被其他应用占用等原因注册失败时返回 nil，并记一条日志。
    @discardableResult
    func register(_ shortcut: GlobalShortcut, action: @escaping () -> Void) -> ID? {
        let id = register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, action: action)
        if id == nil {
            NSLog("PasteMe: \(shortcut.symbol) 注册失败，可能已被其他应用占用")
        }
        return id
    }

    /// - Parameters:
    ///   - keyCode: 虚拟键码，例如 `kVK_ANSI_V`。
    ///   - modifiers: Carbon 修饰键组合，例如 `cmdKey | shiftKey`。
    func register(keyCode: Int, modifiers: Int, action: @escaping () -> Void) -> ID? {
        guard installHandlerIfNeeded() else { return nil }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }
        refs[id] = ref
        actions[id] = action
        return ID(value: id)
    }

    func unregister(_ id: ID) {
        if let ref = refs.removeValue(forKey: id.value) { UnregisterEventHotKey(ref) }
        actions[id.value] = nil
    }

    /// 执行按下的快捷键对应的操作。不是这里注册的快捷键时返回 false，事件交给其他处理器。
    @discardableResult
    func dispatch(_ hotKeyID: EventHotKeyID) -> Bool {
        guard hotKeyID.signature == Self.signature, let action = actions[hotKeyID.id] else { return false }
        action()
        return true
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard read == noErr else { return read }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                // 快捷键事件在主线程的事件循环里分发。
                let handled = MainActor.assumeIsolated { center.dispatch(hotKeyID) }
                return handled ? noErr : OSStatus(eventNotHandledErr)
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        return status == noErr
    }

    isolated deinit {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
