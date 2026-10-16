# 架构说明

写给要修改 PasteMe 代码的人和 agent。这里说明代码怎么分层、seam 在哪里、怎样测试和验证。做这些决定的理由在 [docs/adr/](adr/)，术语以 [GLOSSARY.md](../GLOSSARY.md) 为准。目录结构和文件列表直接看仓库即可，本文只写从代码里看不出来的约定。

## Target 和依赖方向

```text
PasteMe        可执行文件，只有 main.swift
└─ PasteMeApp  AppKit / SwiftUI：剪贴板轮询、全局快捷键、监听 ⌘V、发送 ⌘V、面板、浮窗、视图
   └─ PasteMeCore  不依赖界面：ClipStore、ClipQuery、AppNames、Recorder、EnrichmentQueue、PasteStack、Paster、Settings、PasteboardCodec、Thumbnailer
```

- 能离开界面测试的逻辑都放进 `PasteMeCore`，对外接口为 `public`。
- `PasteMeApp` 里只有 `AppDelegate` 是 `public`（`main.swift` 要用），其余保持 internal，测试用 `@testable import PasteMeApp`。

ADR 0002 规划的模块里，只有 `MCPServer`（`PasteMeMCP` target）还没建，等 #8 再建。

## 记录和全局快捷键

- `ClipboardMonitor` 只轮询剪贴板：发现变化后跳过 PasteMe 自己写入的内容和敏感内容，读出内容和来源应用，交给 `Recorder.record(_:from:)`。暂停时它连剪贴板都不读。
- `Recorder` 决定记不记录（暂停），入库后调用 `onRecord`。暂停只在内存里：`pausedUntil` 为 `.distantFuture` 表示直到手动恢复，定时暂停由 `Recorder` 自己的定时器到时恢复，`onPauseChange` 通知应用换菜单栏图标、显示提示。测试用注入的时钟（`RecorderTests`）。
- 菜单栏图标由 `AppDelegate.updateStatusIcon()` 决定：暂停记录优先，其次 Paste Stack。屏幕上的短暂提示用 `Toast`。
- 全局快捷键都通过 `HotKeyCenter.register(_:action:)` 注册，按键组合定义在 `GlobalShortcut`。Carbon 会把每个快捷键事件发给所有已安装的处理器，所以只装一个处理器，读出事件里的快捷键 id 再分发；`HotKeyCenterTests` 直接调用 `dispatch` 模拟按键。

## Paste Stack

- `PasteStack`（Core）只管开关和顺序：`Recorder` 记下条目后调用 `push`，没开启时什么都不做；`takeNext` 取出最前面的一条，取完最后一条随之结束。
- `PasteStackController`（App）开启时创建 `KeyEventTap`（会话级 `CGEventTap`，只观察 keyDown，不拦截），按 `PasteStackKeys.action` 判断按键：⌘V 取下一条，esc 退出，其余不管。按住不放的重复按键、面板开着时的 ⌘V、PasteMe 自己发送的 ⌘V（`eventSourceUserData` 等于 `CGEventPasteKeystroke.marker`）都不取。
- 时机：事件监听在按键送到目标应用之前同步回调，回调里用 `Paster.copyToPasteboard` 把下一条写进剪贴板（带 `ownMarker`，不会再被记录），目标应用处理这次 ⌘V 时读到的就是它。所以不需要在 keyUp 之后延迟替换、猜测目标应用什么时候读完剪贴板。回调要快：系统会停掉太慢的监听（`KeyEventTap` 收到 `tapDisabledByTimeout` 时重新打开）。
- 结束时（手动退出或取完）在下一轮事件循环里移除监听，不在它自己的回调里移除。
- 浮窗（`PasteStackHUD`）的面板 `canBecomeKey` 为 false：点里面的按钮也不能抢走目标应用的键盘焦点，否则接下来的 ⌘V 会落在浮窗上。
- 监听别的应用的按键需要辅助功能权限，没有权限时 `CGEvent.tapCreate` 返回 nil，开启前先检查并提示。
- 按键判断在 `PasteStackKeysTests`，顺序和开关在 `PasteStackTests`。监听本身只能在真实应用里验证：开启后依次 `pbcopy` 几段文字，在文本编辑里连按 ⌘V。

## 附加信息

