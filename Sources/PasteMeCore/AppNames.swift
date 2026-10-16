import CoreServices
import Foundation

/// 应用自己声明的名字：Info.plist 里的名字、应用包的文件名，以及英文和用户语言下的本地化名字。
/// 例如访达是 ["Finder", "访达"]，微信是 ["WeChat", "微信"]。
public enum AppBundleNames {
    /// 找到这个 bundle id 的应用并读出它的名字。没装这个应用时返回空数组。不依赖主线程。
    public static func names(ofBundleID bundleID: String, languages: [String] = Locale.preferredLanguages) -> [String] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL],
              let url = urls.first,
              let bundle = Bundle(url: url)
        else { return [] }
        return names(of: bundle, languages: languages)
    }

    /// 只读 `languages` 和英文对应的本地化，其他语言（例如 Safari 的阿拉伯文名字）搜索时用不上。
    public static func names(of bundle: Bundle, languages: [String] = Locale.preferredLanguages) -> [String] {
        var names: [String] = []
        func add(_ value: Any?) {
            guard let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { return }
            names.append(name)
        }
        func addNames(in table: [String: Any]?) {
            add(table?["CFBundleDisplayName"])
            add(table?["CFBundleName"])
        }

        addNames(in: bundle.infoDictionary)
        add(bundle.bundleURL.deletingPathExtension().lastPathComponent)

        var localizations: [String] = []
        for language in languages + ["en"] {
            for localization in Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [language])
            where !localizations.contains(localization) {
                localizations.append(localization)
            }
        }
        // 系统应用把各语言的名字放在一个 InfoPlist.loctable 里，其他应用放在各个 .lproj/InfoPlist.strings 里。
        let table = bundle.url(forResource: "InfoPlist", withExtension: "loctable")
            .flatMap { NSDictionary(contentsOf: $0) as? [String: [String: Any]] }
        for localization in localizations {
            if let url = bundle.url(forResource: "InfoPlist", withExtension: "strings", subdirectory: nil, localization: localization) {
                addNames(in: NSDictionary(contentsOf: url) as? [String: Any])
            }
            addNames(in: table?[localization])
        }
        return names
    }
}

/// 应用别名：用户给来源应用起的其他名字，在设置里按 bundle id 保存。
public enum AppAlias {
    /// 把输入框里的文字拆成别名：逗号（全角半角都行）、顿号、分号或换行分隔，去掉首尾空白和重复的。
    /// 空格不分隔，别名里可以有空格，例如 "System Preferences"。
    public static func parse(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，、;；\n")
        var aliases: [String] = []
        for part in text.components(separatedBy: separators) {
            let alias = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !alias.isEmpty, !aliases.contains(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                aliases.append(alias)
            }
        }
        return aliases
    }

    /// 输入框里显示的样子。
    public static func format(_ aliases: [String]) -> String {
        aliases.joined(separator: ", ")
    }
}

/// 来源应用的所有名字：记录时的名字、应用自己声明的各语言名字（`AppBundleNames`）、用户加的别名。
/// 搜索框里的文字和 `app:` 都按这些名字找应用，所以访达的条目搜 "finder" 也能找到。
@MainActor
public final class AppNames {
    /// 按 bundle id 读应用自己声明的名字。会在后台线程调用。
    public typealias SystemNames = @Sendable (String) -> [String]

    private let store: ClipStore
    private let settings: Settings
    private let lookup: SystemNames
    /// 应用自己声明的名字。应用改名很少见，读过一次就一直用。
    private var systemNamesCache: [String: [String]] = [:]
    /// 历史里出现过的来源应用。`historyChanged()` 后重新读。
    private var apps: [SourceApp]?

    public init(store: ClipStore, settings: Settings, systemNames: @escaping SystemNames = { AppBundleNames.names(ofBundleID: $0) }) {
        self.store = store
        self.settings = settings
        lookup = systemNames
    }

    /// 名字或别名包含 `text` 的来源应用（bundle id），不区分大小写和全角半角。`text` 为空时返回空数组。
    public func bundleIDs(matching text: String) -> [String] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return apps(matching: text).map(\.bundleID)
    }

    /// 名字或别名包含 `text` 的来源应用，搜索框里 `@` 后面的候选列表用。有名字以 `text` 开头的排在前面，
    /// 其余的按条目数排列。`text` 为空时返回所有来源应用。
    public func apps(matching text: String) -> [SourceApp] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return sourceApps() }
        let aliases = settings.appAliases
        let options: String.CompareOptions = [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]
        var prefixed: [SourceApp] = []
        var contained: [SourceApp] = []
        for app in sourceApps() {
            let names = [app.name] + systemNames(of: app.bundleID) + (aliases[app.bundleID] ?? [])
            if names.contains(where: { $0.range(of: text, options: options.union(.anchored)) != nil }) {
                prefixed.append(app)
            } else if names.contains(where: { $0.range(of: text, options: options) != nil }) {
                contained.append(app)
            }
        }
        return prefixed + contained
    }

    /// 应用自己声明的名字，不含用户的别名。还没读过时现在读。
    public func systemNames(of bundleID: String) -> [String] {
        if let cached = systemNamesCache[bundleID] { return cached }
        let names = lookup(bundleID)
        systemNamesCache[bundleID] = names
        return names
    }

    /// 历史里出现过的来源应用，按条目数排列。
    public func sourceApps() -> [SourceApp] {
        if let apps { return apps }
        do {
            let apps = try store.sourceApps()
            self.apps = apps
            return apps
        } catch {
            NSLog("PasteMe: 读取来源应用失败：\(error)")
            return []
        }
    }

    /// 历史可能出现了新的来源应用，例如重新打开面板时。下次搜索时重新列出应用。
    public func historyChanged() {
        apps = nil
    }

    /// 在后台读出历史里所有来源应用的名字，第一次搜索时就不用在主线程上读。读一个应用要一两毫秒。
    public func prefetch() async {
        let missing = sourceApps().map(\.bundleID).filter { systemNamesCache[$0] == nil }
        guard !missing.isEmpty else { return }
        let lookup = lookup
        let found = await Task.detached(priority: .utility) {
            missing.map { ($0, lookup($0)) }
        }.value
        for (bundleID, names) in found {
            systemNamesCache[bundleID] = names
        }
    }
}
