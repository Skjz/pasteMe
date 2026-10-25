import AppKit
import Testing
@testable import PasteMeApp

/// 菜单栏菜单里的「暂停记录」每次打开菜单都重新设一遍（#61）：没有暂停时挂子菜单，暂停时换成「恢复记录」。
@MainActor
@Suite struct MenuItemTests {
    final class Target: NSObject {
        @objc func resume() {}
        @objc func pause() {}
    }

    let target = Target()
    let menu = NSMenu()
    let item = NSMenuItem(title: "暂停记录", action: nil, keyEquivalent: "")
    let submenu = NSMenu()

    init() {
        _ = NSApplication.shared
        submenu.addItem(NSMenuItem(title: "暂停 5 分钟", action: #selector(Target.pause), keyEquivalent: ""))
        submenu.items[0].target = target
        menu.addItem(item)
        item.target = target
    }

    /// 菜单打开时 AppKit 按 action 和 target 重新决定菜单项能不能点。
    func isEnabledWhenOpened() -> Bool {
        menu.update()
        return item.isEnabled
    }

    @Test func submenuStaysEnabledEveryTimeTheMenuOpens() {
        for _ in 0..<3 {
            item.showSubmenu(submenu)
            #expect(isEnabledWhenOpened())
        }
    }

    @Test func submenuIsEnabledAgainAfterResuming() {
        item.showSubmenu(submenu)
        item.submenu = nil
        item.action = #selector(Target.resume)
        #expect(isEnabledWhenOpened())

        item.showSubmenu(submenu)
        #expect(item.hasSubmenu && isEnabledWhenOpened())
        #expect(item.action == #selector(NSMenu.submenuAction(_:)))
    }
}
