import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 文件卡片上写的文件信息：是文件、文件夹还是应用这类文件包，多大，文件夹里有几项，图片多少像素。
/// 要读文件系统，所以在后台读（`read(atPath:)`），卡片上由 `FileFactsCache` 缓存。
public struct FileFacts: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case file
        case folder
        /// 应用、.rtfd 这类文件包：实际是文件夹，在访达里是一个文件。
        case package
    }

    public struct PixelSize: Sendable, Equatable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    /// 文件已经不在原来的地方时为 nil。
    public var kind: Kind?
    /// 文件的字节数。文件夹和文件包为 nil。
    public var byteCount: Int64?
    /// 文件夹里不隐藏的项数，和访达里看到的一样。
    public var itemCount: Int?
    /// 图片的宽和高（像素），竖着拍的照片按转正以后算。
    public var pixelSize: PixelSize?

    public static let missing = FileFacts(kind: nil)

    public init(kind: Kind?, byteCount: Int64? = nil, itemCount: Int? = nil, pixelSize: PixelSize? = nil) {
        self.kind = kind
        self.byteCount = byteCount
        self.itemCount = itemCount
        self.pixelSize = pixelSize
    }

    /// 读路径现在的样子。替身（符号链接，例如 /Applications/Safari.app）按它指向的东西算。
    /// 文件夹要列出里面的东西、网络磁盘可能很慢，不要在主线程调用。
    public static func read(atPath path: String) -> FileFacts {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        if isDirectory.boolValue {
            if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
                return FileFacts(kind: .package)
            }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            return FileFacts(kind: .folder, itemCount: names.filter { !$0.hasPrefix(".") }.count)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileFacts(
            kind: .file,
            byteCount: (attributes?[.size] as? NSNumber)?.int64Value,
            pixelSize: pixelSize(ofImageAt: url)
        )
    }

    /// 只读图片文件头里的尺寸。PDF 也能用 ImageIO 打开，但它的「像素」没有意义，不算。
    static func pixelSize(ofImageAt url: URL) -> PixelSize? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // 方向 5…8 是转了 90 度存的照片。
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? PixelSize(width: height, height: width) : PixelSize(width: width, height: height)
    }
}
