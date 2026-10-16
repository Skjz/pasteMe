# 架构说明

写给要修改 PasteMe 代码的人和 agent。这里说明代码怎么分层、seam 在哪里、怎样测试和验证。做这些决定的理由在 [docs/adr/](adr/)，术语以 [GLOSSARY.md](../GLOSSARY.md) 为准。目录结构和文件列表直接看仓库即可，本文只写从代码里看不出来的约定。

## Target 和依赖方向

```text
PasteMe        可执行文件，只有 main.swift
└─ PasteMeApp  AppKit / SwiftUI：剪贴板轮询、快捷键、发送 ⌘V、面板、视图
   └─ PasteMeCore  不依赖界面：ClipStore、ClipQuery、Paster、Settings、PasteboardCodec、Thumbnailer
```

- 能离开界面测试的逻辑都放进 `PasteMeCore`，对外接口为 `public`。
- `PasteMeApp` 里只有 `AppDelegate` 是 `public`（`main.swift` 要用），其余保持 internal，测试用 `@testable import PasteMeApp`。

ADR 0002 规划的模块里，有几个要等第一个用到它的工单才建。在此之前，它们的职责由下面这些现有代码承担。做对应工单时，先把这些代码移进新模块：

| 规划中的模块 | 现在由谁承担 | 建立时机 |
| --- | --- | --- |
| `Recorder` | `ClipboardMonitor.poll()`：轮询、判断记不记录、入库 | #7 |
| `HotKeyCenter` | `HotKey`：只能注册一个快捷键 | #7 |
| `EnrichmentQueue` | 缩略图在 `ClipStore.insert` 里同步生成 | #5 |
| `PanelKeymap` | `PanelController.handle(_:)` | 第一个改面板按键的工单（#1 或 #2） |
| Paste Stack | 无 | #6 |
| `MCPServer`（`PasteMeMCP` target） | 无 | #8 |

## 粘贴流程

```text
HistoryModel.paste(as:) / paste(at:as:) # 回车、双击、右键菜单 / ⌘1…⌘9
└─ AppDelegate.paste(_:as:)
   ├─ panel.hide()                      # 先收起面板，⌘V 才会落到目标应用
   ├─ Paster.paste(id, as: mode, into: panel.targetApp)
   │  ├─ ClipStore.content(id:)         # 条目已不存在 → 抛 PasteError.clipNotFound
   │  ├─ .plainText 时去掉 RTF
   │  ├─ PasteboardWriting.write
   │  ├─ ClipStore.touch(id:)           # 移到历史最前；失败不影响这次粘贴
   │  └─ PasteKeystrokeSending.isTrusted ? sendPaste(to:) → .pasted : .copiedOnly
   └─ .copiedOnly 时 Accessibility.requestTrust()
```

- 发送 ⌘V 前的 0.08 秒延迟（等面板收起、键盘焦点回到目标应用）放在 `CGEventPasteKeystroke` 里，`Paster.paste` 本身是同步的，测试不需要等待。
- 有没有辅助功能权限，由按键 adapter 的 `isTrusted` 判断；弹出系统授权提示是应用层的事（`Accessibility`）。
- `TargetApp` 在 `PanelController.show()` 时从前台应用取得。面板不激活 PasteMe，所以生产环境里 ⌘V 直接发给前台应用，用不到这个值。它是为 #13 的粘贴事件（记录粘贴到了哪个应用）准备的。

## Seam 和测试替身

| Seam | 生产实现 | 测试替身 |
| --- | --- | --- |
| `PasteboardWriting` | `GeneralPasteboard`（Core，`PasteboardCodec` 写 `NSPasteboard.general`） | `FakePasteboard`（`PasterTests.swift`） |
| `PasteKeystrokeSending` | `CGEventPasteKeystroke`（App） | `FakeKeystroke`（`PasterTests.swift`） |
| `ClipStore(path:)` | `ClipStore.defaultPath()` | `ClipStore(path: ":memory:")` |
| `Settings(defaults:)` | 偏好域 `io.github.skjz.PasteMe`，取法见 ADR 0006 | 每个测试一个随机名字的 suite，结束时删除 |

只在已经有两个实现（测试替身也算一个）并且有调用方时才加 seam（ADR 0002）。

## 扩展查询和设置

- **查询条件**：新的筛选字段加在 `ClipQuery` 上，转成 SQL 的代码也写在 `ClipQuery.swift` 的 `filter` 里，`ClipStore.items(matching:)` 不需要改。每个条件生成一段带括号的子句，多个条件用 AND 连接。搜索继续用 LIKE（ADR 0004），10,000 条条目时查询要在 50ms 以内（ADR 0003）。
- **设置项**：所有开关都定义在 `Settings` 上，键名放在 `Settings.Key` 里。每个开关都写默认值测试和读写测试，参照 `SettingsTests`。

## 线程

`ClipStore` 只在主线程使用（ADR 0003）。用到它的类型（`AppDelegate`、`HistoryModel`、`ClipboardMonitor`、`Paster`）都标了 `@MainActor`，测试这些类型的 suite 也要标 `@MainActor`。

## 在真实应用里验证

全局快捷键、面板、真正发送 ⌘V 这些行为，单元测试覆盖不到。改动涉及它们时，按下面的步骤运行应用确认。

1. 用 `pgrep -fl PasteMe` 检查用户是否已经开着 PasteMe。两个实例会争抢 ⇧⌘V，需要先和用户确认能否退出。
2. 运行 `scripts/bundle.sh` 打包。用 Apple Development 证书签名时，辅助功能权限在重新打包后仍然有效。
3. 把 home 指向临时目录再启动，这样不会碰到用户真实的历史和设置：

   ```bash
   open --env CFFIXED_USER_HOME="$TMPDIR/pasteme-home" build/PasteMe.app
   ```

   历史数据库在 `$TMPDIR/pasteme-home/Library/Application Support/PasteMe/history.sqlite`，可以用 `sqlite3` 直接查。
4. 用 `pbcopy` 造测试数据时加上 `LANG=en_US.UTF-8`。不设 `LANG` 时，含中文的内容会被写成空字符串，PasteMe 会直接跳过它。
5. 用截图检查时，面板可能不出现在截图里（例如 computer-use 只截授权应用的窗口）。这时看操作结果：目标应用里粘贴出的文字，以及数据库里条目的增删和顺序。
6. 验证完在仓库根目录用完整路径退出测试实例，以免误关用户自己的 PasteMe：`pkill -f "$PWD/build/PasteMe.app/Contents/MacOS/PasteMe"`。然后删除临时目录。
