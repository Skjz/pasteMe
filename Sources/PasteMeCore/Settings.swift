import Foundation

/// 光标（标出选中卡片的发光边框）的样式。
public enum CursorStyle: String, CaseIterable, Sendable {
    /// 光晕缓慢地变强变弱。
    case breathe
    /// 渐变描边沿边框旋转，外面有光晕。
    case flow
}

/// 自动清除多久以前的历史（#34）。只清除不在 Pinboard 里的条目，按最后一次使用的时间算。
public enum HistoryRetention: String, CaseIterable, Sendable {
    case never
    case week
    case month
    case quarter
    case year

    /// 保留的天数，`never` 为 nil。
    public var days: Int? {
        switch self {
        case .never: nil
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .year: 365
        }
    }

    /// 早于这个时间的条目要清除。`never` 为 nil。
    public func cutoff(now: Date = Date()) -> Date? {
        days.map { now.addingTimeInterval(-Double($0) * 24 * 60 * 60) }
    }
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

    /// 用户给来源应用加的别名，键是 bundle id。搜索时和应用的名字一样匹配（`AppNames`）。
    /// 写入时去掉首尾空白、空的和重复的别名，没有别名的应用不保存。
    public var appAliases: [String: [String]] {
        get { defaults.dictionary(forKey: Key.appAliases) as? [String: [String]] ?? [:] }
        nonmutating set {
            var cleaned: [String: [String]] = [:]
            for (bundleID, aliases) in newValue {
                let aliases = AppAlias.parse(aliases.joined(separator: "\n"))
                if !aliases.isEmpty { cleaned[bundleID] = aliases }
            }
            defaults.set(cleaned, forKey: Key.appAliases)
        }
    }

    /// 原样粘贴图片时也附带一个 PNG 文件（#12），和右键菜单里的「以文件粘贴」一样。默认 false：
    /// 有些聊天软件收到文件会当作附件发出去，而不是显示成图片。
    public var pasteImagesAsFiles: Bool {
        get { defaults.bool(forKey: Key.pasteImagesAsFiles) }
        nonmutating set { defaults.set(newValue, forKey: Key.pasteImagesAsFiles) }
    }

    /// 复制被记录时播放提示音（#25）。默认 false：常驻后台的工具升级后突然开始出声会打扰用户，由用户自己打开。
    public var playsSoundOnRecord: Bool {
        get { defaults.bool(forKey: Key.playsSoundOnRecord) }
        nonmutating set { defaults.set(newValue, forKey: Key.playsSoundOnRecord) }
    }

    /// 复制链接后获取什么（#11）。默认关闭：获取会向对方网站发请求，要用户自己选；
    /// 「只取网站图标」不会打开复制的网址，「完整预览」会，一次性的链接在极少数情况下可能因此失效。
    /// 存的值认不出来时也按关闭处理。
    public var linkPreviewMode: LinkPreviewMode {
        get { defaults.string(forKey: Key.linkPreviewMode).flatMap(LinkPreviewMode.init(rawValue:)) ?? .off }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.linkPreviewMode) }
    }

    /// 自动清除多久以前的历史（#34）。默认不清除：升级后不能自己开始删用户的数据。存的值认不出来时也按不清除处理。
    public var historyRetention: HistoryRetention {
        get { defaults.string(forKey: Key.historyRetention).flatMap(HistoryRetention.init(rawValue:)) ?? .never }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.historyRetention) }
    }

    /// 最近一次固定条目用的 Pinboard，⌘P 固定到这里。没有时为 nil。
    public var lastPinboardID: Int64? {
        get { (defaults.object(forKey: Key.lastPinboardID) as? NSNumber)?.int64Value }
        nonmutating set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Key.lastPinboardID) }
    }

    /// 改一个应用的别名，其他应用的不变。
    public func setAliases(_ aliases: [String], for bundleID: String) {
        var all = appAliases
        all[bundleID] = aliases
        appAliases = all
    }

    private enum Key {
        static let showDuringScreenSharing = "showDuringScreenSharing"
        static let cursorStyle = "cursorStyle"
        static let appAliases = "appAliases"
        static let pasteImagesAsFiles = "pasteImagesAsFiles"
        static let linkPreviewMode = "linkPreviewMode"
        static let lastPinboardID = "lastPinboardID"
        static let historyRetention = "historyRetention"
        static let playsSoundOnRecord = "playsSoundOnRecord"
    }

    /// 在 PasteMe.app 里运行时主 bundle id 就是 `suiteName`，系统不接受把它当 suite 名
    /// （`UserDefaults(suiteName:)` 返回 nil），这时 `.standard` 就是这个偏好域。
    /// `swift run` 或测试时没有这个 bundle id，用 suite 读写同一个偏好文件。见 ADR 0006。
    static func sharedDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}
