# 0001 用 Swift Package 构建原生 macOS 应用，不依赖第三方库

日期：2026-10-16

## 背景

PasteMe 是一个常驻后台的剪贴板管理工具，核心功能都依赖 macOS 系统 API：读写 `NSPasteboard`、注册全局快捷键、用不激活自身的浮动面板接收键盘输入、模拟 ⌘V。项目由一个人长期维护。

## 决定

- 用 Swift 6 + SwiftUI/AppKit 写原生应用，不用 Tauri 或 Electron。上述系统 API 在 Swift 里可以直接调用，常驻进程的内存占用也最小。
- 用 Swift Package 组织代码，不建 Xcode 工程。`swift build` / `swift test` 在命令行即可完成构建和测试，`scripts/bundle.sh` 负责打包成 `.app` 并签名。
- 不引入第三方依赖：存储直接用系统自带的 SQLite3（`ClipStore` 里有一层很薄的封装），全局快捷键用 Carbon 的 `RegisterEventHotKey`。
- 代码分为 `PasteMeCore`（无界面逻辑，可单元测试）和 `PasteMe`（应用本体）两个 target。

## 后果

- 只支持 macOS。将来如果要做 iOS 版，`PasteMeCore` 里的存储和模型可以复用，`PasteboardCodec` 需要另写 UIKit 版本。
- 没有 Xcode 工程，资源目录、Asset Catalog、App Sandbox 权限文件等需要在打包脚本里手动处理。需要上架 Mac App Store 时再重新评估。
- 剪贴板变化靠每 0.5 秒轮询 `changeCount` 检测（系统没有提供变化通知），两次复制间隔小于轮询间隔时只会记下后一次。
