import Foundation
import ImageIO
import Vision

/// 用系统的 Vision 框架识别图片里的中英文文字，不需要联网。
public struct VisionTextRecognizer: TextRecognizing {
    public static let languages = ["zh-Hans", "zh-Hant", "en-US"]

    public init() {}

    public func recognizeText(in input: TextRecognitionInput) async -> String {
        await Task.detached(priority: .utility) {
            Self.recognize(input)
        }.value
    }

    private static func recognize(_ input: TextRecognitionInput) -> String {
        guard let (image, orientation) = cgImage(from: input) else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        do {
            try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
        } catch {
            return ""
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    /// 解码出的图片，以及照片 EXIF 里记录的方向（竖着拍的照片像素是横着存的）。
    private static func cgImage(from input: TextRecognitionInput) -> (CGImage, CGImagePropertyOrientation)? {
        let source: CGImageSource?
        switch input {
        case .imageData(let data):
            source = CGImageSourceCreateWithData(data as CFData, nil)
        case .imageFile(let url, let fallback):
            source = CGImageSourceCreateWithURL(url as CFURL, nil) ?? CGImageSourceCreateWithData(fallback as CFData, nil)
        }
        guard let source, CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return (image, orientation)
    }
}
