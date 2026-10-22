import Foundation

/// 当前运行的是发布版还是开发版（ADR 0009）。两者的偏好域、历史目录和缓存目录都分开，
/// 开发时启动的测试实例改不到用户自己在用的 PasteMe 的设置，也碰不到它的历史。
public enum AppVariant: Equatable, Sendable {
    /// `scripts/make-dmg.sh` 打出来的应用，bundle id 是 `releaseBundleID`。
    case release
    /// 其余的运行方式：`scripts/bundle.sh` 打的 PasteMe Dev（bundle id 是 `developmentBundleID`），
    /// 以及没有 bundle id 的 `swift run`、基准和截图模式，还有测试进程。
    case development

    public static let releaseBundleID = "io.github.skjz.PasteMe"
    public static let developmentBundleID = "io.github.skjz.PasteMe.dev"

    /// 只有 bundle id 正好是发布版的才算发布版。
    public init(bundleID: String?) {
        self = bundleID == Self.releaseBundleID ? .release : .development
    }

    /// 当前进程。
    public static let current = AppVariant(bundleID: Bundle.main.bundleIdentifier)

    /// 偏好域的名字，和这一版应用的 bundle id 相同。
    public var defaultsDomain: String {
        switch self {
        case .release: Self.releaseBundleID
        case .development: Self.developmentBundleID
        }
    }

    /// `~/Library/Application Support` 和 `~/Library/Caches` 下放 PasteMe 文件的目录名。
    public var folderName: String {
        switch self {
        case .release: "PasteMe"
        case .development: "PasteMe Dev"
        }
    }
}
