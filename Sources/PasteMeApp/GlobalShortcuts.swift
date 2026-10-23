import AppKit
import PasteMeCore

/// 三个功能的全局快捷键（#50）：按 `Settings` 里存的组合注册，改了以后重新注册。菜单、提示里显示的组合
/// 每次用时从这里读（`combo(for:)`、`symbol(for:)`），不另存一份。
/// 录制新组合时先全部注销（`suspend`）：不然按下现在的组合会被拦下，设置窗口收不到这次按键。
@MainActor
final class GlobalShortcuts {
    private let center = HotKeyCenter()
    private let settings: PasteMeCore.Settings
    private var actions: [GlobalAction: () -> Void] = [:]
    private var registered: [GlobalAction: HotKeyCenter.ID] = [:]
    private var suspended = false

    /// 没有注册上的功能，设置窗口里提示。
    private(set) var failed: Set<GlobalAction> = []

    init(settings: PasteMeCore.Settings) {
        self.settings = settings
    }

    /// 按下 `action` 的快捷键时执行 `perform`。三个都设好后调用 `registerAll()`。
    func set(_ action: GlobalAction, perform: @escaping () -> Void) {
        actions[action] = perform
    }

    /// 现在的组合，清除了是 nil。
    func combo(for action: GlobalAction) -> KeyCombo? {
        settings.shortcut(for: action)
    }

    /// 写在提示文字里的样子，例如 "⇧⌘V"。清除了是 nil。
    func symbol(for action: GlobalAction) -> String? {
        combo(for: action)?.symbol
    }

    /// 按设置重新注册所有快捷键。录制中（`suspend` 之后）不注册，`resume` 时再注册。
    func registerAll() {
        for id in registered.values { center.unregister(id) }
        registered = [:]
        failed = []
        if !suspended {
            for action in GlobalAction.allCases {
                guard let combo = combo(for: action), let perform = actions[action] else { continue }
                if let id = center.register(combo, action: perform) {
                    registered[action] = id
                } else {
                    failed.insert(action)
                }
            }
        }
    }

    func suspend() {
        suspended = true
        registerAll()
    }

    func resume() {
        suspended = false
        registerAll()
    }
}
