import Foundation

/// 打开文件和文件夹用的应用（#51）：设置窗口「面板」页里给文件、文件夹各选一个，右键菜单「打开方式」里随时可以换。
public enum OpenApp: String, CaseIterable, Sendable {
    /// 系统默认的方式：文件用它默认的应用，文件夹用访达。
    case systemDefault
    case visualStudioCode
    case cursor
    case terminal
    case iTerm
    case ghostty
    case otty

    /// 系统默认的方式为 nil。
    public var bundleID: String? {
        switch self {
        case .systemDefault: nil
        case .visualStudioCode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .terminal: "com.apple.Terminal"
        case .iTerm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .otty: "io.appmakes.otty"
        }
    }

    /// 终端只接收文件夹：打开文件时打开它所在的文件夹。把脚本交给终端会直接执行它。
    public var isTerminal: Bool {
        switch self {
        case .terminal, .iTerm, .ghostty, .otty: true
        case .systemDefault, .visualStudioCode, .cursor: false
        }
    }

    /// 菜单和设置里的名字。系统默认的方式对文件夹是访达，对文件是默认的应用。
    public func title(forFolders: Bool) -> String {
        switch self {
        case .systemDefault: forFolders ? "访达" : "默认的应用"
        case .visualStudioCode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .terminal: "终端"
        case .iTerm: "iTerm2"
        case .ghostty: "Ghostty"
        case .otty: "Otty"
        }
    }

    /// 装了才能选。系统默认的方式总是在。
    public func isAvailable(isInstalled: (String) -> Bool) -> Bool {
        bundleID.map(isInstalled) ?? true
    }
}

/// ⌘O 打开一个条目（#51）：每个网址用哪个应用打开。链接用默认浏览器；文件和文件夹各用设置里选的应用，
/// 右键菜单「打开方式」里选了别的应用时两者都用它。选的应用后来删掉了就按系统默认的方式打开。
public struct OpenPlan: Equatable, Sendable {
    public enum PathKind: Sendable {
        case file
        case folder
    }

    public struct Target: Equatable, Sendable {
        public enum Kind: Sendable {
            case link
            case file
            case folder
        }

        /// 交给应用的网址。用终端打开文件时是文件所在的文件夹。
        public var url: URL
        /// 条目里这一项是什么。
        public var kind: Kind
        /// 用哪个应用打开，nil 时用系统默认的方式。
        public var appBundleID: String?

        public init(url: URL, kind: Kind, appBundleID: String?) {
            self.url = url
            self.kind = kind
            self.appBundleID = appBundleID
        }
    }

    /// 还在的文件和链接，按条目里的顺序。用终端打开同一个文件夹里的几个文件时只打开一次。
    public var targets: [Target]
    /// 已经不在原来地方的文件个数。
    public var missing: Int
    /// 文件和文件夹实际用的应用：设置里选的，没装时是系统默认的方式。
    public var fileApp: OpenApp
    public var folderApp: OpenApp

    /// 文本和图片没有可打开的东西，网址读不出来的链接也没有，都返回 nil。
    ///
    /// - Parameters:
    ///   - text: 条目的完整文字：链接是网址，文件是以换行分隔的路径（`ClipContent.text`）。
    ///   - fileApp: 打开文件用的应用；`folderApp` 是打开文件夹的。右键菜单「打开方式」里选的应用两个都传它。
    ///   - isInstalled: 这个 bundle id 的应用装了没有。
    ///   - pathKind: 路径现在是文件还是文件夹，不在了是 nil。
    public static func make(
        kind: ClipKind,
        text: String?,
        fileApp: OpenApp,
        folderApp: OpenApp,
        isInstalled: (String) -> Bool,
        pathKind: (String) -> PathKind?
    ) -> OpenPlan? {
        let fileApp = fileApp.isAvailable(isInstalled: isInstalled) ? fileApp : .systemDefault
        let folderApp = folderApp.isAvailable(isInstalled: isInstalled) ? folderApp : .systemDefault
        switch kind {
        case .link:
            let address = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address), url.scheme != nil else { return nil }
            let target = Target(url: url, kind: .link, appBundleID: nil)
            return OpenPlan(targets: [target], missing: 0, fileApp: fileApp, folderApp: folderApp)
        case .file:
            var targets: [Target] = []
            var missing = 0
            for path in (text ?? "").split(separator: "\n").map(String.init) {
                let url = URL(fileURLWithPath: path)
                let target: Target
                switch pathKind(path) {
                case .file:
                    let opened = fileApp.isTerminal ? url.deletingLastPathComponent() : url
                    target = Target(url: opened, kind: .file, appBundleID: fileApp.bundleID)
                case .folder:
                    target = Target(url: url, kind: .folder, appBundleID: folderApp.bundleID)
                case nil:
                    missing += 1
                    continue
                }
                let duplicate = targets.contains { $0.url.standardizedFileURL == target.url.standardizedFileURL && $0.appBundleID == target.appBundleID }
                if !duplicate { targets.append(target) }
            }
            return OpenPlan(targets: targets, missing: missing, fileApp: fileApp, folderApp: folderApp)
        case .text, .image:
            return nil
        }
    }

    /// 菜单项的文字。
    public var title: String {
        let kinds = Set(targets.map(\.kind))
        if kinds == [.link] { return "在浏览器中打开" }
        let apps = Set(targets.map { $0.kind == .folder ? folderApp : fileApp })
        guard apps.count == 1, let app = apps.first else { return "打开" }
        if app == .systemDefault { return kinds == [.folder] ? "在访达中打开" : "打开" }
        return Self.title(using: app.title(forFolders: kinds == [.folder]))
    }

    /// 「用 Cursor 打开」「用终端打开」：英文名字两边留空格，中文不留。
    static func title(using name: String) -> String {
        name.first?.isASCII == true ? "用 \(name) 打开" : "用\(name)打开"
    }

    /// 打不开的原因，菜单里写在后面。有东西可以打开时为 nil。
    public var unavailableReason: String? {
        targets.isEmpty ? "文件已经不在了" : nil
    }

    /// 在文件系统里看路径现在是文件还是文件夹。应用、.rtfd 这类文件包虽然是文件夹，在访达里是一个文件，
    /// 双击用对应的应用打开，所以算文件，不交给编辑器。
    public static func pathKind(atPath path: String) -> PathKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return .file }
        let isPackage = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        return isPackage ? .file : .folder
    }
}
