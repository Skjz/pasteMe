import AppKit
import SwiftUI

/// 在鼠标所在屏幕的下方短暂显示一行提示，例如“已暂停记录”。不接收鼠标和键盘，不打断当前操作。
@MainActor
final class Toast {
    private let panel: NSPanel
    private var hideWork: DispatchWorkItem?

    /// 提示停留的时间，不含淡入淡出。
    private static let duration = 1.4

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
    }

    /// - Parameters:
    ///   - symbol: SF Symbol 的名字。
    ///   - detail: 第二行的小字，可以省略。
    func show(_ message: String, detail: String? = nil, symbol: String) {
        let hosting = NSHostingView(rootView: ToastView(message: message, detail: detail, symbol: symbol))
        let size = hosting.fittingSize
        panel.contentView = WindowBackground.make(cornerRadius: 14, material: .hudWindow, content: hosting)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // 放在屏幕下方、面板上沿以上，面板开着时也不会被挡住。
            let origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + PanelController.panelHeight + 40
            )
            panel.setFrame(NSRect(origin: origin, size: size), display: true)
        }

        hideWork?.cancel()
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                self.panel.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated {
                    // 淡出期间又显示了新提示时不要收起。
                    if self.panel.alphaValue == 0 { self.panel.orderOut(nil) }
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Self.duration, execute: work)
    }
}

private struct ToastView: View {
    let message: String
    let detail: String?
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text(message)
                    .font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .fixedSize()
    }
}
