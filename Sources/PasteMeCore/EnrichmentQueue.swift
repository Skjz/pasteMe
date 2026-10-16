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

/// 在条目保存之后补充附加信息，目前是图片中的文字（#5）。
///
/// 一次只处理一个条目：在主线程读出图片，后台识别，再回到主线程写库（`ClipStore` 只在主线程使用，ADR 0003）。
/// 新复制的条目排在最前面；`backfill()` 补做的旧条目排在后面，每条之间停一下，避免启动后 CPU 一直满载。
@MainActor
public final class EnrichmentQueue {
    /// 一个条目处理完、结果已写入数据库后调用。
    public var onEnriched: (Int64) -> Void = { _ in }

    private let store: ClipStore
    private let recognizer: any TextRecognizing
    private let backfillPause: Duration
    private var pending: [(id: Int64, isBackfill: Bool)] = []
    private var worker: Task<Void, Never>?

    /// - Parameter backfillPause: 补做旧条目时，每条之间停多久。
    public init(store: ClipStore, recognizer: any TextRecognizing, backfillPause: Duration = .milliseconds(500)) {
        self.store = store
        self.recognizer = recognizer
        self.backfillPause = backfillPause
    }

    /// 处理刚记录的条目。不是图片或已经处理过的条目会被跳过。
    public func enqueue(_ id: Int64) {
        pending.removeAll { $0.id == id }
        pending.insert((id, false), at: 0)
        startIfNeeded()
    }

    /// 补做所有还没处理过的旧条目。
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
        let input: TextRecognitionInput?
        do {
            input = try store.textRecognitionInput(id: id)
        } catch {
            NSLog("PasteMe: 读取图片失败：\(error)")
            return
        }
        guard let input else { return }
        let text = await recognizer.recognizeText(in: input)
        do {
            // 识别期间条目被删除时，这里不会更新任何一行。
            try store.setRecognizedText(text, id: id)
            onEnriched(id)
        } catch {
            NSLog("PasteMe: 保存识别出的文字失败：\(error)")
        }
    }
}
