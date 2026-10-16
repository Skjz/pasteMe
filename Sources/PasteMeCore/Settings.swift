import Foundation

/// 光标（标出选中卡片的发光边框）的样式。
public enum CursorStyle: String, CaseIterable, Sendable {
    /// 光晕缓慢地变强变弱。
    case breathe
    /// 渐变描边沿边框旋转，外面有光晕。
    case flow
}

/// 用户可以修改的开关，集中定义在这里。应用和 MCP 子进程读写同一个偏好域。
public struct Settings {
    /// 偏好域的名字，与 PasteMe.app 的 bundle id 相同。
    public static let suiteName = "io.github.skjz.PasteMe"

    private let defaults: UserDefaults

    /// 不传 `defaults` 时读写 `suiteName` 这个偏好域。测试时传入一个独立的 `UserDefaults`。
    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.sharedDefaults()
    }

    /// 共享屏幕、录屏和截图时是否显示面板。默认 false，即对其他人隐藏。
    public var showDuringScreenSharing: Bool {
        get { defaults.bool(forKey: Key.showDuringScreenSharing) }
        nonmutating set { defaults.set(newValue, forKey: Key.showDuringScreenSharing) }
    }

    /// 面板上光标的样式。默认呼吸；存的值认不出来时也按呼吸处理。
    public var cursorStyle: CursorStyle {
        get { defaults.string(forKey: Key.cursorStyle).flatMap(CursorStyle.init(rawValue:)) ?? .breathe }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.cursorStyle) }
    }

    private enum Key {
        static let showDuringScreenSharing = "showDuringScreenSharing"
        static let cursorStyle = "cursorStyle"
    }

    /// 在 PasteMe.app 里运行时主 bundle id 就是 `suiteName`，系统不接受把它当 suite 名
    /// （`UserDefaults(suiteName:)` 返回 nil），这时 `.standard` 就是这个偏好域。
    /// `swift run` 或测试时没有这个 bundle id，用 suite 读写同一个偏好文件。见 ADR 0006。
    static func sharedDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
