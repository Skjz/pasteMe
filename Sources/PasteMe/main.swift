import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 只在菜单栏显示，不出现在 Dock 和 ⌘Tab 里。Info.plist 的 LSUIElement 也做了同样的声明，
// 这里再设一次是为了直接 `swift run` 时行为一致。
app.setActivationPolicy(.accessory)
app.run()
