import Foundation
import Testing
@testable import PasteMeCore

/// ⌘O 和右键菜单「打开方式」打开条目（#51）：每个网址用哪个应用打开，菜单里怎么写。
@Suite struct OpeningTests {
    static let vscode = OpenApp.visualStudioCode.bundleID!
    static let cursor = OpenApp.cursor.bundleID!
    static let ghostty = OpenApp.ghostty.bundleID!
    static let terminal = OpenApp.terminal.bundleID!
    static let everything = Set(OpenApp.allCases.compactMap(\.bundleID))

    /// 假的文件系统：文件名以 `f` 开头的是文件，以 `d` 开头的是文件夹，其他的都不在了。
    private func pathKind(_ path: String) -> OpenPlan.PathKind? {
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("f") { return .file }
        if name.hasPrefix("d") { return .folder }
        return nil
    }

    private func plan(
        _ kind: ClipKind, _ text: String?,
        files: OpenApp = .systemDefault, folders: OpenApp = .systemDefault, installed: Set<String> = everything
    ) -> OpenPlan? {
        OpenPlan.make(kind: kind, text: text, fileApp: files, folderApp: folders, isInstalled: installed.contains, pathKind: pathKind)
    }

    @Test func linksOpenInTheDefaultBrowser() throws {
        let plan = try #require(plan(.link, " https://example.com/a?b=1\n", files: .cursor, folders: .ghostty))
        #expect(plan.targets == [.init(url: URL(string: "https://example.com/a?b=1")!, kind: .link, appBundleID: nil)])
        #expect(plan.missing == 0)
        #expect(plan.title == "在浏览器中打开")
    }

    @Test func textImagesAndBrokenLinksHaveNothingToOpen() {
        #expect(plan(.text, "/w/fa.txt") == nil)
        #expect(plan(.image, nil) == nil)
        #expect(plan(.link, "") == nil)
        #expect(plan(.link, "not a url") == nil)
    }

    @Test func filesAndFoldersOpenTheSystemWayByDefault() throws {
        let file = try #require(plan(.file, "/w/fa.txt"))
        #expect(file.targets == [.init(url: URL(fileURLWithPath: "/w/fa.txt"), kind: .file, appBundleID: nil)])
        #expect(file.title == "打开")

        let folder = try #require(plan(.file, "/w/dproject"))
        #expect(folder.targets.map(\.appBundleID) == [nil])
        #expect(folder.title == "在访达中打开")
    }

    @Test func eachKindUsesItsOwnSetting() throws {
        let folder = try #require(plan(.file, "/w/dproject", files: .ghostty, folders: .visualStudioCode))
        #expect(folder.targets.map(\.appBundleID) == [Self.vscode])
        #expect(folder.title == "用 Visual Studio Code 打开")

        let file = try #require(plan(.file, "/w/fa.swift", files: .cursor, folders: .visualStudioCode))
        #expect(file.targets.map(\.appBundleID) == [Self.cursor])
        #expect(file.title == "用 Cursor 打开")

        let both = try #require(plan(.file, "/w/fa.txt\n/w/dproject\n/w/fb.png", folders: .visualStudioCode))
        #expect(both.targets.map(\.url.path) == ["/w/fa.txt", "/w/dproject", "/w/fb.png"])
        #expect(both.targets.map(\.appBundleID) == [nil, Self.vscode, nil])
        #expect(both.title == "打开")
    }

    @Test func terminalsOpenTheFolderAFileIsIn() throws {
        // 不把文件交给终端：shell 脚本会被直接执行。同一个文件夹里的几个文件只开一次。
        let plan = try #require(plan(.file, "/w/frun.sh\n/w/fnotes.txt\n/w/dsrc", files: .ghostty, folders: .ghostty))
        #expect(plan.targets.map(\.url.path) == ["/w", "/w/dsrc"])
        #expect(plan.targets.map(\.appBundleID) == [Self.ghostty, Self.ghostty])
        #expect(plan.title == "用 Ghostty 打开")

        let folder = try #require(self.plan(.file, "/w/dsrc", folders: .terminal))
        #expect(folder.targets.map(\.url.path) == ["/w/dsrc"])
        #expect(folder.title == "用终端打开")
    }

    @Test func aRemovedAppFallsBackToTheSystemWay() throws {
        let plan = try #require(plan(.file, "/w/dproject\n/w/fa.txt", files: .otty, folders: .cursor, installed: [Self.vscode]))
        #expect(plan.targets.map(\.appBundleID) == [nil, nil])
        #expect(plan.folderApp == .systemDefault && plan.fileApp == .systemDefault)
        #expect(plan.targets.map(\.url.path) == ["/w/dproject", "/w/fa.txt"])
    }

    @Test func missingFilesAreCountedAndSkipped() throws {
        let some = try #require(plan(.file, "/w/fa.txt\n/w/gone\n/w/dproject"))
        #expect(some.targets.map(\.url.path) == ["/w/fa.txt", "/w/dproject"])
        #expect(some.missing == 1)
        #expect(some.unavailableReason == nil)

        let none = try #require(plan(.file, "/w/gone\n/w/also-gone"))
        #expect(none.targets.isEmpty)
        #expect(none.missing == 2)
        #expect(none.unavailableReason == "文件已经不在了")
    }

    @Test func packagesCountAsFiles() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("project")
        let app = directory.appendingPathComponent("Tool.app")
        let file = directory.appendingPathComponent("a.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        try Data("a".utf8).write(to: file)

        #expect(OpenPlan.pathKind(atPath: folder.path) == .folder)
        #expect(OpenPlan.pathKind(atPath: app.path) == .file)
        #expect(OpenPlan.pathKind(atPath: file.path) == .file)
        #expect(OpenPlan.pathKind(atPath: directory.appendingPathComponent("gone").path) == nil)
    }

    @Test func onlyInstalledAppsCanBeChosen() {
        let installed: Set<String> = [Self.vscode, Self.terminal]
        #expect(OpenApp.systemDefault.isAvailable(isInstalled: installed.contains))
        #expect(OpenApp.visualStudioCode.isAvailable(isInstalled: installed.contains))
        #expect(OpenApp.terminal.isAvailable(isInstalled: installed.contains))
        #expect(!OpenApp.cursor.isAvailable(isInstalled: installed.contains))
        #expect(!OpenApp.otty.isAvailable(isInstalled: installed.contains))
    }

    @Test func theSystemWayIsNamedByWhatIsOpened() {
        #expect(OpenApp.systemDefault.title(forFolders: true) == "访达")
        #expect(OpenApp.systemDefault.title(forFolders: false) == "默认的应用")
        #expect(OpenApp.allCases.filter(\.isTerminal) == [.terminal, .iTerm, .ghostty, .otty])
    }
}
