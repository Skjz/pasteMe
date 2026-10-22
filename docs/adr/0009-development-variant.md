# 0009 开发版用自己的 bundle id、偏好域和数据目录

日期：2026-10-23

0.1.0 发布后，用户在「应用程序」里装着 PasteMe 日常使用，开发时又要启动测试实例。以前两者共用一个 bundle id，于是共用偏好域 `io.github.skjz.PasteMe`（ADR 0006）：在测试实例里改的开关就是用户真实的设置。自动清除历史的期限每小时从设置里重新读，测试实例里改成 7 天，用户自己的 PasteMe 一小时内就会删掉真实历史里的旧条目，而且不弹确认框。登录项（`SMAppService.mainApp`）也按应用登记，同样会被测试实例改掉。

现在分成发布版和开发版（`AppVariant`）。只有 `scripts/make-dmg.sh` 打出的应用是发布版，bundle id 保持 `io.github.skjz.PasteMe`。其余都是开发版：`scripts/bundle.sh` 默认把 bundle id 改成 `io.github.skjz.PasteMe.dev`，名字改成「PasteMe Dev」；`swift run`、基准、截图模式没有 bundle id，测试进程的 bundle id 是别的，也都按开发版处理。开发版的偏好域是 `io.github.skjz.PasteMe.dev`，历史和缓存放在 `PasteMe Dev` 目录。ADR 0006 的取法不变（应用包里用 `.standard`，否则用 suite），只是选哪个域由 `AppVariant` 决定；ADR 0006 里「`swift run`、`swift test` 读写同一个偏好文件」这一点不再成立。

## Considered Options

- 只在 `#if DEBUG` 里换偏好域：`scripts/bundle.sh` 默认编 release，测试实例照样落到用户的域；而且偏好域分开了，登录项和辅助功能权限仍然和发布版混在一起。
- 只换偏好域，bundle id 不变：用 suite 读写另一个域就行，但 AppKit 自己写的键（菜单栏图标位置）、登录项、辅助功能权限仍按 bundle id 算。
- 历史目录不分开，只靠测试时设 `CFFIXED_USER_HOME`：忘了设的时候，开发版会读写用户真实的数据库，数据库升到新版本以后，旧的发布版可能读不了。

## Consequences

- 开发版的设置从默认值开始，和用户在发布版里的设置互不影响；`scripts/bench-panel.sh` 也用开发版的默认设置。和这次改动之前的提交比较读数时，旧提交读的还是用户的设置。
- 「PasteMe Dev」在辅助功能里是单独一项，要单独允许一次；之后用同一张证书重新打包，权限仍然有效。
- 剪贴板和全局快捷键不受偏好域管：两个实例同时运行时，复制的内容两边都会记录，快捷键也会被抢。测试前仍要先退出用户的 PasteMe。
- 改发布版的 bundle id 或 `AppVariant` 的目录名，用户已有的设置和历史就读不到了，需要同时迁移。
