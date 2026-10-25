import Foundation

/// 启动时要不要删掉辅助功能列表里失效的 PasteMe 条目（ADR 0011）。
///
/// `tccutil reset Accessibility <bundle id>` 按 bundle id 删掉这个用户下的全部记录，不看路径，
/// 也不看那条记录是不是还在给另一份 PasteMe 授权。所以只在下面这些都成立时才删：
/// - 现在没有授权；
/// - 正在运行的就是 LaunchServices 为这个 bundle id 登记的那一份（装好的那个），不是 DMG 里、
///   App Translocation 里或者 `build/` 里试跑的副本：试跑的副本签名不一样、没有授权，删了会连装好的那份的授权一起删；
/// - 这一份签名（designated requirement）还没处理过：授权过的记下来，用户后来自己关掉开关不会被重置；
///   清理过一次的也记下来，用户拒绝了不会每次启动都再删一遍。
public enum StaleGrant {
    public struct Situation: Equatable, Sendable {
        public var isTrusted: Bool
        /// 当前签名的 designated requirement，读不出来时为 nil。
        public var requirement: String?
        /// 正在运行的应用的路径。
        public var appPath: String
        /// LaunchServices 为这个 bundle id 登记的应用路径，没有登记时为 nil。
        public var registeredPath: String?
        /// 上次授权过或清理过的 requirement（`Settings.accessibilityRequirement`）。
        public var handledRequirement: String?

        public init(isTrusted: Bool, requirement: String?, appPath: String, registeredPath: String?, handledRequirement: String?) {
            self.isTrusted = isTrusted
            self.requirement = requirement
            self.appPath = appPath
            self.registeredPath = registeredPath
            self.handledRequirement = handledRequirement
        }
    }

    public enum Action: Equatable, Sendable {
        case nothing
        /// 已经授权：把这份 requirement 记下来。
        case remember(String)
        /// 删掉失效的条目，`tccutil` 成功后记下这份 requirement。
        case reset(String)
    }

    public static func action(for situation: Situation) -> Action {
        guard let requirement = situation.requirement else { return .nothing }
        if situation.isTrusted {
            return situation.handledRequirement == requirement ? .nothing : .remember(requirement)
        }
        guard situation.handledRequirement != requirement,
              let registered = situation.registeredPath,
              isInstalledCopy(situation.appPath, registered: registered)
        else { return .nothing }
        return .reset(requirement)
    }

    static func isInstalledCopy(_ path: String, registered: String) -> Bool {
        let path = canonical(path)
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") { return false }
        return path == canonical(registered)
    }

    /// 解开符号链接（`/var` 和 `/private/var`、`/tmp` 和 `/private/tmp`），去掉末尾的斜杠。
    static func canonical(_ path: String) -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        let real = realpath(path, &resolved) != nil ? String(cString: resolved) : path
        return real.count > 1 && real.hasSuffix("/") ? String(real.dropLast()) : real
    }
}