- 图片中的文字由 `EnrichmentQueue` 补充：`Recorder` 记下图片或图片文件后调用 `enqueue(id)`，启动 3 秒后 `AppDelegate` 调用 `backfill()` 补做旧条目。队列一次只处理一个条目，新复制的排在前面，补做的每条之间停 0.5 秒。
- 线程：在主线程用 `ClipStore.textRecognitionInput(id:)` 读出图片（`Sendable` 的 `TextRecognitionInput`），在后台识别，回到主线程用 `setRecognizedText(_:id:)` 写回（ADR 0003）。`VisionTextRecognizer` 自己用 `Task.detached` 切到后台，不依赖调用方。
- `ocr_text` 为 NULL 表示还没识别，空字符串表示识别过但没有文字或识别失败，以后不再识别。图片文件识别原文件，原文件不在了识别缩略图（缩略图只有 480 像素，效果差一些）。
- 缩略图仍在 `ClipStore.insert` 里同步生成，没有移进队列：复制图片后卡片要马上能显示缩略图。
- 测试用 `FakeRecognizer`（`TextRecognitionTests.swift`），另有一个测试真的调用 Vision 识别画出来的中英文。

## 面板按键

`PanelKeymap.action(for:in:)` 是纯函数：输入按键（`PanelKey`）和面板状态（焦点、搜索词是否为空、能否撤销），输出要执行的面板命令，或者把按键交给搜索框。新的面板快捷键加在这里，并在 `PanelKeymapTests` 里写对应的用例。`PanelController.handle(_:)` 只负责把 `NSEvent` 转成 `PanelKey`、执行命令。

- 焦点（`HistoryModel.focus`）是唯一的状态来源，`HistoryView` 把它同步到搜索框的 `@FocusState`。呼出面板时焦点在卡片列表上。窗口第一次成为 key 时 AppKit 会自动让搜索框成为第一响应者，SwiftUI 随之把 `focus` 改成搜索框，所以 `PanelController.show()` 在 `makeKeyAndOrderFront` 之后把第一响应者交还给窗口本身。
- 焦点在卡片上时打字，需要让这次按键直接进入搜索框。本地事件监视器在事件分发之前回调，所以 `PanelController` 在监视器里同步把搜索框设为第一响应者，再把事件放行。搜索框是在视图层级里找到的第一个可编辑 `NSTextField`。
- 输入法组字时（搜索框的字段编辑器 `hasMarkedText()`），所有按键都交给输入法：↩、方向键和 esc 是用来选字和取消的。
- 删除时 `ClipStore.delete(id:)` 返回 `DeletedClip`，`HistoryModel` 保存到面板关闭为止，⌘Z 用 `ClipStore.restore(_:)` 按原来的 id、时间和缩略图放回。删除和撤销的动画见「删除动画」。
- PasteMe 没有菜单栏，但 `AppDelegate.setUpMainMenu()` 设了一个不显示的主菜单：输入框的 ⌘X、⌘C、⌘V、⌘A、⌘Z 和 ⌘W 关闭窗口都要靠菜单项的快捷键才能用。

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
- 动画是否流畅用 `scripts/bench-panel.sh` 测量（DEBUG 构建里的 `PanelBenchmark`），步骤和读数见 `docs/agents/ui-performance.md`。

## 删除动画

删除时卡片碎成颗粒向上飘散，所有颗粒散完后右边的卡片才一次补上来；撤销时颗粒飘回来拼成卡片。

**分工**

- `HistoryModel` 只通过 `CardRemovalEffect` 协议要求播放动画，生产实现是 `CardDust`，测试用 `FakeRemovalEffect`，没有设置时列表直接变化。模型改列表都经过 `HistoryModel.animate`（就是 `withAnimation`），测试替换它来观察视图会看到的状态。
- `CardDust` 用 `ImageRenderer` 把卡片画成图（和面板一样的外观、⌘n 和搜索命中），交给 `DustView` 播放。`DustView` 是盖在 `HistoryView` 根视图上的透明 `CAMetalLayer`，每个颗粒是一个实例，位置、大小、透明度都在着色器里按时间和序号算，主线程每帧只更新时间、提交一次绘制。节奏参数在 `DustTiming`。着色器源码在运行时编译（SwiftPM 不编译 .metal 文件），`PanelController.prewarm()` 启动时在后台编译；没编译好时删除不播放颗粒。
- 开启「减少动态效果」时不播放颗粒，卡片直接去掉，右边的卡片用短的缓动补上。

