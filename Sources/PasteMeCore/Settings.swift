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
    private let defaults: UserDefaults

    /// 不传 `defaults` 时读写这一版的偏好域（`AppVariant.defaultsDomain`）。测试时传入一个独立的 `UserDefaults`。
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

    /// ⌘O 用什么打开文件（#51）。默认是文件自己默认的应用；存的值认不出来时也这样。
    /// 选的应用后来删掉了，打开时按系统默认的方式（`OpenPlan`）。
    public var fileApp: OpenApp {
        get { defaults.string(forKey: Key.fileApp).flatMap(OpenApp.init(rawValue:)) ?? .systemDefault }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.fileApp) }
    }

    /// ⌘O 用什么打开文件夹（#51）。默认访达，规则和 `fileApp` 一样。
    public var folderApp: OpenApp {
        get { defaults.string(forKey: Key.folderApp).flatMap(OpenApp.init(rawValue:)) ?? .systemDefault }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.folderApp) }
    }

    /// 全局快捷键（#50）。没改过时是默认值，清除了是 nil。存的值认不出来时也按默认值处理。
    public func shortcut(for action: GlobalAction) -> KeyCombo? {
        guard let stored = defaults.dictionary(forKey: Key.shortcut(action)) else { return action.defaultCombo }
        // 空的字典表示用户清除了这个快捷键。
        if stored.isEmpty { return nil }
        guard let keyCode = stored["keyCode"] as? Int, let modifiers = stored["modifiers"] as? Int else {
            return action.defaultCombo
        }
        return KeyCombo(keyCode: keyCode, modifiers: KeyCombo.Modifiers(rawValue: modifiers))
    }

    /// 改成 `combo`；传 nil 是清除，这个功能就没有全局快捷键。
    public func setShortcut(_ combo: KeyCombo?, for action: GlobalAction) {
        let value: [String: Int] = combo.map { ["keyCode": $0.keyCode, "modifiers": $0.modifiers.rawValue] } ?? [:]
        defaults.set(value, forKey: Key.shortcut(action))
    }

    /// 恢复默认的快捷键。
    public func resetShortcut(for action: GlobalAction) {
        defaults.removeObject(forKey: Key.shortcut(action))
    }

    /// 最近一次固定条目用的 Pinboard，⌘P 固定到这里。没有时为 nil。
    public var lastPinboardID: Int64? {
        get { (defaults.object(forKey: Key.lastPinboardID) as? NSNumber)?.int64Value }
        nonmutating set { defaults.set(newValue.map { NSNumber(value: $0) }, forKey: Key.lastPinboardID) }
    }

    /// 每天自动检查一次有没有新版本（ADR 0010）。默认 true：只向 GitHub 查最新的发布，不发送任何内容。
    public var checksForUpdates: Bool {
        get { defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Key.checksForUpdates) }
    }

    /// 上一次成功检查更新的时间，没查过为 nil。
    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Key.lastUpdateCheck) as? Date }
        nonmutating set { defaults.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    /// 用户点了「跳过这个版本」的版本号。自动检查不再提示它，手动检查照样提示。
    public var skippedUpdateVersion: String? {
        get { defaults.string(forKey: Key.skippedUpdateVersion) }
        nonmutating set { defaults.set(newValue, forKey: Key.skippedUpdateVersion) }
    }

    /// 辅助功能处理过的签名：授权过的、或者启动时清理过失效条目的 designated requirement（`StaleGrant`，ADR 0011）。
    public var accessibilityRequirement: String? {
        get { defaults.string(forKey: Key.accessibilityRequirement) }
        nonmutating set { defaults.set(newValue, forKey: Key.accessibilityRequirement) }
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
        static let fileApp = "fileApp"
        static let folderApp = "folderApp"
        static let checksForUpdates = "checksForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let accessibilityRequirement = "accessibilityRequirement"

        static func shortcut(_ action: GlobalAction) -> String {
            "shortcut." + action.rawValue
        }
    }

    /// 发布版读写 `io.github.skjz.PasteMe`，其余都读写 `io.github.skjz.PasteMe.dev`（ADR 0009）。
    /// 在应用包里运行时主 bundle id 就是这个偏好域，系统不接受把它当 suite 名（`UserDefaults(suiteName:)` 返回 nil），
    /// 这时 `.standard` 就是它；`swift run`、基准和测试没有这个 bundle id，用 suite（ADR 0006）。
    static func sharedDomain(bundleID: String?) -> (name: String, isStandard: Bool) {
        let name = AppVariant(bundleID: bundleID).defaultsDomain
        return (name, bundleID == name)
    }

    static func sharedDefaults() -> UserDefaults {
        let domain = sharedDomain(bundleID: Bundle.main.bundleIdentifier)
        if domain.isStandard { return .standard }
        return UserDefaults(suiteName: domain.name) ?? .standard
    }
}
