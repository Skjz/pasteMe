import Foundation

/// 要识别文字的图片。
public enum TextRecognitionInput: Sendable, Equatable {
    /// 复制的图片本身（PNG）。
    case imageData(Data)
    /// 复制的图片文件。文件已经不在时识别 `fallback`（复制时保存的缩略图）。
    case imageFile(URL, fallback: Data)
}

/// 识别图片里的文字。
public protocol TextRecognizing: Sendable {
    /// 返回识别出的文字，每行一段，用换行连接。没有文字或识别失败时返回空字符串。
    /// 在后台执行，不占用调用方所在的线程。
    func recognizeText(in input: TextRecognitionInput) async -> String
}

/// 一种附加信息：在主线程从条目读出要处理的内容，在后台算出结果，再回到主线程写库
/// （`ClipStore` 只在主线程使用，ADR 0003）。
public protocol Enricher: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    /// 条目不需要这种附加信息、或者已经有了时返回 nil。
    @MainActor func input(for id: Int64, in store: ClipStore) throws -> Input?
    /// 在后台执行，不占用主线程。
    func compute(_ input: Input) async -> Output
    @MainActor func save(_ output: Output, for id: Int64, in store: ClipStore) throws
}

/// 图片中的文字（#5）。
public struct TextRecognitionEnricher: Enricher {
    let recognizer: any TextRecognizing

    public init(recognizer: any TextRecognizing) {
        self.recognizer = recognizer
    }

    public func input(for id: Int64, in store: ClipStore) throws -> TextRecognitionInput? {
        try store.textRecognitionInput(id: id)
    }

    public func compute(_ input: TextRecognitionInput) async -> String {
        await recognizer.recognizeText(in: input)
    }

    public func save(_ text: String, for id: Int64, in store: ClipStore) throws {
        try store.setRecognizedText(text, id: id)
    }
}

/// 链接的网页标题、预览图和网站图标（#11）。按设置（`mode`，每次都重新读）和 `LinkPreviewPolicy` 决定请求哪个网址：
/// 关闭时、本机和内网地址不请求，这两种情况都不做标记，打开后再复制一次就会获取；「只取网站图标」和看起来像
/// 一次性的链接只请求网站首页。获取失败时存下 `LinkPreview.failed`，以后不再重试。
public struct LinkPreviewEnricher: Enricher {
    let fetcher: any LinkPreviewFetching
    let mode: @MainActor @Sendable () -> LinkPreviewMode

    public init(fetcher: any LinkPreviewFetching, mode: @escaping @MainActor @Sendable () -> LinkPreviewMode) {
        self.fetcher = fetcher
        self.mode = mode
    }

    public func input(for id: Int64, in store: ClipStore) throws -> LinkPreviewRequest? {
        guard let url = try store.linkPreviewURL(id: id) else { return nil }
        return LinkPreviewPolicy.request(for: url, mode: mode())
    }

    public func compute(_ request: LinkPreviewRequest) async -> LinkPreview {
        await fetcher.fetchPreview(request) ?? .failed
    }

    public func save(_ preview: LinkPreview, for id: Int64, in store: ClipStore) throws {
        try store.setLinkPreview(preview, id: id)
    }
}

/// 在条目保存之后补充附加信息：图片中的文字（#5）、链接预览（#11）。
///
/// 一次只处理一个条目，每种附加信息依次处理（`Enricher`）。
/// 新复制的条目排在最前面；`backfill()` 补做的旧条目排在后面，每条之间停一下，避免启动后 CPU 一直满载。
@MainActor
public final class EnrichmentQueue {
    /// 一个条目处理完、结果已写入数据库后调用。
    public var onEnriched: (Int64) -> Void = { _ in }

    private let store: ClipStore
    private let enrichers: [any Enricher]
    private let backfillPause: Duration
    private var pending: [(id: Int64, isBackfill: Bool)] = []
    private var worker: Task<Void, Never>?

    /// - Parameter backfillPause: 补做旧条目时，每条之间停多久。
    public init(store: ClipStore, enrichers: [any Enricher], backfillPause: Duration = .milliseconds(500)) {
        self.store = store
        self.enrichers = enrichers
        self.backfillPause = backfillPause
    }

    /// 只识别图片中的文字。
    public convenience init(store: ClipStore, recognizer: any TextRecognizing, backfillPause: Duration = .milliseconds(500)) {
        self.init(store: store, enrichers: [TextRecognitionEnricher(recognizer: recognizer)], backfillPause: backfillPause)
    }

    /// 处理刚记录的条目。不需要附加信息或已经处理过的条目会被跳过。
    public func enqueue(_ id: Int64) {
        pending.removeAll { $0.id == id }
        pending.insert((id, false), at: 0)
        startIfNeeded()
    }

    /// 补做所有还没识别文字的旧图片。链接预览不补做：以前复制的链接不会因为打开了开关就一下子发出很多请求。
    public func backfill() {
        do {
            let queued = Set(pending.map(\.id))
            pending += try store.idsPendingTextRecognition().filter { !queued.contains($0) }.map { ($0, true) }
        } catch {
            NSLog("PasteMe: 读取待识别的图片失败：\(error)")
        }
        startIfNeeded()
    }

    /// 等队列里的条目都处理完。测试用。
    public func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func startIfNeeded() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if next.isBackfill {
                try? await Task.sleep(for: backfillPause)
            }
            await process(next.id)
        }
        worker = nil
    }

    private func process(_ id: Int64) async {
        for enricher in enrichers {
            await run(enricher, for: id)
        }
    }

    private func run<E: Enricher>(_ enricher: E, for id: Int64) async {
        let input: E.Input?
        do {
            input = try enricher.input(for: id, in: store)
        } catch {
            NSLog("PasteMe: 读取条目失败：\(error)")
            return
        }
        guard let input else { return }
        let output = await enricher.compute(input)
        do {
            // 处理期间条目被删除时，这里不会更新任何一行。
            try enricher.save(output, for: id, in: store)
            onEnriched(id)
        } catch {
            NSLog("PasteMe: 保存附加信息失败：\(error)")
        }
    }
}