**规则**（每一条都对应过一个真实的显示问题）

- **空位**：条目在 `delete()` 里马上从 `items` 去掉，选中项、⌘1…⌘9 和接下来的按键都按新列表算；屏幕上由 `HistoryModel.cards` 在原来的地方插一个空位。空位按被删条目的复制时间排进列表（和 `ClipStore` 的顺序一样），不记「第几格」：中间又删掉或放回别的卡片时格数会过时，卡片会换位置。不能改用「列表立即变化、动画推迟开始」：推迟期间 SwiftUI 报告的已经是新位置，连续删除时颗粒会出现在错误的地方。
- 卡片变成空位时还是同一个视图，只是透明、不接收点击（`HistoryView.cardView`）。换成另一种视图的话，正在播放选中动画的卡片会被多留一会儿，后面的卡片被挤开一格。透明度要放在 `.animation(_:value: selected)` 外面，否则删除选中的卡片时它会跟着选中的弹簧慢慢变淡。空位去掉时要立即移除（`HistoryView.cardTransition`），之后撤销放回同一个条目时才是新视图。
- **一次改完**：删除和撤销对视图可见的状态（`items`、`gaps`、`hiddenIDs`、`selectedID`）要在同一个 `animate` 里改。SwiftUI 进入 `withAnimation` 前会先渲染之前的改动；先加空位、再在里面重新查询的话，中间有一帧同一个条目出现两次。
- **颗粒播放时卡片不动**：颗粒画在所有卡片上面，卡片滑进它的范围就会和深色颗粒混成一片碎块。所以空位要等所有消失动画和撤销时的出现动画都播完，才一起去掉。撤销时颗粒要等卡片的位置上现在和接下来都没有别的卡片挡着才开始聚拢（`CardDust.tryToStart`，沿着别的卡片剩下的滑动轨迹逐帧检查，因为滑到一半改了终点的卡片会带着速度冲过头）；回到自己空位时一般马上开始。撤销后还在等着开始聚拢的卡片又被删除：原来的颗粒还在飘就让它接着飘完、照常留空位，已经飘完就当这张卡片没出现过。
- **滑动途中的位置**：布局（`CardDust.frames`）给的是滑动的终点。模型用 `slideAnimation()` 取补位或让位的动画，`CardDust` 记下时间；随后 `HistoryView` 报上来的布局变化（`cardLaidOut`）按这个弹簧从旧位置滑向新位置，从报告的那一刻算起：SwiftUI 在处理这次更新时才开始播放动画、同时报告位置，可能比模型改列表晚一两帧。`CardDust.visibleFrame(of:)` 据此算出卡片此刻在屏幕上的位置，删除时颗粒从这里开始，播放中的颗粒每帧都按它画（卡片被后来放回的卡片挤开时颗粒跟着走）。
- **大小**：聚拢中的颗粒按 `CardDust.scale(of:)` 放大，跟着选中状态用和卡片同一个弹簧（`SpringCurve.selection`）放大或缩回；刚出现的卡片（和选中项在同一次更新里报上位置）直接是目标大小。飘散中的颗粒保持开始时的大小。
- **弹簧**：`SpringCurve` 的公式就是 SwiftUI 的 `.spring(response:dampingFraction:)`。卡片补位用 `SpringCurve.slide`（阻尼 0.86）：几个空位一起去掉时卡片一次滑过好几格，回弹必须小于卡片间距，否则会撞进左边的卡片。光标平时用更有弹性的 `SpringCurve.cursor`，卡片补位时跟着用这次的动画。
- 消失到一半撤销、拼到一半又删除，都从当前的样子接着播（`DustView.play`）。

**测试**

三层，从快到慢。改删除动画或面板卡片列表的布局时三层都要跑：

