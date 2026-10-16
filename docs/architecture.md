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
| Paste Stack | 无 | #6 |
| `MCPServer`（`PasteMeMCP` target） | 无 | #8 |

## 面板按键

`PanelKeymap.action(for:in:)` 是纯函数：输入按键（`PanelKey`）和面板状态（焦点、搜索词是否为空、能否撤销），输出要执行的面板命令，或者把按键交给搜索框。新的面板快捷键加在这里，并在 `PanelKeymapTests` 里写对应的用例。`PanelController.handle(_:)` 只负责把 `NSEvent` 转成 `PanelKey`、执行命令。

- 焦点（`HistoryModel.focus`）是唯一的状态来源，`HistoryView` 把它同步到搜索框的 `@FocusState`。
- 焦点在卡片上时打字，需要让这次按键直接进入搜索框。本地事件监视器在事件分发之前回调，所以 `PanelController` 在监视器里同步把搜索框设为第一响应者，再把事件放行。搜索框是在视图层级里找到的第一个可编辑 `NSTextField`。
- 删除时 `ClipStore.delete(id:)` 返回 `DeletedClip`，`HistoryModel` 保存到面板关闭为止，⌘Z 用 `ClipStore.restore(_:)` 按原来的 id、时间和缩略图放回。

## 卡片外观

- 标题栏颜色由 `CardStyle(for:)` 决定：来源应用图标的代表色（`IconColor.dominant`，在 `PasteMeCore`，测试在 `IconColorTests`），找不到应用或图标全透明时用类型的颜色。图标和颜色都由 `AppIconCache` 按 bundle id 缓存，每个应用只算一次。
- 光标（`SelectionCursor`）不是每张卡片各画一个，而是在卡片列表上叠一层，按选中卡片的序号算出横向位置，所以选中项变化时能滑过去。这依赖卡片宽度固定（`ClipCardView.size`）和间距固定（`HistoryView.cardSpacing`）；改卡片布局时要同时改光标的位置计算。
- 光标的旋转和明暗变化由 `TimelineView` 逐帧驱动，面板收起后（`HistoryModel.isPanelVisible` 为 false）或开启「减少动态效果」时暂停，不在后台耗电。
- 标题栏图标比标题栏大、一部分被裁掉。这个裁切不能在运行时用 `.clipped()` 做：裁切超出范围的内容会让每张卡片在依次出现的动画里逐帧重新合成，#17 之后呼出面板时大约三分之一的帧赶不上 120 Hz。现在由 `AppIconCache.headerIcon` 把放大、阴影、裁切和卡片右上圆角一起画成一张正好标题栏右端大小的图片，所以标题栏高度固定为 `ClipCardView.headerHeight`。改标题栏的布局时要同时改 `headerIconSlice` 和 `headerIconFrame`。
- 光标样式存在 `Settings.cursorStyle`，同时放一份在 `HistoryModel.cursorStyle`，让视图在菜单里切换后立即更新。
- 卡片列表左右的留白用 `contentMargins` 而不是 `padding`，这样 `scrollTo` 滚到某张卡片时也会留出这段距离。放大的卡片和光标的光晕会超出滚动区域的上下边，所以滚动区域设了 `scrollClipDisabled()`。

## 面板动画

- `PanelMotion` 是纯值类型，按弹簧的解析解算出某一时刻的进度（0 收起，1 就位）和速度，参数在 `Spring.show` / `.hide` / `.fade` 里调整，测试在 `PanelMotionTests`。从任意进度和速度出发，所以动画中途反向时不会跳。
- `PanelAnimator` 用 display link 逐帧移动窗口、改透明度。display link 按显示器创建，不用时暂停而不销毁，并在启动时由 `PanelController.prewarm()` 提前创建：第一次创建要读取显示器的模式列表，约 0.2 秒，放在第一次呼出时会丢掉开头的帧。
- 收起时面板先 `orderOut`，键盘焦点马上回到目标应用，⌘V 的时机和没有动画时一样；再用 `orderFrontRegardless` 不取得焦点地放回屏幕，由面板自己滑出（期间 `allowsKey` 和接收鼠标都关掉）。收起中途再次呼出时，面板恢复接收输入，从当前位置弹回去。
- 这依赖 `ClipPanel.animationBehavior = .none`。开着系统窗口动画时，窗口重新上屏会先播系统的过渡，窗口服务器不理会 `setFrameOrigin`，面板只会原地淡出。以前因为这个现象用过一个替身窗口，把面板的内容视图搬过去播动画，但每次搬动内容视图要 18 ms 左右，呼出和收起都会丢帧，已经去掉。
- 卡片依次出现在 `HistoryView` 里用 SwiftUI 动画实现，只对前 8 张做。
- 验证动画时截图拍不到面板，可以用 `CGWindowListCopyWindowInfo` 每隔几毫秒采样 PasteMe 窗口的位置和透明度，看每一帧的位置。
- 衡量动画是否流畅，看两种时间：
  - 主线程：在 `PanelAnimator` 的 display link 回调里记时间戳，看两帧之间的间隔。
  - 实际上屏：在面板的内容图层里临时加一个 2×2 的 `CAMetalLayer`，每个 display link 回调提交一帧，用 `MTLDrawable.addPresentedHandler` 记下 `presentedTime`。相邻两次上屏之间超过 1.5 帧的空档就是用户看到的掉帧。主线程准时而这里掉帧，说明瓶颈在渲染端。
- 不要批量用 Instruments 的 Animation Hitches 模板录制：每录十几秒就会在 `$TMPDIR` 留下十几 GB 的原始追踪文件，删掉输出的 `.trace` 也不会删它们，曾经把磁盘占满。

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
