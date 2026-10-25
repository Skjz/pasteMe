import AppKit
import Observation
import PasteMeCore

/// 检查更新、安装并重新打开（ADR 0010）。
///
/// 自动检查（`checkIfDue`）在启动后和每小时调用一次，距上次检查满一天才真的去查；查到新版本时不弹窗打断用户，
/// 只显示一次 Toast，并在菜单栏菜单最前面放「更新到 PasteMe x.y.z…」。手动检查（菜单栏菜单、设置的「关于」页）
/// 直接弹窗，已经是最新时也说一声。用户点了安装才下载：下载、验证签名、换掉应用，然后退出、由一个小脚本等进程
/// 结束后重新打开新的应用。
@MainActor
@Observable
final class Updater {
    /// 查到的、还没安装也没跳过的新版本。菜单栏菜单据此显示「更新到…」。
    private(set) var available: UpdateRelease?
    private(set) var isChecking = false
    private(set) var isInstalling = false
    /// 安装进行到哪一步，更新窗口（`UpdateProgressView`）据此显示进度。
    private(set) var step: InstallStep?
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var window: UpdateWindow?

    enum InstallStep: Equatable {
        /// 正在下载 DMG：已经读到的字节数、总大小（服务器没给时为 nil）。
        case downloading(received: Int64, total: Int64?)
        /// 下载完了，正在检查安装包里的应用（换不了应用、只把安装包交给用户时）。
        case checking
        /// 下载完了，正在验证、挂载、换应用。这一步不能取消。
        case installing
    }
    /// 正在进行的检查，测试等它结束。
    @ObservationIgnored private(set) var checking: Task<Void, Never>?

    @ObservationIgnored private let settings: Settings
    @ObservationIgnored private let client: UpdateClient
    /// 查最新的发布。测试替换它，不联网。
    @ObservationIgnored private let latest: @MainActor () async throws -> UpdateRelease?
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private let current: AppVersion?
    @ObservationIgnored private let variant: AppVariant
    @ObservationIgnored private let toast: Toast

    init(
        settings: Settings,
        toast: Toast,
        client: UpdateClient = UpdateClient(),
        installer: UpdateInstaller = UpdateInstaller(app: Bundle.main.bundleURL),
        current: AppVersion? = .current,
        variant: AppVariant = .current,
        latest: (@MainActor () async throws -> UpdateRelease?)? = nil
    ) {
        self.settings = settings
        self.toast = toast
        self.client = client
        self.latest = latest ?? { try await client.latest() }
        self.installer = installer
        self.current = current
        self.variant = variant
    }

    /// 自动检查：只有发布版、打开了自动检查、距上次满一天时才查。
    func checkIfDue() {
        guard variant == .release, settings.checksForUpdates, UpdateSchedule.isDue(lastCheck: settings.lastUpdateCheck) else { return }
        checking = Task { await check(manual: false) }
    }

    /// 用户点了「检查更新…」。
    func checkNow() {
        checking = Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard !isChecking, !isInstalling, let current else {
            if manual, current == nil { inform("没有版本号", "这个 PasteMe 不是打包出来的应用，查不了更新。") }
            return
        }
        isChecking = true
        defer { isChecking = false }
        let release: UpdateRelease?
        do {
            release = try await latest()
            settings.lastUpdateCheck = Date()
        } catch {
            NSLog("PasteMe: 检查更新失败：\(error)")
            if manual { inform("检查更新失败", "连不上 GitHub：\(error.localizedDescription)") }
            return
        }
        guard let release, release.isWorthOffering(current: current, skipped: settings.skippedUpdateVersion, manual: manual) else {
            available = nil
            if manual { inform("PasteMe \(current) 已经是最新版本", "") }
            return
        }
        // 没有签名的发布不放进菜单：自动检查不提示，手动检查只警告。
        guard release.canInstall else {
            available = nil
            if manual { warnUnsigned(release) }
            return
        }
        available = release
        if manual {
            offer(release)
        } else {
            toast.show("PasteMe \(release.version) 可以更新了", detail: "在菜单栏菜单里更新", symbol: "arrow.down.circle")
        }
    }