1. `PanelFlushTests`：把 `HistoryModel.animate` 换成「先检查当时的 `cards`、再执行」，模拟 SwiftUI 进入 `withAnimation` 前的渲染，检查删除、撤销做到一半时没有重复的条目、留空位的过程中卡片不换位置。
2. `DeleteAnimationScenarioTests`：`PanelSimulator` 用真实的 `HistoryModel` 和 `CardDust` 加虚拟时钟（`CardDust.now`、`CardDust.schedule`、`DustView.advance()`），按 SwiftUI 的规则算出每张卡片每一帧在屏幕上的位置和大小，逐帧检查：颗粒和卡片对齐、卡片之间不重叠、卡片不滑进颗粒、空位等颗粒播完才去掉，最后一切停在布局位置上。几个具名场景对应用户碰到过的操作，另有随机操作序列。随机序列平时跑 60 个种子；改了这部分逻辑后用 `PASTEME_FUZZ_SEEDS=2000 swift test --filter randomSequences` 多跑一些（约 2 分钟），失败信息里有种子和操作，`PM_TRACE=<种子>` 逐帧打印那个种子的状态。
3. `SwiftUIAssumptionTests`：在不显示的窗口里放真实的 `HistoryView`，确认上面两层依赖的 SwiftUI 行为还成立：进入 `withAnimation` 前先渲染；带动画的移动只报告终点；新位置在 `CardDust.slideWindow` 以内报上来；新插入的选中卡片和选中项在同一次更新里报告。这层失败说明 SwiftUI 或面板的视图结构变了，先改 `PanelSimulator` 和 `CardDust` 的对应部分。

`DustShaderTests` 离屏执行着色器，检查第一帧拼出的卡片没有缝、方向正确、颗粒向上飘、最后全部透明。测试管不到的是观感和真实屏幕上的掉帧：流畅度用 `scripts/bench-panel.sh --delete` 测（见 `docs/agents/ui-performance.md`），观感请用户在真实屏幕上看。用户录屏反馈时要先打开「共享屏幕时显示面板」，否则录不到面板；用 ffmpeg 逐帧导出、按相邻帧的差异找到动画发生的时间段再放大看。

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
| `TextRecognizing` | `VisionTextRecognizer`（Core） | `FakeRecognizer`（`TextRecognitionTests.swift`） |
| `CardRemovalEffect` | `CardDust`（App） | `FakeRemovalEffect`（`FakeRemovalEffect.swift`） |
| `HistoryModel.animate` | `withAnimation` | 先检查视图可见的状态再执行（`PanelFlushTests`、`PanelSimulator`） |
| `CardDust.now`、`CardDust.schedule` | `CACurrentMediaTime`、`DispatchQueue.main.asyncAfter` | 虚拟时钟（`PanelSimulator`），配合 `DustView.advance()` 逐帧推进 |
| `AppNames(systemNames:)` | `AppBundleNames.names(ofBundleID:)`（Core，读已安装应用的本地化名字） | 固定的字典（`AppNamesTests`、`AppAliasesTests`） |
| `PasteboardWriting` | `GeneralPasteboard`（Core，`PasteboardCodec` 写 `NSPasteboard.general`） | `FakePasteboard`（`PasterTests.swift`） |
| `PasteKeystrokeSending` | `CGEventPasteKeystroke`（App） | `FakeKeystroke`（`PasterTests.swift`） |
| `ClipStore(path:)` | `ClipStore.defaultPath()` | `ClipStore(path: ":memory:")` |
| `Settings(defaults:)` | 偏好域 `io.github.skjz.PasteMe`，取法见 ADR 0006 | 每个测试一个随机名字的 suite，结束时删除 |

只在已经有两个实现（测试替身也算一个）并且有调用方时才加 seam（ADR 0002）。

## 扩展查询和设置

