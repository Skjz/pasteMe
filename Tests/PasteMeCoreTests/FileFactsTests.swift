import Foundation
import Testing
@testable import PasteMeCore

/// 文件卡片上的文件信息：文件、文件夹、文件包怎么区分，大小、项数和像素从哪里读。
@Suite struct FileFactsTests {
    @Test func filesHaveTheirSize() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data(repeating: 1, count: 1234).write(to: file)

        #expect(FileFacts.read(atPath: file.path) == FileFacts(kind: .file, byteCount: 1234))
    }

    @Test func foldersCountWhatFinderShows() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["a.txt", "b.txt", ".DS_Store"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sub"), withIntermediateDirectories: false)

        #expect(FileFacts.read(atPath: directory.path) == FileFacts(kind: .folder, itemCount: 3))
    }

    @Test func packagesAndAliasesCountAsWhatTheyAre() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
        let folder = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        // 替身按它指向的东西算，例如 /Applications/Safari.app。
        let alias = directory.appendingPathComponent("Shortcut.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        let folderAlias = directory.appendingPathComponent("project link")
        try FileManager.default.createSymbolicLink(at: folderAlias, withDestinationURL: folder)

        #expect(FileFacts.read(atPath: app.path).kind == .package)
        #expect(FileFacts.read(atPath: alias.path).kind == .package)
        #expect(FileFacts.read(atPath: folderAlias.path) == FileFacts(kind: .folder, itemCount: 0))
    }

    @Test func missingFilesAreMissing() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(FileFacts.read(atPath: directory.appendingPathComponent("gone.pdf").path) == .missing)
        #expect(FileFacts.missing.kind == nil)
    }

    @Test func imagesHaveTheirPixelSize() throws {
        let directory = try ClipStoreTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try #require(ClipStoreTests.makePNG(width: 30, height: 20))
        let image = directory.appendingPathComponent("photo.png")
        try png.write(to: image)
        // 扩展名不是图片的文件即使能被 ImageIO 打开也不读像素。
        let renamed = directory.appendingPathComponent("photo.dat")
        try png.write(to: renamed)

        let facts = FileFacts.read(atPath: image.path)
        #expect(facts.pixelSize == FileFacts.PixelSize(width: 30, height: 20))
        #expect(facts.byteCount == Int64(png.count))
        #expect(FileFacts.read(atPath: renamed.path).pixelSize == nil)
    }
}
