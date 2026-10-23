import CryptoKit
import Foundation

/// 要计算哈希值的内容（#37）：文本和链接按 UTF-8 编码后的字节算，hex、Base64 等子类型也不解码；文件按文件内容算。
public enum HashInput: Sendable, Equatable {
    case text(String)
    case files([URL])

    /// 文件条目算不了哈希值的原因，菜单里写在后面。都能算时为 nil。
    public static func unavailableReason(forFiles paths: [String]) -> String? {
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return "文件已经不在了" }
            if isDirectory.boolValue { return "不能计算文件夹" }
        }
        return nil
    }

    /// 文件的总大小，用来判断要不要提示「正在计算」。文本为 0。
    public var fileSize: Int {
        guard case .files(let urls) = self else { return 0 }
        return urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}

/// 计算哈希值的算法（#37、#49），结果是小写十六进制。菜单按这里的顺序列出，按摘要从短到长。
public enum HashAlgorithm: String, CaseIterable, Sendable {
    case md5
    case sha1
    case sha256

    public var title: String {
        switch self {
        case .md5: "MD5"
        case .sha1: "SHA-1"
        case .sha256: "SHA-256"
        }
    }

    /// 计算结果，记成一条新的文本条目：文本和单个文件是一个哈希值；几个文件时每行一个 `<哈希值>  <路径>`，
    /// 和 `shasum`、`md5sum` 的输出一样。读文件可能要好一会儿，在后台线程调用。
    public func digest(of input: HashInput) throws -> String {
        switch input {
        case .text(let text):
            return hex(of: Data(text.utf8))
        case .files(let urls) where urls.count == 1:
            return try hex(ofFileAt: urls[0])
        case .files(let urls):
            return try urls.map { "\(try hex(ofFileAt: $0))  \($0.path)" }.joined(separator: "\n")
        }
    }

    public func hex(of data: Data) -> String {
        switch self {
        case .md5: Self.hex(Insecure.MD5.hash(data: data))
        case .sha1: Self.hex(Insecure.SHA1.hash(data: data))
        case .sha256: Self.hex(SHA256.hash(data: data))
        }
    }

    /// 每次读 1 MB，几个 GB 的文件也不用整个读进内存。
    public func hex(ofFileAt url: URL) throws -> String {
        switch self {
        case .md5: try Self.hash(fileAt: url, with: Insecure.MD5())
        case .sha1: try Self.hash(fileAt: url, with: Insecure.SHA1())
        case .sha256: try Self.hash(fileAt: url, with: SHA256())
        }
    }

    private static func hash<H: HashFunction>(fileAt url: URL, with function: H) throws -> String {
        var function = function
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            function.update(data: chunk)
        }
        return hex(function.finalize())
    }

    private static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