- **查询条件**：新的筛选字段加在 `ClipQuery` 上，转成 SQL 的代码也写在 `ClipQuery.swift` 的 `filter` 里，`ClipStore.items(matching:)` 不需要改。每个条件生成一段带括号的子句，多个条件用 AND 连接。搜索继续用 LIKE（ADR 0004），10,000 条条目时查询要在 50ms 以内（ADR 0003），`ClipFilterTests` 里有对应的测试。
- **筛选的来源**：面板上的按钮和菜单改 `HistoryModel.filters`（`PanelFilters`）；搜索框里的 `type:`、`app:` 由 `ClipQuery.parse` 解析，不回写到按钮上。搜索框末尾的 `@词`（`FilterMention`）弹出候选列表（`HistoryModel.suggestions`：`ClipKind.matching` 加上 `AppNames.apps(matching:)`），选中后从搜索框里去掉这个词、写进 `filters`，所以显示在按钮上。有候选项时这个词不参与搜索；没有候选项或按 esc 关掉列表后，它按普通文字搜索。`HistoryModel.currentQuery` 把两者合起来，类型取交集（`ClipQuery.kinds` 为空集合时什么都不返回）。`query` 和 `filters` 改动后立即重新查询；`didShow` 一次清空两者，只查询一次，因为它在呼出动画的第一帧之前运行。
- **来源应用菜单**：用 AppKit 的 `NSMenu`，点开时才调用 `ClipStore.sourceApps()`，不在呼出面板时查询。
- **按应用的其他名字搜索**：条目只记了复制时的应用名（中文系统下是「访达」）。`HistoryModel.currentQuery` 最后调用 `ClipQuery.resolvingAppNames`，由 `AppNames` 找出名字、其他语言的名字（`AppBundleNames`，只读用户语言和英文）或应用别名（`Settings.appAliases`）包含搜索文字的应用，SQL 里加 `OR source_bundle_id IN (…)`。从应用包读名字一个应用要一两毫秒，所以启动 3 秒后 `AppNames.prefetch()` 在后台读完历史里的应用；应用列表在每次呼出面板时（`historyChanged()`）作废，第一次搜索时重新查。别名在 `AppAliasesWindow` 里编辑，输入时就保存，不需要通知 `AppNames`。
- **数据库迁移**：`ClipStore.migrate()` 按 `user_version` 逐级升级，每一级一个 `if` 块，最后设新的版本号。改表结构时加一级，并在 `ClipStoreMigrationTests` 里用上一版的表结构建库，确认旧数据还在。
- **设置项**：所有开关都定义在 `Settings` 上，键名放在 `Settings.Key` 里。每个开关都写默认值测试和读写测试，参照 `SettingsTests`。

## 线程

`ClipStore` 只在主线程使用（ADR 0003）。`AppNames.prefetch()` 只把读应用包这一步放到后台（只用 Foundation 和 LaunchServices），结果回到主线程存进缓存。用到它的类型（`AppDelegate`、`HistoryModel`、`ClipboardMonitor`、`Paster`）都标了 `@MainActor`，测试这些类型的 suite 也要标 `@MainActor`。

## 在真实应用里验证

全局快捷键、面板、真正发送 ⌘V 这些行为，单元测试覆盖不到。改动涉及它们时，按下面的步骤运行应用确认。

1. 用 `pgrep -fl PasteMe` 检查用户是否已经开着 PasteMe。两个实例会争抢全局快捷键（⇧⌘V、⌃⇧⌘V、⌃⇧⌘C），需要先和用户确认能否退出。
2. 运行 `scripts/bundle.sh` 打包。用 Apple Development 证书签名时，辅助功能权限在重新打包后仍然有效。
3. 把 home 指向临时目录再启动，这样不会碰到用户真实的历史：

   ```bash
   open --env CFFIXED_USER_HOME="$TMPDIR/pasteme-home" build/PasteMe.app
   ```

   历史数据库在 `$TMPDIR/pasteme-home/Library/Application Support/PasteMe/history.sqlite`，可以用 `sqlite3` 直接查。
   设置不隔离：偏好设置由 cfprefsd 按真实用户读写，不认 `CFFIXED_USER_HOME`。在测试实例的菜单里改开关、在别名窗口里加别名，改的都是用户真实的设置（`defaults read io.github.skjz.PasteMe` 可以查看）。请用户这样试之前先说明，试完提醒改回去。
4. 用 `pbcopy` 造测试数据时加上 `LANG=en_US.UTF-8`。不设 `LANG` 时，含中文的内容会被写成空字符串，PasteMe 会直接跳过它。
5. 用截图检查时，面板可能不出现在截图里（例如 computer-use 只截授权应用的窗口）。这时看操作结果：目标应用里粘贴出的文字，以及数据库里条目的增删和顺序。面板默认不出现在录屏里（`sharingType = .none`），请用户录屏反馈动画问题时，要先在菜单里打开「共享屏幕时显示面板」，否则录到的只有面板后面的桌面。
6. 验证完在仓库根目录用完整路径退出测试实例，以免误关用户自己的 PasteMe：`pkill -f "$PWD/build/PasteMe.app/Contents/MacOS/PasteMe"`。然后删除临时目录。
