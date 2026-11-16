import AppKit
import PasteMeCore

/// 调用系统的隔空投送窗口发送条目，并在发送完成、失败或取消后删掉临时文件（#68）。
@MainActor
final class AirDropController {
    private let files: AirDropFiles?
    private let toast: Toast
    private var sessions: [UUID: Session] = [:]

    init(files: AirDropFiles?, toast: Toast) {
        self.files = files
        self.toast = toast
    }

    /// 系统现在能不能用隔空投送发送这类条目。菜单打开时用来决定「隔空投送…」是不是灰的，不写临时文件。
    ///
    /// `NSSharingService.canPerform(withItems:)` 会检查本地文件 URL 是否真的存在于磁盘上：传不存在的路径会返回 false。
    /// 文本和图片在真正发送时会写成临时文件，这里用当前可执行文件作为已存在的本地文件探针来询问系统隔空投送服务是否可用。
    static func canSend(kind: ClipKind, urls: [URL]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        let probeItems: [Any] = switch kind {
        case .link, .file:
            urls
        case .text, .image:
            [existingLocalFileProbe]
        }
        guard !probeItems.isEmpty else { return false }
        return service.canPerform(withItems: probeItems)
    }

    private static let existingLocalFileProbe: URL = Bundle.main.executableURL
        ?? URL(fileURLWithPath: CommandLine.arguments[0])

    /// 写出需要的临时文件并弹出系统的隔空投送窗口。返回是否成功拉起窗口。
    @discardableResult
    func send(_ plan: AirDropPlan) -> Bool {
        guard plan.unavailableReason == nil, !plan.items.isEmpty else { return false }
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            toast.show("当前无法使用隔空投送", symbol: "exclamationmark.triangle")
            return false
        }

        let directory = files ?? AirDropFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PasteMeAirDrop", isDirectory: true))
        let prepared: AirDropFiles.Prepared
        do {
            prepared = try directory.prepare(plan.items)
        } catch {
            NSLog("PasteMe: 准备隔空投送临时文件失败：\(error)")
            toast.show("无法创建临时文件", symbol: "exclamationmark.triangle")
            return false
        }

        guard service.canPerform(withItems: prepared.urls) else {
            prepared.cleanUp()
            toast.show("当前无法使用隔空投送", symbol: "exclamationmark.triangle")
            return false
        }

        let id = UUID()
        let session = Session(service: service, prepared: prepared) { [weak self] in
            self?.sessions[id] = nil
        }
        sessions[id] = session
        // PasteMe 平时不激活，激活一下再弹出隔空投送窗口，免得窗口落在前台应用后面。
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: prepared.urls)
        return true
    }

    /// 持有正在进行的 `NSSharingService` 和它的代理，直到收到完成或失败（含用户取消）回调。
    @MainActor
    private final class Session: NSObject, NSSharingServiceDelegate {
        let service: NSSharingService
        let prepared: AirDropFiles.Prepared
        let onFinish: () -> Void
        private var finished = false

        init(service: NSSharingService, prepared: AirDropFiles.Prepared, onFinish: @escaping () -> Void) {
            self.service = service
            self.prepared = prepared
            self.onFinish = onFinish
            super.init()
            service.delegate = self
        }

        private func finish() {
            guard !finished else { return }
            finished = true
            prepared.cleanUp()
            onFinish()
        }

        nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            MainActor.assumeIsolated { finish() }
        }

        nonisolated func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
            MainActor.assumeIsolated { finish() }
        }
    }
}
