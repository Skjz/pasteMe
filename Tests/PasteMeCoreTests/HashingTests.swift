import Foundation
import Testing
@testable import PasteMeCore

/// 计算文本和文件的 MD5、SHA-256（#37）。期望值是本机 `md5`、`shasum -a 256` 算出的。
@Suite final class HashingTests {
    let directory: URL

    init() throws {
        directory = try ClipStoreTests.makeTempDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func knownValues() throws {
        #expect(try HashAlgorithm.md5.digest(of: .text("")) == "d41d8cd98f00b204e9800998ecf8427e")
        #expect(try HashAlgorithm.md5.digest(of: .text("hello")) == "5d41402abc4b2a76b9719d911017c592")
        #expect(try HashAlgorithm.sha256.digest(of: .text("")) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(try HashAlgorithm.sha256.digest(of: .text("hello")) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func textIsHashedAsUTF8AndNotDecoded() throws {
        #expect(try HashAlgorithm.md5.digest(of: .text("你好")) == "7eca689f0d3389d9dea66ae112e5cfd7")
        #expect(try HashAlgorithm.sha256.digest(of: .text("你好")) == "670d9743542cae3ea7ebe36af56bd53648b0a1126162e78d81a32934a711302e")
        // Base64 的「aGVsbG8=」是 hello，但算的是这几个字符本身。
        #expect(try HashAlgorithm.md5.digest(of: .text("aGVsbG8=")) != "5d41402abc4b2a76b9719d911017c592")
    }

    @Test func filesAreReadInChunks() throws {
        // 3 MB，比每次读的 1 MB 大。
        let big = try file("big.bin", Data(repeating: UInt8(ascii: "a"), count: 3_000_000))
        #expect(try HashAlgorithm.md5.digest(of: .files([big])) == "99ddc9a3a46ea62c95652bdf937a1fb8")
        let empty = try file("empty", Data())
        #expect(try HashAlgorithm.md5.digest(of: .files([empty])) == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test func severalFilesGiveOneLinePerFile() throws {
        let hello = try file("hello.txt", Data("hello".utf8))
        let empty = try file("empty.txt", Data())
        #expect(try HashAlgorithm.sha256.digest(of: .files([hello, empty])) == """
            2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824  \(hello.path)
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  \(empty.path)
            """)
    }

    @Test func missingFilesAndFoldersCannotBeHashed() throws {
        let present = try file("a.txt", Data("a".utf8))
        #expect(HashInput.unavailableReason(forFiles: [present.path]) == nil)
        #expect(HashInput.unavailableReason(forFiles: [present.path, directory.appendingPathComponent("gone").path]) == "文件已经不在了")
        #expect(HashInput.unavailableReason(forFiles: [directory.path]) == "不能计算文件夹")
        #expect(throws: (any Error).self) {
            try HashAlgorithm.md5.digest(of: .files([self.directory.appendingPathComponent("gone")]))
        }
    }
}
