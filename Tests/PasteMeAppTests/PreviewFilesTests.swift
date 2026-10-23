import Carbon.HIToolbox
import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 几个文件的条目，预览时可以换着看每一个文件。
@MainActor
@Suite final class PreviewFilesTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item() -> ClipItem {
        ClipItem(id: 1, kind: .file, preview: nil, textLength: 0, thumbnail: nil, sourceBundleID: nil, sourceName: nil, createdAt: Date())
    }

    @Test func previewStartsAtTheFirstFileThatIsStillThereAndWrapsAround() throws {
        let gone = directory.appendingPathComponent("gone.txt").path
        let a = directory.appendingPathComponent("a.txt")
        let b = directory.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let state = PreviewState()
        state.load(item(), content: ClipContent(kind: .file, text: [gone, a.path, b.path].joined(separator: "\n")))

        #expect(state.fileIndex == 1)
        #expect(state.currentFileURL?.lastPathComponent == "a.txt")
        state.showFile(at: 3)
        #expect(state.fileIndex == 0)
        state.showFile(at: -1)
        #expect(state.currentFileURL?.lastPathComponent == "b.txt")

        // 换了条目就回到第一个还在的文件。
        state.load(item(), content: ClipContent(kind: .file, text: [a.path, b.path].joined(separator: "\n")))
        #expect(state.fileIndex == 0)
    }

    @Test func optionArrowsSwitchFilesWhileThePreviewIsOpen() {
        let optionLeft = PanelKey(keyCode: kVK_LeftArrow, option: true, characters: "\u{F702}")
        let optionRight = PanelKey(keyCode: kVK_RightArrow, option: true, characters: "\u{F703}")
        var context = PanelContext(focus: .cards, queryIsEmpty: true, canUndoDelete: false)
        context.previewShown = true
        context.previewHasSeveralFiles = true
        #expect(PanelKeymap.action(for: optionLeft, in: context) == .run(.previewFile(by: -1)))
        #expect(PanelKeymap.action(for: optionRight, in: context) == .run(.previewFile(by: 1)))

        // 只有一个文件、或者没开预览时，⌥← ⌥→ 和 ← → 一样换卡片。
        context.previewHasSeveralFiles = false
        #expect(PanelKeymap.action(for: optionLeft, in: context) == .run(.moveSelection(by: -1)))

        // 搜索框里有文字时按词移动插入点。
        var searching = PanelContext(focus: .search, queryIsEmpty: false, canUndoDelete: false)
        searching.previewShown = true
        searching.previewHasSeveralFiles = true
        #expect(PanelKeymap.action(for: optionLeft, in: searching) == .passThrough)
    }
}
