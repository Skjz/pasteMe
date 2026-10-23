import AppKit
import Foundation
import Testing
@testable import PasteMeApp
import PasteMeCore

/// 文件卡片：标题和细线中间写什么、底部写哪个位置，文件信息在后台读、读到后一起写回，图标预先画成图。
@MainActor
@Suite struct FileCardTests {
    private func text(_ paths: [String], _ facts: [String: FileFacts] = [:]) -> FileCardText {
        FileCardText(paths: paths, facts: { facts[$0] })
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @Test func aFileShowsItsNameTypeAndSize() {
        // 还没读到文件信息时只写类型，读到后加上大小。
        #expect(text(["/w/季度报告.pdf"]) == FileCardText(headline: "季度报告", caption: "PDF"))
        #expect(text(["/w/季度报告.pdf"], ["/w/季度报告.pdf": FileFacts(kind: .file, byteCount: 40_000)])
            == FileCardText(headline: "季度报告", caption: "PDF · \(size(40_000))"))
        #expect(text(["/w/海岸.heic"], ["/w/海岸.heic": FileFacts(kind: .file, byteCount: 9, pixelSize: .init(width: 4096, height: 2160))])
            == FileCardText(headline: "海岸", caption: "HEIC · 4096 × 2160"))
    }

    @Test func namesKeepWhatIsNotAKnownExtension() {
        #expect(text(["/w/Makefile"]) == FileCardText(headline: "Makefile", caption: "文件"))
        #expect(text(["/w/.gitignore"]).headline == ".gitignore")
        // 「v1.2」的「2」不是扩展名：读到之前也写全名，读到是文件夹以后也一样。
        #expect(text(["/w/v1.2"]).headline == "v1.2")
        #expect(text(["/w/v1.2"], ["/w/v1.2": FileFacts(kind: .folder, itemCount: 4)])
            == FileCardText(headline: "v1.2", caption: "文件夹 · 4 项"))
    }

    @Test func foldersAppsAndMissingFiles() {
        #expect(text(["/w/pasteMe"], ["/w/pasteMe": FileFacts(kind: .folder, itemCount: 14)])
            == FileCardText(headline: "pasteMe", caption: "文件夹 · 14 项"))
        #expect(text(["/Applications/Safari.app"], ["/Applications/Safari.app": FileFacts(kind: .package)])
            == FileCardText(headline: "Safari", caption: "应用程序"))
        #expect(text(["/w/旧版报价单.xlsx"], ["/w/旧版报价单.xlsx": .missing])
            == FileCardText(headline: "旧版报价单", caption: "已经不在原处"))
    }

    @Test func severalFilesAreCountedByWhatTheyAre() {
        let paths = ["/w/a.pdf", "/w/b.heic", "/w/c.pdf"]
        #expect(text(paths) == FileCardText(headline: "3 个文件", caption: "PDF · HEIC"))
        let folders: [String: FileFacts] = ["/w/src": FileFacts(kind: .folder), "/w/docs": FileFacts(kind: .folder)]
        #expect(text(["/w/src", "/w/docs"], folders) == FileCardText(headline: "2 个文件夹", caption: "文件夹"))
        #expect(text(["/w/src", "/w/a.pdf"], folders) == FileCardText(headline: "2 项", caption: "文件夹 · PDF"))
        #expect(text(["/w/a.pdf", "/w/b.png", "/w/c.md", "/w/d.zip"]).caption == "PDF · PNG · MD …")
    }

    @Test func theLocationIsTheFolderTheFilesShare() {
        let home = NSHomeDirectory()
        #expect(FileCardText.location(of: ["\(home)/fromGit/pasteMe"]) == "~/fromGit")
        #expect(FileCardText.location(of: ["\(home)/fromGit/pasteMe/Sources/PasteMeApp/A.swift"]) == "…/Sources/PasteMeApp")
        #expect(FileCardText.location(of: ["\(home)/文稿/a.pdf", "\(home)/文稿/项目/b.pdf"]) == "~/文稿")
        #expect(FileCardText.location(of: ["/Applications/Safari.app"]) == "/Applications")
        #expect(FileCardText.location(of: ["/Applications/Safari.app", "/Volumes/U盘/a.txt"]) == "/")
        #expect(FileCardText.location(of: []) == "")
    }

    // MARK: - 文件信息

    /// 测试用的文件系统：记下每次读了哪些路径，答案可以中途改。
    final class FakeFiles: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: FileFacts]
        private(set) var reads: [String] = []

        init(_ answers: [String: FileFacts]) {
            self.answers = answers
        }

        func set(_ path: String, _ facts: FileFacts) {
            lock.withLock { answers[path] = facts }
        }

        func read(_ path: String) -> FileFacts {
            lock.withLock {
                reads.append(path)
                return answers[path] ?? .missing
            }
        }

        var readCount: Int { lock.withLock { reads.count } }
    }

    /// `known` 变了几次：每变一次，读它的卡片都要重画。
    final class Changes: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        @MainActor init(of cache: FileFactsCache) {
            withObservationTracking { _ = cache.known } onChange: { [self] in lock.withLock { value += 1 } }
        }

        var count: Int { lock.withLock { value } }
    }

    @Test func pathsRequestedTogetherAreReadAndWrittenBackTogether() async {
        let files = FakeFiles(["/w/a.pdf": FileFacts(kind: .file, byteCount: 1), "/w/src": FileFacts(kind: .folder, itemCount: 2)])
        let cache = FileFactsCache(read: files.read)

        // 画卡片时先返回 nil，同一个路径只请求一次。
        #expect(cache.facts(for: "/w/a.pdf") == nil)
        #expect(cache.facts(for: "/w/src") == nil)
        #expect(cache.facts(for: "/w/a.pdf") == nil)
        let changes = Changes(of: cache)
        await cache.reading?.value

        #expect(files.reads.sorted() == ["/w/a.pdf", "/w/src"])
        #expect(changes.count == 1)
        #expect(cache.facts(for: "/w/a.pdf") == FileFacts(kind: .file, byteCount: 1))
        #expect(cache.facts(for: "/w/src") == FileFacts(kind: .folder, itemCount: 2))
    }

    @Test func refreshingWritesBackOnlyWhatChanged() async {
        let files = FakeFiles(["/w/a.pdf": FileFacts(kind: .file, byteCount: 1)])
        let cache = FileFactsCache(read: files.read)
        _ = cache.facts(for: "/w/a.pdf")
        await cache.reading?.value

        // 没变：卡片不用重画。
        let unchanged = Changes(of: cache)
        cache.refresh()
        await cache.refreshing?.value
        #expect(files.readCount == 2)
        #expect(unchanged.count == 0)

        // 文件后来被删掉了：下次呼出面板后卡片跟着变。
        files.set("/w/a.pdf", .missing)
        let changed = Changes(of: cache)
        cache.refresh()
        await cache.refreshing?.value
        #expect(changed.count == 1)
        #expect(cache.facts(for: "/w/a.pdf") == .missing)
    }

    // MARK: - 图标

    @Test func plainFilesShareTheIconOfTheirType() {
        #expect(FileIconCache.iconKey(forPath: "/w/a.pdf", kind: nil) == .type("com.adobe.pdf"))
        #expect(FileIconCache.iconKey(forPath: "/w/a.pdf", kind: .file) == .type("com.adobe.pdf"))
        // 文件夹、应用和扩展名不认识的可能有自己的图标。
        #expect(FileIconCache.iconKey(forPath: "/w/v1.2", kind: nil) == .path("/w/v1.2"))
        #expect(FileIconCache.iconKey(forPath: "/w/Tool.app", kind: nil) == .path("/w/Tool.app"))
        #expect(FileIconCache.iconKey(forPath: "/w/archive.zip", kind: .folder) == .path("/w/archive.zip"))
        #expect(FileIconCache.iconKey(forPath: "/w/Notes.rtfd", kind: .package) == .path("/w/Notes.rtfd"))
    }

    /// 图片正中的像素。
    private func centerPixel(of image: NSImage) throws -> NSColor {
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        return try #require(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    /// 一张纯色的 PNG。
    private func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func postersAreDrawnOnceAtTheirSizeAndGrayWhenMissing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileCardTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = FileIconCache.IconKey.path(folder.path)

        let poster = FileIconCache.poster(for: key, size: 60, missing: false)
        #expect(poster.size == NSSize(width: 60 + FileIconCache.glow * 2, height: 60 + FileIconCache.glow * 2))
        #expect(FileIconCache.poster(for: key, size: 60, missing: false) === poster)
        // 图标按点画满中间：正中是文件夹不透明的蓝色。
        let blue = try centerPixel(of: poster)
        #expect(blue.alphaComponent > 0.95)
        #expect(blue.blueComponent - blue.redComponent > 0.2)

        let gray = try centerPixel(of: FileIconCache.poster(for: key, size: 60, missing: true))
        #expect(abs(gray.redComponent - gray.blueComponent) < 0.05)
        #expect(abs(gray.alphaComponent - 0.4) < 0.05)
    }

    @Test func thumbnailsBecomeASheetThatFitsTheBox() throws {
        let portrait = try png(width: 300, height: 400)
        let sheet = try #require(FileIconCache.sheet(for: 1, thumbnail: portrait))
        let margin = FileIconCache.sheetMargin * 2
        #expect(sheet.size == NSSize(width: 51 + margin, height: 68 + margin))
        #expect(FileIconCache.sheet(for: 1, thumbnail: portrait) === sheet)

        let slide = try png(width: 160, height: 90)
        #expect(FileIconCache.sheet(for: 2, thumbnail: slide)?.size == NSSize(width: 80 + margin, height: 45 + margin))
        #expect(FileIconCache.sheet(for: 3, thumbnail: Data([1, 2, 3])) == nil)
    }
}
