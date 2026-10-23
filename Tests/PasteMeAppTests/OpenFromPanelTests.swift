import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 在面板里按 ⌘O 打开链接、文件和文件夹（#51）。文件系统和装了哪些应用由测试替换。
@MainActor
@Suite final class OpenFromPanelTests {
    let store: ClipStore
    let model: HistoryModel
    var opened: [OpenPlan] = []
    var notices: [String] = []

    init() throws {
        store = try ClipStore(path: ":memory:")
        model = HistoryModel(store: store) { Date(timeIntervalSince1970: 100) }
        model.onOpen = { [unowned self] in opened.append($0) }
        model.onNotice = { [unowned self] message, _ in notices.append(message) }
        model.isInstalled = { [OpenApp.visualStudioCode.bundleID, OpenApp.ghostty.bundleID].contains($0) }
        // `/f` 开头的是文件，`/d` 开头的是文件夹，其他的都不在了。
        model.pathKind = { path in
            path.hasPrefix("/f") ? .file : path.hasPrefix("/d") ? .folder : nil
        }
    }

    private func select(_ content: ClipContent) throws {
        let id = try store.insert(content, source: nil, at: Date(timeIntervalSince1970: 1))
        model.didShow()
        model.selectedID = id
    }

    @Test func aLinkOpensItsFullAddress() throws {
        // 比卡片上的 `preview`（前 2000 个字符）长。
        let address = "https://example.com/" + String(repeating: "a", count: 3000)
        try select(ClipContent(kind: .link, text: address))
        model.open()
        #expect(opened.map(\.targets) == [[.init(url: URL(string: address)!, kind: .link, appBundleID: nil)]])
        #expect(notices.isEmpty)
    }

    @Test func filesAndFoldersFollowTheirSettings() throws {
        model.folderApp = .visualStudioCode
        model.fileApp = .ghostty
        try select(ClipContent(kind: .file, text: "/dproject\n/fa.txt"))
        model.open()
        #expect(opened.first?.targets.map(\.appBundleID) == [OpenApp.visualStudioCode.bundleID, OpenApp.ghostty.bundleID])
    }

    @Test func openWithUsesTheChosenAppForEverything() throws {
        model.folderApp = .visualStudioCode
        try select(ClipContent(kind: .file, text: "/dproject\n/fa.txt"))
        let item = try #require(model.selectedItem)
        // 「打开方式」只列出装了的应用。
        #expect(model.openApps(for: item) == [.systemDefault, .visualStudioCode, .ghostty])

        model.open(item, using: .ghostty)
        // 终端打开文件所在的文件夹：`/fa.txt` 在根目录。
        #expect(opened.first?.targets.map(\.url.path) == ["/dproject", "/"])
        #expect(opened.first?.targets.map(\.appBundleID) == [OpenApp.ghostty.bundleID, OpenApp.ghostty.bundleID])
    }

    @Test func linksHaveNoOpenWithMenu() throws {
        try select(ClipContent(kind: .link, text: "https://example.com"))
        #expect(model.openApps(for: try #require(model.selectedItem)).isEmpty)
    }

    @Test func textAndImagesDoNothing() throws {
        try select(ClipContent(kind: .text, text: "https://example.com"))
        model.open()
        #expect(opened.isEmpty && notices.isEmpty)
        #expect(model.openPlan(for: try #require(model.selectedItem)) == nil)
    }

    @Test func missingFilesAreReported() throws {
        try select(ClipContent(kind: .file, text: "/gone"))
        model.open()
        // 都不在了：不打开，面板不收起（`onOpen` 没有调用），只提示。
        #expect(opened.isEmpty)
        #expect(notices == ["文件已经不在了"])

        notices = []
        try select(ClipContent(kind: .file, text: "/fa.txt\n/gone\n/also-gone"))
        model.open()
        #expect(opened.first?.targets.map(\.url.path) == ["/fa.txt"])
        #expect(notices == ["有 2 个文件已经不在了"])
    }
}