    /// 弹窗介绍新版本，问要不要安装。菜单栏菜单的「更新到…」也走这里。
    func offer(_ release: UpdateRelease) {
        guard release.canInstall else { return warnUnsigned(release) }
        let reason = installReason(release)
        let alert = NSAlert()
        alert.messageText = "PasteMe \(release.version) 可以更新了"
        var text = "你现在用的是 \(current.map(String.init(describing:)) ?? "开发版本")。"
        if let reason {
            text += "\(reason)，不能自动替换。PasteMe 会下载安装包、核对签名，放进「下载」文件夹并打开，把里面的 PasteMe 拖进「应用程序」就行。"
        } else {
            text += "更新后 PasteMe 会重新打开。之后要在「系统设置 → 隐私与安全性 → 辅助功能」里删掉旧的 PasteMe，再重新允许。"
        }
        alert.informativeText = text
        if !release.notes.isEmpty { alert.accessoryView = Self.notesView(release.notes) }
        alert.addButton(withTitle: reason == nil ? "安装并重新打开" : "下载安装包")
        alert.addButton(withTitle: "以后再说")
        alert.addButton(withTitle: "跳过这个版本")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installTask = Task { await install(release, replacing: reason == nil) }
        case .alertThirdButtonReturn:
            settings.skippedUpdateVersion = release.version.description
            available = nil
        default:
            break
        }
    }

    /// 发布里没有签名：可能不是发布者传的（拿到 GitHub 发布权限的人故意不传 `.sig`），所以不给下载页面，
    /// 免得用户手动装上、在「隐私与安全性」里点「仍要打开」绕过校验。只有手动检查会走到这里。
    private func warnUnsigned(_ release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "PasteMe \(release.version) 没有通过签名校验"
        alert.informativeText = "这次发布缺少发布者的签名，可能不是 PasteMe 的发布者传上去的。请不要下载安装它，等下一个版本，或者到 GitHub Issues 反馈。现在用的 PasteMe 不受影响。"
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "跳过这个版本")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            settings.skippedUpdateVersion = release.version.description
            available = nil
        }
    }

    /// 这台 Mac 上换不了应用的原因，能换时为 nil。这时只下载、验签，把安装包交给用户手动安装。
    private func installReason(_ release: UpdateRelease) -> String? {
        if variant != .release { return "开发版不自动更新" }
        return installer.unavailableReason
    }

    /// 下载并验签。`replacing` 时换掉应用、重新打开；否则检查过 DMG 里的应用后放进「下载」文件夹打开。
    ///
    /// 失败时都不给发布页：发布页上的文件没有一个是验过的，让用户去手动下载等于绕过签名。
    private func install(_ release: UpdateRelease, replacing: Bool) async {
        guard !isInstalling else { return }
        isInstalling = true
        step = .downloading(received: 0, total: nil)
        let window = UpdateWindow(updater: self, version: release.version)
        self.window = window
        window.show()
        defer {
            isInstalling = false
            step = nil
            installTask = nil
        }
        var verified = false
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteMe-update-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let dmg = try await client.download(release, into: directory) { received, total in
                Task { @MainActor [weak self] in self?.downloaded(received, of: total) }
            }
            verified = true
            guard replacing else {
                // 和自动替换一样，先看 DMG 里的应用对不对（bundle id、版本和 tag 一样、codesign），再交给用户。
                step = .checking
                let version = release.version
                try await Task.detached { try UpdateInstaller.inspect(dmg: dmg, expecting: version) }.value
                let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let kept = try VerifiedDMG.keep(dmg, in: downloads)
                window.close()
                NSWorkspace.shared.open(kept)
                return
            }
            step = .installing
            let installer = installer
            try await Task.detached { try installer.install(dmg: dmg, expecting: release.version) }.value
        } catch is CancellationError {
            window.close()
            return
        } catch UpdateError.badSignature {
            window.close()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "PasteMe \(release.version) 没有通过签名校验"
            alert.informativeText = "下载的安装包和发布者的签名对不上，没有安装。它可能被人换过，请不要手动下载安装这一版。现在用的 PasteMe 没有变。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        } catch UpdateError.unexpectedApp(let reason) {
            // 签名对、里面的应用不对：比如拿一个旧版本的签名包顶着新的 tag。签名只覆盖这一个文件，发布页上的别的文件没签过，所以也不给发布页。
            window.close()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "PasteMe \(release.version) 的安装包不对"
            alert.informativeText = "\(reason)，没有安装。请不要手动下载安装这一版。现在用的 PasteMe 没有变。"
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        } catch {
            // 网络、挂载、拷贝、替换出错。不给发布页：手动安装只能走「下载安装包」，它总是先验签、再查内容。
            window.close()
            NSLog("PasteMe: 更新失败：\(error)")
            inform(verified ? "没有装上 PasteMe \(release.version)" : "没有下载完 PasteMe \(release.version)",
                   "\(error)。现在用的 PasteMe 没有变，稍后再试一次。")
            return
        }
        relaunch()
    }

    /// 进度是从后台一条条送回主线程的，只往前走，晚到的旧进度不用。
    private func downloaded(_ received: Int64, of total: Int64?) {
        guard case .downloading(let shown, _) = step, received >= shown else { return }
        step = .downloading(received: received, total: total)
    }

    /// 更新窗口里点了取消或关掉了窗口。只有下载时能取消，开始换应用以后不行。
    func cancelInstall() {
        guard case .downloading = step else { return }
        installTask?.cancel()
    }

    /// 应用已经换成新的了：交给一个等这个进程结束的 shell 去打开它，然后退出。
    private func relaunch() {
        let script = "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), installer.app.path]
        do {
            try process.run()
        } catch {
            inform("PasteMe 已经更新", "请手动重新打开 PasteMe。")
        }
        NSApp.terminate(nil)
    }

    private func inform(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// 发布说明：按 Markdown 去掉标记、保留换行，太长时可以滚动。
    ///
    /// 链接去掉，只留文字：弹窗出现时还没有下载、没有验签，发布说明和 `.sig` 一样可能是别人传的，
    /// 文本视图里的链接一点就交给系统打开（`file://` 也行），用户会装上没验过的东西。
    static func notesView(_ notes: String) -> NSView {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let text = (try? NSMutableAttributedString(AttributedString(markdown: notes, options: options), including: \.appKit))
            ?? NSMutableAttributedString(string: notes)
        text.removeAttribute(.link, range: NSRange(location: 0, length: text.length))
        text.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor],
                           range: NSRange(location: 0, length: text.length))
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 380, height: 180)
        scroll.borderType = .bezelBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.textStorage?.setAttributedString(text)
        }
        return scroll
    }
}
