# 0006 偏好域沿用 bundle id，在 .app 内通过 `.standard` 读写

日期：2026-10-16

部分被 ADR 0009 取代：开发版（`swift run`、`swift test`、`scripts/bundle.sh` 打的 PasteMe Dev）改用 `io.github.skjz.PasteMe.dev` 这个域，下面说的取法不变。

ADR 0002 规定设置存在 `UserDefaults(suiteName: "io.github.skjz.PasteMe")`，应用和 MCP 子进程共用。这个名字就是 PasteMe.app 的 bundle id，而系统不接受把主 bundle id 当 suite 名：在 .app 里运行时 `UserDefaults(suiteName:)` 返回 nil，并在日志里打印 "Using your own bundle identifier as an NSUserDefaults suite name does not make sense"（2026-10-16 实测）。我们保留这个偏好域，由 `Settings` 按运行环境选择取法：主 bundle id 等于 suite 名时（应用本体，以及 ADR 0005 中从包内同一个可执行文件启动的 `PasteMe mcp`）用 `UserDefaults.standard`，它就是这个偏好域；否则（`swift run`、`swift test`）用 suite。两种取法读写的都是 `~/Library/Preferences/io.github.skjz.PasteMe.plist`。

## Considered Options

- 换一个不同于 bundle id 的 suite 名（例如 `io.github.skjz.PasteMe.settings`）：任何环境都能直接用 suite，代码不需要分支。但 PasteMe 的偏好会分散到两个 plist 里，AppKit 自己写入的键（如菜单栏图标位置）仍在 bundle id 的域里，查看和修改设置时要记住另一个域名。
- 一律用 `.standard`：`swift run` 时没有 bundle id，`.standard` 会落到以可执行文件名命名的域，和应用读写的不是同一份设置。

## Consequences

- `Settings.sharedDefaults()` 里的分支是有意为之。写成 `UserDefaults(suiteName: Settings.suiteName)!` 会让应用在第一次读取设置时崩溃，而 `swift test` 不在 .app 里运行，测不出来。
- 修改 Info.plist 的 `CFBundleIdentifier` 会让已有设置读不到，需要同时迁移偏好域。
