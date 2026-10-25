# 架构说明

写给要修改 PasteMe 代码的人和 agent。这里说明代码怎么分层、seam 在哪里、怎样测试和验证。做这些决定的理由在 [docs/adr/](adr/)，术语以 [GLOSSARY.md](../GLOSSARY.md) 为准。目录结构和文件列表直接看仓库即可，本文只写从代码里看不出来的约定。

## Target 和依赖方向

```text
PasteMe        可执行文件，只有 main.swift
└─ PasteMeApp  AppKit / SwiftUI：剪贴板轮询、全局快捷键、监听 ⌘V、发送 ⌘V、面板、浮窗、视图
   └─ PasteMeCore  不依赖界面：AppVariant、ClipStore、ClipQuery、AppNames、Recorder、RecordChime、EnrichmentQueue（Enricher、LinkPreview、HTMLPreviewFetcher）、PasteStack、Paster、TemporaryFiles、TextFile、Settings、PasteboardCodec、Thumbnailer、TextSubtype（ByteText、CodeDetector）、TextConverter、HashAlgorithm、SyntaxHighlighter、OpenPlan（OpenApp）、KeyCombo（GlobalAction、ShortcutRules）、WebPreviewPolicy、Updates（AppVersion、UpdateRelease、UpdateSignature、UpdateClient、UpdateInstaller）
```

- 能离开界面测试的逻辑都放进 `PasteMeCore`，对外接口为 `public`。
- `PasteMeApp` 里只有 `AppDelegate` 是 `public`（`main.swift` 要用），其余保持 internal，测试用 `@testable import PasteMeApp`。
- 应用图标的源文件是 `Resources/AppIcon.icon`，用 Xcode 自带的 Icon Composer 打开修改，图层是 `Assets/` 里的 SVG；`scripts/bundle.sh` 用 `actool` 把它编成 `Assets.car` 和 `AppIcon.icns`，macOS 14、15 显示的平面图标也由 `actool` 从这份文件生成，不另外维护。

ADR 0002 规划的模块里，只有 `MCPServer`（`PasteMeMCP` target）还没建，等 #8 再建。

## 记录和全局快捷键

- `ClipboardMonitor` 只轮询剪贴板：发现变化后跳过 PasteMe 自己写入的内容和敏感内容，读出内容和来源应用，交给 `Recorder.record(_:from:)`。暂停时它连剪贴板都不读。
- `Recorder` 决定记不记录（暂停），入库后调用 `onRecord`。设置里打开了「复制时播放提示音」（#25）时，入库后、`onRecord` 之前先播放提示音（`RecordSoundPlaying`）；没有走到 `Recorder` 的内容（暂停、敏感内容、PasteMe 自己写入的）不会响。生产实现 `SystemRecordSound` 用系统音效服务播放，遵守系统设置里的「播放用户界面音效」；系统音效服务只能播放文件，所以 `RecordChime` 在代码里合成的声音（纸滑进剪贴板的夹子，4 个版本由 `TakeRotation` 轮流，不连续重复）在第一次播放时写成缓存目录里的 .wav。音色和响度是和用户试听十几轮选定的，否掉的方向写在 `RecordChime` 的注释里，改之前先试听。暂停只在内存里：`pausedUntil` 为 `.distantFuture` 表示直到手动恢复，定时暂停由 `Recorder` 自己的定时器到时恢复，`onPauseChange` 通知应用换菜单栏图标、显示提示。测试用注入的时钟（`RecorderTests`）。
- 菜单栏图标由 `AppDelegate.updateStatusIcon()` 决定：暂停记录优先，其次 Paste Stack。屏幕上的短暂提示用 `Toast`。
- 全局快捷键都通过 `HotKeyCenter.register(_:action:)` 注册。Carbon 会把每个快捷键事件发给所有已安装的处理器，所以只装一个处理器，读出事件里的快捷键 id 再分发；`HotKeyCenterTests` 直接调用 `dispatch` 模拟按键。
- 三个功能（`GlobalAction`）的组合存在 `Settings.shortcut(for:)`（#50）：没改过时是 `defaultCombo`，清除了是 nil（存成空字典）。`KeyCombo` 是键码加修饰键，在 Core 里，不引入 Carbon；Carbon 修饰键、菜单项的按键和「⇧⌘V」这样的符号在 `KeyComboDisplay.swift`，字符按当前键盘布局取（`UCKeyTranslate`），所以键码是物理位置，换了键盘布局显示的字符跟着变。`GlobalShortcuts` 按设置注册、改了以后重新注册，菜单栏菜单、暂停的 Toast、Paste Stack 浮窗每次用时从它读组合，不另存。
- 录制在设置窗口里：`SettingsWindow` 的本地事件监视器在录制时把窗口里的 keyDown 都交给 `SettingsModel.recordKey`（在主菜单之前收到，⌘W、⌘Q 也能录），esc 取消，⌫ 清除。录制开始时 `GlobalShortcuts.suspend()` 注销 PasteMe 自己的全部快捷键，不然按下现在的组合会被 Carbon 拦下、窗口收不到。检查规则在 `ShortcutRules.problem`（要带 ⌘⌃⌥、不能和另一项重复、不能是系统快捷键）。查不出和别的应用冲突：别的应用注册了同一个组合时 `RegisterEventHotKey` 照样成功，选项是 0 还是 `kEventHotKeyExclusive` 都一样（在 macOS 27 上试过），别的应用菜单里的快捷键更查不到；注册失败时（`GlobalShortcuts.failed`）设置页只说没有生效，不猜原因。系统快捷键用 `CopySymbolicHotKeys` 读：新的 SDK 不带它的头文件，`SystemShortcuts.current()` 用 `dlsym` 找到它，比较时只看 ⌃⌥⇧⌘（系统记的修饰键里还有 fn 位）。和面板里的按键相同时只提醒（`PanelKeymap.isUsedByPanel` 直接问按键映射）：全局快捷键在 PasteMe 自己是前台时也会先被拦下。

## Paste Stack

- `PasteStack`（Core）只管开关和顺序：`Recorder` 记下条目后调用 `push`，没开启时什么都不做；`takeNext` 取出最前面的一条，取完最后一条随之结束。
- `PasteStackController`（App）开启时创建 `KeyEventTap`（会话级 `CGEventTap`，只观察 keyDown，不拦截），按 `PasteStackKeys.action` 判断按键：⌘V 取下一条，esc 退出，其余不管。按住不放的重复按键、面板开着时的 ⌘V、PasteMe 自己发送的 ⌘V（`eventSourceUserData` 等于 `CGEventPasteKeystroke.marker`）都不取。
- 时机：事件监听在按键送到目标应用之前同步回调，回调里用 `Paster.copyToPasteboard` 把下一条写进剪贴板（带 `ownMarker`，不会再被记录），目标应用处理这次 ⌘V 时读到的就是它。所以不需要在 keyUp 之后延迟替换、猜测目标应用什么时候读完剪贴板。回调要快：系统会停掉太慢的监听（`KeyEventTap` 收到 `tapDisabledByTimeout` 时重新打开）。
- 结束时（手动退出或取完）在下一轮事件循环里移除监听，不在它自己的回调里移除。
- 浮窗（`PasteStackHUD`）的面板 `canBecomeKey` 为 false：点里面的按钮也不能抢走目标应用的键盘焦点，否则接下来的 ⌘V 会落在浮窗上。
- 监听别的应用的按键需要辅助功能权限，没有权限时 `CGEvent.tapCreate` 返回 nil，开启前先检查并提示。
- 按键判断在 `PasteStackKeysTests`，顺序和开关在 `PasteStackTests`。监听本身只能在真实应用里验证：开启后依次 `pbcopy` 几段文字，在文本编辑里连按 ⌘V。

## 附加信息

- `EnrichmentQueue` 依次运行一组 `Enricher`：图片中的文字（`TextRecognitionEnricher`）和链接预览（`LinkPreviewEnricher`）。每个 `Enricher` 在主线程从 `ClipStore` 读出输入（不需要处理时返回 nil），在后台算出结果，回到主线程写库（ADR 0003）。`Recorder` 记下图片、文件和链接后调用 `enqueue(id)`，改过网址的链接由 `HistoryModel.onEdited` 再交给它。启动 3 秒后 `AppDelegate` 调用 `backfill()` 补做旧图片的文字识别。队列一次只处理一个条目，新复制的排在前面，补做的每条之间停 0.5 秒。
- 图片中的文字：`VisionTextRecognizer` 自己用 `Task.detached` 切到后台。`ocr_text` 为 NULL 表示还没识别，空字符串表示识别过但没有文字或识别失败，以后不再识别。图片文件识别原文件，原文件不在了识别缩略图（缩略图只有 480 像素，效果差一些）。测试用 `FakeRecognizer`（`TextRecognitionTests.swift`），另有一个测试真的调用 Vision 识别画出来的中英文。
- 链接预览（#11）是 PasteMe 在后台联网的两个地方之一（另一个是每天检查一次更新，见「检查更新」；用户按空格预览网页也联网，见「预览和附属窗口」），默认关闭，分「只取网站图标」和「完整预览」两档（`Settings.linkPreviewMode`，`LinkPreviewEnricher` 每次读输入时重新读）。请求哪个网址由 `LinkPreviewPolicy.request(for:mode:)` 决定，先去掉分享时附带的跟踪参数（`withoutTracking`，否则 `si`、`share_id` 这类随机字符会被当成令牌）：本机、内网后缀、私有网段和 100.64.0.0/10、IPv6 字面地址、没有点的主机名都不请求；「只取网站图标」和看起来像一次性的网址（`looksSingleUse`：路径里的登录、重置、验证类词，像令牌的参数名，16 个以上字母数字混合的连续字符或 UUID）只请求网站首页。关闭和内网这两种情况都不做标记，打开后再复制一次就会获取。判断宁可多认：认错只少了网页标题，漏认可能让链接失效。
- 获取用 `HTMLPreviewFetcher`，不用 LinkPresentation：`LPMetadataProvider` 用 WebKit 加载整个网页，会加载页面上的资源、可能执行脚本。`HTMLPreviewFetcher` 用不带 Cookie、不缓存的 `URLSession` 只读 HTML，读到 `</head>` 为止（最多 2 MB），从 `og:title`、`twitter:title`、`<title>` 取标题，从 `og:image` 取预览图，从 `<link rel="apple-touch-icon"/"icon">` 和 `/favicon.ico` 取图标。不是网页的链接只看响应头不下载，图片链接用图片本身。每次请求带一个 `RedirectGuard`：重定向到内网地址不跟；打开复制的网址时，重定向到像一次性的网址也不跟（短链接跳到重置密码的链接），退回只取网站图标。只读 HTML 拿不到信息的网站在 `KnownSite` 里单独处理：Reddit 的网页要执行脚本才出内容，有的网络还整个被拦，帖子标题改从 oEmbed 接口取，其他页面从网址读出版块名，图标用固定地址。预览图缩成 480 像素存进 `thumbnail`，图标缩成 128 像素存进 `link_icon`（候选里有 `fluid-icon` 和惯例的 `/apple-touch-icon.png`，尽量拿到大图标）；只取网站图标时不存首页的标题，免得卡片把它当成这个链接的标题。`link_title` 和 `ocr_text` 的约定一样：NULL 是还没获取，空字符串是获取过（失败、没有标题或只取了图标），以后不再重试。旧链接不补做，免得打开开关后一下子发出很多请求。测试：`FakeLinkFetcher`（`LinkPreviewTests.swift`）测档位和规则，`StubURLProtocol`（`HTMLPreviewFetcherTests.swift`）给 `HTMLPreviewFetcher` 一个假的网络，测 Cookie、重定向、大小上限、编码和 Reddit 的 oEmbed。
- 有预览的链接卡片是海报样式（`LinkCardContent`）：居中的衬线标题（`EditorialFont`：New York，中文换成宋体，按字号缓存）和夹在细线中间的网站名，上面是预览图或带光晕的网站图标。没有网页标题时由 `LinkText` 从网址读出标题。图标的主色（`IconColor.dominant`）、四角是否透明由 `LinkIconCache` 按条目算一次；光晕不在运行时画，`LinkIconCache.posterIcon` 把圆角、白底、描边和光晕画成一张比图标大一圈的图，原因和标题栏图标一样（见「卡片外观」）。截图检查浅色外观时用 `PASTEME_SNAPSHOT_APPEARANCE=light`。
- 缩略图仍在 `ClipStore.insert` 里同步生成，没有移进队列：复制图片后卡片要马上能显示缩略图。

## 文本子类型、转换和代码着色

- **识别**（#26、#28）：`TextSubtype.detect(_:sourceBundleID:)` 是纯函数，只看整段内容（去掉首尾空白），按 颜色 > 时间戳 > hexdump > hex > Base64 > 代码 取第一个，超过 1 MB 不识别。各种写法的解析在 `TextFormats.swift`（`ColorValue`、`UnixTimestamp`、`ByteText`），识别和转换共用。容易误认的地方都有规则和反例测试（`TextSubtypeTests`）：纯十进制数字和 `cafe` 这样只有字母的词不是 hex，`12:30:45` 不是按字节分隔的 hex，驼峰命名的标识符和路径不是 Base64（`looksCamelCase`）。改规则时先加反例。
- **存储**：`clips.text_subtype`（第 7 级迁移，为什么不是新的类型见 ADR 0008）存 `TextSubtype.rawValue`（`base64`、`code:swift`），只有文本条目有：NULL 是还没识别，空字符串是识别过、不是任何子类型。`ClipStore.insert` 记录时算，`updateText` 改完重算；再次复制相同内容时，新的结果为空就保留原来的（同一段代码从编辑器复制时认得出语言，从别处复制时可能认不出）。升级前的文本条目由 `AppDelegate.backfillTextSubtypes` 在启动 3 秒后每批 100 条、间隔 0.2 秒补算（`ClipStore.backfillTextSubtypes`），不在迁移里算，免得历史很多时启动变慢。
- **筛选**：`ClipQuery.textSubtypes`（`.code` 用 `LIKE 'code:%'` 包含所有语言），`PanelFilters.subtypes`，`FilterSuggestion.subtype`。子类型没有常驻的按钮，从 `@` 选了才在类型按钮后面出现（`SubtypeChip`）。搜索框里的 `type:` 对得上类型时只按类型筛选，子类型都是文本，取并集只剩类型。
- **转换**（#27）：`TextConverter.options(for:subtype:)` 按子类型列出转换（做不了的带原因，菜单里照样列出），`convert` 做转换，都是纯函数（`TextConversionTests` 用本机 `hexdump -C`、`xxd -i` 的真实输出做期望值）。`HistoryModel.convert` 把结果当成 ⌘N 新建的文本那样记录（不记来源应用），再用 `showInHistory` 回到没有筛选的「历史」选中它，所以在 Pinboard 里或有筛选时也看得到。右键菜单里的「转换」是单独的视图（`ConversionMenuItems`），列出转换要读完整内容，只在菜单打开时做；⌘T 弹出同样内容的 `NSMenu`（`PanelController.showConversionMenu`），位置取 `CardDust` 记下的卡片布局，它的视图盖在卡片列表上，坐标一致。
- **哈希值**（#37、#49）：`HashAlgorithm.digest(of:)`（`Hashing.swift`）算 MD5、SHA-1、SHA-256（菜单按 `allCases` 的顺序列出，摘要从短到长），文本按 UTF-8 编码后的字节、不解码子类型，文件用 `FileHandle` 每次读 1 MB。`HistoryModel.computeHash` 在主线程读出输入，用 `Task.detached` 在后台算，回到主线程按转换的规则记录（`record`，和 `convert` 共用）。它不在 `TextConverter` 里：转换是同步的纯函数、有 1 MB 的上限，哈希值没有上限、文件可能很大。菜单里放在转换后面，文件卡片在右键菜单里。有文件夹的条目不列出这几项（`HistoryModel.offersHash`）：文件夹永远算不了，列出来只是几行灰字；文件不在了时照样列出，写明原因（`HashInput.unavailableReason`），用户以为能算，要知道为什么不行。
- **识别代码**（#28）：`CodeDetector` 只看前 4000 个字符、80 行，逐行比较字节，不用正则（release 下 15 行代码约 80 µs，一段散文约 13 µs）。顺序：确定的标记（shebang、`<?php`、`<?xml`、能解析的 JSON）→ 排除散文和 Markdown → HTML/XML、YAML → 按 `CodeSignals.swift` 的表给各语言打分。注释行不打分；C++、Objective-C 的分加在 C 上，TypeScript 加在 JavaScript 上；最高分要过门槛（编辑器 3、终端 4、其他 6）并且比第二名多 2 分。加一种语言：在 `CodeLanguage` 加一项（`rawValue` 存进数据库，不能改），在 `CodeSignals` 写只有它才有的写法，在 `LexerRules` 和 `Keywords` 写词法，再在 `CodeDetectorTests` 加正例和会混淆的反例。改规则后最好拿一批真实文字检查误认：例如把仓库里的文档按段落、源码按 15 行切开跑一遍，文档段落一条都不应该认成代码。
- **着色**：`SyntaxHighlighter.segments(of:language:)` 返回覆盖整段文字的片段。多数语言用 C 风格的 `Lexer`，只换 `LexerRules`；HTML/XML、CSS、JSON、YAML 各有自己的扫描。卡片只着色显示的部分：`CodeSnippet.displayText` 取前 11 行、tab 换成 4 个空格、去掉共同的缩进，`CodeSnippet.truncating` 把超出卡片宽度的部分截掉换成「…」（中日韩文字算两列）。不让文字超出卡片再靠圆角裁掉，原因和标题栏图标一样（见「卡片外观」）。`CodeHighlightCache` 按条目、预览文字、语言和深浅外观缓存 `AttributedString`；视图读 `colorScheme`，外观换了就取另一份。单张代码卡片从创建到画出来和普通文本卡片一样（release 下都约 8 ms，主要花在创建视图上）。

## Pinboard

- 数据：`pinboards`（名字、颜色、标签顺序）和 `pinboard_items`（Pinboard、条目、位置，`sort_order` 越小越靠前，新固定的放在最前）。固定的条目同时还是历史里的条目（为什么不另存一份见 ADR 0007），「历史」标签照常显示它（卡片底部有图钉）。再次复制已固定的条目只更新 `clips` 的时间，不动它在 Pinboard 里的位置。
- 查询：`ClipQuery.pinboardID` 是标签，`ClipStore.items(matching:)` 这时 JOIN `pinboard_items`、按位置排序，`ClipItem.pinOrder` 带着位置；`ClipQuery.inPinboards` 是筛选，只限定条目、不改排序。`HistoryModel.comesBefore` 按 `pinOrder` 排空位，所以删除动画在 Pinboard 里也把空位放回原来的格子（`DeleteAnimationScenarioTests` 里有 Pinboard 的场景和随机序列）。
- 删除：「历史」里 ⌘⌫ 删除条目，也从所有 Pinboard 里去掉；Pinboard 里 ⌘⌫ 只是移出（`ClipStore.unpin`）。两种都进 `HistoryModel.removals`，⌘Z 用 `restore` / `restorePin` 放回原来的位置。切换标签时撤销记录清空：撤销放回的卡片要在当前列表里才能播放聚拢的动画。
- `ClipStore.delete(id:)` 把整行按列名存进 `DeletedClip`，连同它在各个 Pinboard 里的位置，`restore` 原样插回去。以后给 `clips` 加列，撤销删除不用改。
- 清空历史（`ClipStore.clearHistory()`）只删除不在任何 Pinboard 里的条目。
- 自动清除（#34，`Settings.historyRetention`）：`AppDelegate.clearOldHistory` 在启动 3 秒后和之后每小时（和 `TemporaryFiles.removeExpired` 用同一个定时器）调用 `ClipStore.deleteUnpinned(before:)`，删除不在 Pinboard 里、`created_at` 早于期限的条目；`created_at` 在再次复制和粘贴时更新，所以按的是最后一次使用。面板开着时跳过这一次。不做 VACUUM，免得大数据库每小时卡一下。换成更短的期限、马上会删条目时，先用 `unpinnedCount(before:)` 数出来、弹窗确认。
- 标签：`HistoryModel.pinboardID` 为 nil 是「历史」，每次呼出面板回到「历史」。⌘← ⌘→（`PanelKeymap`，规则和 ← → 一样）和面板开着时的 ⇧⌘V（`PanelController.toggle`，没有 Pinboard 时仍是收起）循环切换。⌘P 固定到 `Settings.lastPinboardID`，没有 Pinboard 时请求新建。
- 新建、重命名、删除确认都在 `PinboardEditorController` 的小窗口里（见下一节），不用系统提示框：`NSAlert` 要激活 PasteMe，目标应用就不在前台了，关掉面板后 ⌘V 会落空。

## 预览和附属窗口

- 预览窗口（`PreviewController`，#10）和 Pinboard 编辑窗口（`PinboardEditorController`）都是 `AuxiliaryPanel`：和面板一样不激活 PasteMe、层级相同、`sharingType` 跟着面板（`PanelController.showsDuringScreenSharing`）。
- 键盘焦点：面板失去 key 时以前直接收起。现在附属窗口也会成为 key（输入标题、改正文），所以 `PanelController.keyMovedAway` 等这次切换做完（下一轮事件循环）再看 `NSApp.keyWindow`：还是面板或附属窗口就不收起，是 nil（去了别的应用）才收起。附属窗口关掉后 `takeKeyBack` 把 key 还给面板。
- 预览打开时不取得 key（`becomesKeyOnlyIfNeeded`，点图片和按钮不抢焦点，点进正文或标题才抢），所以面板上的空格、esc、← → 和 ↩ 照常起作用，预览跟着选中项换内容（`HistoryModel.onSelectionChange`）。
- 第一下点击：窗口不是 key 时，AppKit 默认只拿第一下点击让窗口成为 key，点到的视图收不到，要再点一下。面板和附属窗口在 `sendEvent` 里先调用 `NSWindow.takeKeyForFirstClick`：点到的视图接受第一下点击（`acceptsFirstMouse`）就照常交给它，窗口不抢键盘；不接受就先 `makeKey()`，这一下点击接着交给它。面板和预览的 SwiftUI 内容是 `FirstClickHostingView`，图片是 `FirstClickImageView`、`ZoomingScrollView`、`CenteringClipView`，网页是 `PreviewWebView`（它另外要成为 key，好让按键给网页）。但 SwiftUI 的按钮点中的是它里面不接受第一下点击的内部视图，预览照样会成为 key：所以点完以后第一响应者还是窗口自己（没有正文、标题框、网页、Quick Look 接过键盘）时，`AuxiliaryPanel.onClickWithoutKeyboard` 把键盘还给面板，空格和 ← → 照常作用于面板。Pinboard 编辑窗口不设它：失去 key 就会关掉。预览是 key 时点面板上的卡片也走这条路，第一下就选中。测试在 `FirstClickTests`：窗口要先上屏（`orderFrontRegardless`），`sendEvent` 才会分发点击。
- 预览开着时点面板的空白处关掉预览，分两块。搜索栏那一行、底部的留白：`HistoryView` 根视图背后垫了一层接单击的透明底（`HistoryModel.blankClicked`），控件和卡片在它前面，点中它们时轮不到它；右边的按键提示 `allowsHitTesting(false)`，点上去也算空白。卡片那一排被滚动区域挡着，这层底收不到：同一个本地事件监视器也收 leftMouseDown，点在面板上时用 `CardListClick.isBlank` 判断，在卡片那一排的高度以内、又不在任何一张卡片上（卡片按 `CardDust.frames` 的布局，只有选中的那张按放大 5% 后的大小算，其余按原大小，不然两张卡片之间只剩 6 点宽，很难点中）就关。点击照样交给面板。没用 SwiftUI 的手势：滚动区域会把空白处的点击吃掉，卡片的单击、双击和外面的单击也会互相抢。
- 预览是 key 时，按键由同一个本地事件监视器按 `event.window` 分给 `PreviewController.handle`（esc 关闭，输入法组字时除外），其余交给正文或标题。
- 修改在预览关闭、换内容或面板收起时保存（`PreviewState.markSaved` 先记下已保存，保存引起的重新查询再回来时不会存第二次）。正文是 `NSTextView`，有 RTF 的文本按富文本编辑、画在白底上（富文本常带黑色文字），其他按纯文本编辑；关掉了引号、破折号替换和拼写纠正。`ClipStore.updateText` 改完内容哈希会变，和另一条相同时合并（规则见它的注释和 `ClipEditingTests`）。
- 链接的预览显示网页（#52，`WebPreview.swift`）：`PreviewState.showsWebPage` 时（链接、不是 ⌘E 打开的编辑、`WebPreviewPolicy.start` 认得是 http/https）下面是 `WebPreviewPane`，否则仍是网址编辑器。`WebPreviewLoader` 持有唯一的 `WKWebView`，第一次预览链接时才建（要启动网页进程），之后复用。它用 `.nonPersistent()` 的数据存储，关掉预览时 `stop(clearingData:)` 再清一次，所以下次预览不是登录状态。打开预览马上加载，`follow` 换过来的等 `followDelay`（0.3 秒）再加载，期间换走就取消。这里和链接预览不同：是用户按了空格，所以不看「链接预览」设置、本机和内网地址也加载，只有 `looksSingleUse` 的链接等用户点「加载网页」。主框架里用户点的链接和新窗口交给 `NSWorkspace` 打开，页面自己跳到非网页地址（`zoommtg://`）拦下（`WebPreviewPolicy.navigation`），要下载的文件不下载。网页视图不主动取得键盘焦点，预览窗口照旧不是 key；点进网页后窗口成为 key，esc 由 `PreviewController.handle` 关闭预览，空格交给网页滚动。
- 预览顶上是一条 `PreviewLayout.barHeight` 高的窄栏，和窗口同一层玻璃、没有分隔线：左边标题输入框（没有标题时占位文字是网站、文件名或字数），右边这种内容的按钮和关闭，平时 `.tertiary`，鼠标进来是 `.secondary`。内容从窄栏下面开始，其余三边铺满。试过让控件做成浮在内容上的胶囊：Quick Look 显示的文本、网页的导航栏开头几行会被挡住，内容的边距又不归我们管，所以控件不叠在内容上。图片识别出的文字排在图片下面，也不叠。
- 窗口大小由 `PreviewLayout` 按内容算，都加上窄栏的高度，最小 360×220：网页用面板上方能用的整块地方（最宽是屏幕的 80%）；图片按比例缩进去、不放大；文本用 `boundingRect` 量出高度（太长的不量，直接用最大高度）。文件按类型（`content(forFileAt:)`）：图片按像素大小，256 KB 以内的文本和代码按 Quick Look 的等宽字体估高度，文件夹和应用是固定的小窗口，其余（PDF、视频）用整块地方。换内容（`follow`）时按新内容重新定大小。
- 几个文件的条目：`PreviewState.fileIndex` 是正在预览的文件，换条目时回到第一个还在的文件，`showFile(at:)` 超出两头时从另一头接着数。顶栏右边的切换器和 ⌥← ⌥→ 都走 `PreviewController.showFile`，换文件后按这个文件重新定大小。⌥← ⌥→ 在面板是 key 时由 `PanelKeymap`（`previewHasSeveralFiles`，搜索框里有文字时交给搜索框按词移动）处理，点进 Quick Look 以后由 `PreviewController.handle` 处理。
- 截图模式里 `PASTEME_SNAPSHOT_PREVIEW=1` / `PASTEME_SNAPSHOT_EDITOR=1` 把这两个窗口另存成图片。

## 窗口背景

- 面板、附属窗口、Paste Stack 浮窗和 Toast 的背景都由 `WindowBackground.make` 建（#41）：macOS 26 起是 Liquid Glass（`NSGlassEffectView`），之前是毛玻璃材质（`NSVisualEffectView`）。新加的浮动窗口也用它，版本分支只写在这一处。`@` 的候选列表画在面板里面，用 SwiftUI 的 `glassEffect`（`SuggestionListBackground`）。
- 玻璃只当背景：`make` 返回一个普通容器，下面是玻璃，上面是按同样圆角裁剪的内容，内容不放进玻璃的 `contentView`（原因见 `make` 的注释）。窗口的 `contentView` 因此不是 SwiftUI 内容的直接父视图，要用内容视图时自己留着引用（`AuxiliaryPanel.hosting`）。
- 截图模式用 `cacheDisplay` 画面板，画不出窗口后面的内容，截图里看不出玻璃的效果，要在真实屏幕上看。
- 玻璃跟着窗口是不是当前窗口（key 或 main）变：两样都不是时，玻璃里带 `vibrantColorMatrix` 滤镜的那层高光变成透明，像切到了别的应用。面板和附属窗口之间换键盘焦点时，`WindowActivity.keepActive` 把不是 key 的那个开着的窗口设成 main（`ClipPanel`、`AuxiliaryPanel` 都允许成为 main），两块玻璃都不变。时机：`WindowActivity.link` 让两种窗口在 `makeKey()`、`makeKeyAndOrderFront(_:)` 和点击的 `sendEvent(_:)` 里，`super` 返回以后调用它（`KeepsCompanionActive.onKeyChange`），`PanelController` 打开预览和编辑窗口后也调用一次。试过推迟到下一轮事件循环：中间那一帧有一个窗口两样都不是，两块玻璃先暗一下再亮回来，看起来在闪。也试过在「成为 key」的通知里设：太早，AppKit 发完通知还会调整 main，把它改掉。两种窗口自己是 key 时都不当 main（`canBecomeMain`），main 留给另一个。`NSGlassEffectView` 没有 `NSVisualEffectView.state` 那样的开关，SwiftUI 的 `appearsActive` 也改不了它，都试过。`WindowActivityTests` 读那层高光的不透明度来检查：窗口要先上屏，再转一下 run loop。
- 设置窗口是普通的有标题栏的窗口，不用 `WindowBackground`，外观照着 Alcove 的设置窗口：整个窗口铺一层侧栏材质（`WindowMaterial`，窗口不在前台时也透出桌面的颜色），侧栏和内容共用它，中间一条细线；分组是一层很淡的前景色加细边（`SettingsLayout`）。窗口带一个空的工具栏，标题栏和红绿灯是带工具栏窗口的尺寸，页面标题和红绿灯在同一行。

## 拖出卡片

- 卡片上的 `DragGesture` 第一次变化时调用 `HistoryModel.beginDrag`，`PanelController.beginDrag` 取 `NSApp.currentEvent`（这时是 leftMouseDragged）调用面板 `NSHostingView` 的 `beginDraggingSession`，之后鼠标交给 AppKit 的拖拽。用 AppKit 而不是 SwiftUI 的 `onDrag`：`onDrag` 只能给一个 `NSItemProvider`，几个文件的条目拖不出去。
- 拖的内容由 `Paster.draggingWriters(for:)` 生成，和粘贴时写进剪贴板的一样（`PasteboardCodec.writers`），图片总是附带 PNG 文件。文本是 `TextFilePromise`（#36）：一个 file promise，访达放下时才在目标文件夹写出 .txt；它同时提供文字和 RTF，其他应用照常拿到文字。拖拽开始时不知道会放到哪里，所以不能像粘贴那样按目标应用决定。
- 拖出面板时（`draggingSession(_:movedTo:)`）面板收起；在面板里时可以拖到 Pinboard 的标签上固定（`PinboardTabs` 的 `onDrop`），在 Pinboard 里拖到别的卡片上换位置（`ReorderDropDelegate` → `HistoryModel.moveDraggedCard`，拖拽结束时 `endDrag` 写进数据库）。这几处 `onDrop` 都只认 `HistoryModel.draggingID`，不解析拖拽的内容。

## 面板按键

`PanelKeymap.action(for:in:)` 是纯函数：输入按键（`PanelKey`）和面板状态（焦点、搜索词是否为空、能否撤销），输出要执行的面板命令，或者把按键交给搜索框。新的面板快捷键加在这里，并在 `PanelKeymapTests` 里写对应的用例。`PanelController.handle(_:)` 只负责把 `NSEvent` 转成 `PanelKey`、执行命令。

- 焦点（`HistoryModel.focus`）是唯一的状态来源，`HistoryView` 把它同步到搜索框的 `@FocusState`。呼出面板时焦点在卡片列表上。窗口第一次成为 key 时 AppKit 会自动让搜索框成为第一响应者，SwiftUI 随之把 `focus` 改成搜索框，所以 `PanelController.show()` 在 `makeKeyAndOrderFront` 之后把第一响应者交还给窗口本身。
- 焦点在卡片上时打字，需要让这次按键直接进入搜索框。本地事件监视器在事件分发之前回调，所以 `PanelController` 在监视器里同步把搜索框设为第一响应者，再把事件放行。搜索框是在视图层级里找到的第一个可编辑 `NSTextField`。
- 输入法组字时（搜索框的字段编辑器 `hasMarkedText()`），所有按键都交给输入法：↩、方向键和 esc 是用来选字和取消的。
- 删除时 `ClipStore.delete(id:)` 返回 `DeletedClip`（Pinboard 里是 `unpin` 返回 `UnpinnedClip`），`HistoryModel` 保存到面板关闭或切换标签为止，⌘Z 放回原来的 id、时间、缩略图和 Pinboard 里的位置。删除和撤销的动画见「删除动画」。
- 焦点在卡片上时空格打开、关闭预览（预览开着时 esc 也关闭它），⌘P、⌘N、⌘E、⌘J、⌘T、⌘O 在两种焦点下都起作用。
- ⌘O（#51）：`HistoryModel.openPlan(for:)` 读条目的完整内容（卡片的 `preview` 只有前 2000 个字符），交给 `OpenPlan.make` 决定每个网址用什么打开：链接用系统默认的浏览器，文件用 `Settings.fileApp`，文件夹用 `Settings.folderApp`（`OpenApp`：系统默认的方式、编辑器或终端，没装就按系统默认的方式），应用、.rtfd 这类文件包算文件。终端只接收文件夹，用终端打开文件时交给它的是文件所在的文件夹，几个文件在同一个文件夹里只开一次：终端会直接执行交给它的脚本。右键菜单的「打开方式」（`OpenWithMenuItems`）列出装了的应用，选了就把它同时当作文件和文件夹的打开方式，不改设置。文件都不在了只提示、面板不收起；否则 `onOpen` 由 `AppDelegate.open` 收起面板再用 `NSWorkspace` 打开，同一个编辑器的几个文件夹一次交给它。右键菜单的「打开」也用 `openPlan`，菜单项的文字（「在浏览器中打开」「用 Cursor 打开」）是 `OpenPlan.title`。⌘R、⌘C 只在焦点在卡片上时起作用，在搜索框里交给输入框（⌘C 拷贝选中的文字）。
- 在卡片标题栏里编辑标题（#33）是第三种焦点 `.title`：`HistoryModel.rename` 记下 `titleEditingID`，`HistoryView` 只给这一张卡片的标题栏放 `CardTitleField`（其他卡片的画法不变），它出现后自己取得第一响应者。`PanelKeymap` 这时只处理 ↩（保存）和 esc（取消），其余按键都交给输入框。焦点离开 `.title`（点进搜索框、点了别的卡片）、切换标签、卡片被筛选掉、面板收起都按保存处理；卡片的点击、双击和拖动在编辑时不起作用，免得点输入框时选中、粘贴或拖走卡片。开始编辑前先关掉预览，否则预览关闭时会把它记着的旧标题存回去。截图模式里 `PASTEME_SNAPSHOT_RENAME=1` 画出编辑标题时的面板。
- ⌘1…⌘9（#39）从最左边一张完整显示的卡片数起，卡片上的编号只在按住 ⌘ 时显示，两者用同一个起点（`HistoryModel.firstShortcutIndex`）。起点由 `HistoryView` 在卡片列表上用 `onGeometryChange` 按它在滚动区域里的位置算出（`firstFullyVisibleCard`），只在跨过一张卡片时写进 `HistoryModel.firstVisibleCard`；没按住 ⌘ 时视图不读它，滚动时卡片列表不用重新计算。这依赖卡片宽度和间距固定，和光标一样。呼出面板时滚回最前面，所以 ⌘1 还是最新的一条；只在上次滚到了后面时才滚（`HistoryView.scrolledPastFirst`），已经在最前面时再 `scrollTo` 一次，呼出动画的缺帧中位数多 1 帧左右。修饰键由 `PanelController` 的本地监视器收 `flagsChanged` 事件，规则在 `PanelKeymap.showsShortcutHints`；`HistoryModel.shortcutKeysChanged` 按住 0.2 秒后才显示（测试替换 `HistoryModel.schedule`）。编号从卡片下边缘外滑进来、滑回去，由卡片自己的 `.animation(_:value:)` 按有没有编号触发（`ShortcutHint.animation`），模型改状态时不用包 `withAnimation`，滚动时新进入或离开 ⌘1…⌘9 的编号也有动画。不能把动画挂在过渡上（`.transition(….animation(…))`）：那样只有透明度会动，位移直接跳到终点，`SwiftUIAssumptionTests.shortcutHintsSlideInAndOutOnTheirOwn` 检查这一点。编号盖在卡片底部右端，不改底部文字的排版。收起面板时已经显示的编号跟着面板滑出去，收起动画播完（`HistoryModel.panelDidHide`）才去掉，免得在收起或下次呼出的动画里淡出。截图模式里 `PASTEME_SNAPSHOT_HINTS=n` 画出往右选了 n 张、按住 ⌘ 时的面板。
- ⌘C（#35）用 `Paster.copyToPasteboard(_:touching: false)` 只写剪贴板，面板不收起，卡片也不动；`HistoryModel.copiedID` 记下最后拷贝的条目，`panelWillHide` 时才 `touch` 到历史最前。
- PasteMe 没有菜单栏，但 `AppDelegate.setUpMainMenu()` 设了一个不显示的主菜单：输入框的 ⌘X、⌘C、⌘V、⌘A、⌘Z 和 ⌘W 关闭窗口都要靠菜单项的快捷键才能用。

## 卡片外观

- 标题栏颜色由 `CardStyle(for:)` 决定：来源应用图标的代表色（`IconColor.dominant`，在 `PasteMeCore`，测试在 `IconColorTests`），找不到应用或图标全透明时用类型的颜色。图标和颜色都由 `AppIconCache` 按 bundle id 缓存，每个应用只算一次。
- 光标（`SelectionCursor`）不是每张卡片各画一个，而是在卡片列表上叠一层，按选中卡片的序号算出横向位置，所以选中项变化时能滑过去。这依赖卡片宽度固定（`ClipCardView.size`）和间距固定（`HistoryView.cardSpacing`）；改卡片布局时要同时改光标的位置计算。
- 光标的旋转和明暗变化由 `TimelineView` 逐帧驱动，面板收起后（`HistoryModel.isPanelVisible` 为 false）或开启「减少动态效果」时暂停，不在后台耗电。
- 标题栏图标比标题栏大、一部分被裁掉。这个裁切不能在运行时用 `.clipped()` 做：裁切超出范围的内容会让每张卡片在依次出现的动画里逐帧重新合成，#17 之后呼出面板时大约三分之一的帧赶不上 120 Hz。现在由 `AppIconCache.headerIcon` 把放大、阴影、裁切和卡片右上圆角一起画成一张正好标题栏右端大小的图片，所以标题栏高度固定为 `ClipCardView.headerHeight`。改标题栏的布局时要同时改 `headerIconSlice` 和 `headerIconFrame`。
- 文件卡片（`FileCardContent`）和链接卡片一样是海报样式，标题、细线中间的小字和顶上那片颜色是两者共用的 `PosterHeadline`、`PosterCaption`、`PosterGlow`。卡片上写的字由 `FileCardText` 按路径和文件信息算出，是纯函数（`FileCardTests`）。图片文件显示复制时的缩略图；别的文件有缩略图时（ImageIO 能打开的 PDF）显示成一页纸。
- 文件信息（类型、大小、文件夹的项数、图片的像素）要读文件系统，大文件夹、网络磁盘可能很慢，所以 `FileFacts.read` 只在后台调用，结果由 `FileFactsCache` 缓存。卡片第一次画某个路径时 `facts(for:)` 返回 nil，同一轮请求的路径一起读、一起写回，卡片先按路径写（类型取扩展名），读到后重画一次。面板每次呼出动画播完以后 `refresh()` 在后台重读，只写回变了的，所以文件被删掉以后下次打开面板就显示「已经不在原处」，平时打开面板卡片不会先空着再填上。
- 文件图标的光晕、灰掉的图标和那一页纸由 `FileIconCache` 预先画成图，原因和标题栏图标一样。普通文件的图标按类型缓存（`IconKey.type`），同一类文件共用一张；文件夹、文件包和扩展名不认识的文件可能有自己的图标，按路径缓存（`IconKey.path`）。还没读到文件信息时按扩展名猜，「v1.2」这样的文件夹读到以后才换成按路径的图标。
- 光标样式存在 `Settings.cursorStyle`，同时放一份在 `HistoryModel.cursorStyle`，让视图在设置窗口里切换后立即更新。
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
- `CardDust` 用 `ImageRenderer` 把卡片画成图（和面板一样的外观、按住 ⌘ 时的 ⌘n 和搜索命中），交给 `DustView` 播放。`DustView` 是盖在 `HistoryView` 根视图上的透明 `CAMetalLayer`，每个颗粒是一个实例，位置、大小、透明度都在着色器里按时间和序号算，主线程每帧只更新时间、提交一次绘制。节奏参数在 `DustTiming`。着色器源码在运行时编译（SwiftPM 不编译 .metal 文件），`PanelController.prewarm()` 启动时在后台编译；没编译好时删除不播放颗粒。
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
   │  ├─ .file（或设置了「图片以文件粘贴」）时 TemporaryFiles.imageFile 把图片存成 PNG
   │  ├─ 文本、目标是访达时 TemporaryFiles.textFile 存成 .txt（TextFile.name 起名）
   │  ├─ PasteboardWriting.write(content, attachingFile:)
   │  ├─ ClipStore.touch(id:)           # 移到历史最前；失败不影响这次粘贴
   │  └─ PasteKeystrokeSending.isTrusted ? sendPaste(to:) → .pasted : .copiedOnly
   └─ .copiedOnly 时 Accessibility.requestTrust()
```

- 发送 ⌘V 前的 0.08 秒延迟（等面板收起、键盘焦点回到目标应用）放在 `CGEventPasteKeystroke` 里，`Paster.paste` 本身是同步的，测试不需要等待。
- 有没有辅助功能权限，由按键 adapter 的 `isTrusted` 判断；弹出系统授权提示是应用层的事（`Accessibility`）。启动时先调用 `Accessibility.forgetStaleGrantIfNeeded`，再在没有授权时弹提示：签名变了以后列表里的旧条目失效，系统不会把新的 PasteMe 加进列表，要先用 `tccutil reset Accessibility <bundle id>` 删掉它（ADR 0011）。`tccutil` 按 bundle id 删掉全部记录、不看路径，所以要不要删由 `StaleGrant.action` 决定：只在没有授权、正在运行的就是 LaunchServices 登记的那一份（不是 DMG、App Translocation、`build/` 里试跑的副本）、而且这份 designated requirement 没处理过时才删；授权过的和清理成功过的 requirement 记在 `Settings.accessibilityRequirement`，用户自己关掉的开关不会被重置。`tccutil` 退出码不是 0 时写日志、不记下。
- 以文件粘贴和拖出图片生成的 PNG 放在 `~/Library/Caches/PasteMe/Files/<条目 id>/`（开发版是 `PasteMe Dev` 目录），文件名用复制时间。再次用到时只更新修改时间；`AppDelegate` 在启动 3 秒后和之后每小时调用 `TemporaryFiles.removeExpired()`，删除一天没用过的。
- `TargetApp` 在 `PanelController.show()` 时从前台应用取得。面板不激活 PasteMe，所以生产环境里 ⌘V 直接发给前台应用，发送按键用不到这个值。文本粘贴到访达时附带 .txt 文件（#36）靠它判断目标；粘贴到其他应用不附带文件，否则有的应用会把文本粘贴成附件。#13 的粘贴事件（记录粘贴到了哪个应用）也会用到它。

## Seam 和测试替身

| Seam | 生产实现 | 测试替身 |
| --- | --- | --- |
| `TextRecognizing` | `VisionTextRecognizer`（Core） | `FakeRecognizer`（`TextRecognitionTests.swift`） |
| `CardRemovalEffect` | `CardDust`（App） | `FakeRemovalEffect`（`FakeRemovalEffect.swift`） |
| `HistoryModel.animate` | `withAnimation` | 先检查视图可见的状态再执行（`PanelFlushTests`、`PanelSimulator`） |
| `CardDust.now`、`CardDust.schedule` | `CACurrentMediaTime`、`DispatchQueue.main.asyncAfter` | 虚拟时钟（`PanelSimulator`），配合 `DustView.advance()` 逐帧推进 |
| `HistoryModel.isInstalled`、`HistoryModel.pathKind`、`SettingsModel.isInstalled` | `NSWorkspace.urlForApplication`、`OpenPlan.pathKind(atPath:)` | 固定的结果（`OpenFromPanelTests`、`SettingsWindowTests`） |
| `SettingsModel.isReservedBySystem`、`failedShortcuts` | `SystemShortcuts`、`GlobalShortcuts.failed` | 固定的结果（`GlobalShortcutsTests`） |
| `AppNames(systemNames:)` | `AppBundleNames.names(ofBundleID:)`（Core，读已安装应用的本地化名字） | 固定的字典（`AppNamesTests`、`AppAliasesTests`） |
| `PasteboardWriting` | `GeneralPasteboard`（Core，`PasteboardCodec` 写 `NSPasteboard.general`） | `FakePasteboard`（`PasterTests.swift`） |
| `PasteKeystrokeSending` | `CGEventPasteKeystroke`（App） | `FakeKeystroke`（`PasterTests.swift`） |
| `RecordSoundPlaying` | `SystemRecordSound`（App） | `FakeSound`（`RecorderTests.swift`） |
| `LinkPreviewFetching` | `HTMLPreviewFetcher`（Core） | `FakeLinkFetcher`（`LinkPreviewTests.swift`） |
| `HTMLPreviewFetcher(configuration:)` | `HTMLPreviewFetcher.defaultConfiguration()` | 加上 `StubURLProtocol` 的配置（`HTMLPreviewFetcherTests.swift`） |
| `UpdateClient(configuration:latestURL:publicKey:)` | `UpdateClient.defaultConfiguration()`、GitHub 的 latest 接口、`UpdateSignature.publicKey` | `StubURLProtocol` 和测试里临时生成的钥匙（`UpdatesTests`） |
| `UpdateInstaller(app:)` | `Bundle.main.bundleURL` | 临时目录里用 `/usr/bin/true` 拼出来、临时签名的应用和 `hdiutil` 现做的 DMG（`UpdatesTests`） |
| `Updater(latest:)` | `UpdateClient.latest()` | 固定的回复（`UpdaterTests`） |
| `TemporaryFiles(directory:)` | `TemporaryFiles.defaultDirectory()` | 每个测试一个临时目录（`TemporaryFilesTests`） |
| `ClipStore(path:)` | `ClipStore.defaultPath()` | `ClipStore(path: ":memory:")` |
| `Settings(defaults:)` | 发布版的偏好域 `io.github.skjz.PasteMe`，开发版的 `io.github.skjz.PasteMe.dev`（`AppVariant`），取法见 ADR 0006、0009 | 每个测试一个随机名字的 suite，结束时删除 |

只在已经有两个实现（测试替身也算一个）并且有调用方时才加 seam（ADR 0002）。

## 扩展查询和设置

- **查询条件**：新的筛选字段加在 `ClipQuery` 上，转成 SQL 的代码也写在 `ClipQuery.swift` 的 `filter` 里，`ClipStore.items(matching:)` 不需要改。每个条件生成一段带括号的子句，多个条件用 AND 连接。搜索继续用 LIKE（ADR 0004），10,000 条条目时查询要在 50ms 以内（ADR 0003），`ClipFilterTests` 里有对应的测试。
- **筛选的来源**：面板上的按钮和菜单改 `HistoryModel.filters`（`PanelFilters`）；搜索框里的 `type:`、`app:` 由 `ClipQuery.parse` 解析，不回写到按钮上。搜索框末尾的 `@词`（`FilterMention`）弹出候选列表（`HistoryModel.suggestions`：`ClipKind.matching`、名字包含这段文字的 Pinboard，再加上 `AppNames.apps(matching:)`），选中后从搜索框里去掉这个词、写进 `filters`，所以显示在按钮上。有候选项时这个词不参与搜索；没有候选项或按 esc 关掉列表后，它按普通文字搜索。`HistoryModel.currentQuery` 把两者合起来，类型取交集（`ClipQuery.kinds` 为空集合时什么都不返回）。`query` 和 `filters` 改动后立即重新查询；`didShow` 一次清空两者，只查询一次，因为它在呼出动画的第一帧之前运行。
- **来源应用菜单**：用 AppKit 的 `NSMenu`，点开时才调用 `ClipStore.sourceApps()`，不在呼出面板时查询。
- **按应用的其他名字搜索**：条目只记了复制时的应用名（中文系统下是「访达」）。`HistoryModel.currentQuery` 最后调用 `ClipQuery.resolvingAppNames`，由 `AppNames` 找出名字、其他语言的名字（`AppBundleNames`，只读用户语言和英文）或应用别名（`Settings.appAliases`）包含搜索文字的应用，SQL 里加 `OR source_bundle_id IN (…)`。从应用包读名字一个应用要一两毫秒，所以启动 3 秒后 `AppNames.prefetch()` 在后台读完历史里的应用；应用列表在每次呼出面板时（`historyChanged()`）作废，第一次搜索时重新查。别名在设置窗口的「应用别名」页（`AppAliasesModel`）里编辑，输入时就保存，不需要通知 `AppNames`。
- **数据库迁移**：`ClipStore.migrate()` 按 `user_version` 逐级升级，每一级一个 `if` 块，最后设新的版本号。改表结构时加一级，并在 `ClipStoreMigrationTests` 里用上一版的表结构建库，确认旧数据还在。现在是第 7 级：4 加标题，5 加链接预览，6 加 Pinboard，7 加文本子类型。外键在每次打开数据库时用 `PRAGMA foreign_keys = ON` 打开，但删除条目和 Pinboard 时仍然显式删掉 `pinboard_items` 里的行，不只靠级联。
- **设置项**：所有开关都定义在 `Settings` 上，键名放在 `Settings.Key` 里。每个开关都写默认值测试和读写测试，参照 `SettingsTests`。
- **设置窗口**：开关的界面都在设置窗口里，菜单栏菜单只放打开历史、暂停记录、Paste Stack 这类操作。`SettingsModel` 读写 `Settings`，应用里要跟着变的地方（面板的 `sharingType`、`HistoryModel.cursorStyle` 等）通过它的 `on…` 回调通知，由 `AppDelegate.makeSettingsModel` 接上；会删条目的操作（换成更短的自动清除期限、清空历史）先放进 `pending…`，视图弹出确认后才执行。各页的视图在 `SettingsWindow.swift`，新开关加在对应的页里，在 `SettingsWindowTests` 里测读写和回调。窗口大小固定（`SettingsWindow.size`），侧栏自己画，不用 `NavigationSplitView`（原因见 `SettingsView` 的注释）。离屏检查排版可以在测试里用 `cacheDisplay` 画窗口的 `contentView?.superview`，但画不出材质；DEBUG 构建里 `PASTEME_SHOW_SETTINGS=<页>`（`SettingsModel.Page` 的 rawValue）启动后直接打开设置窗口，点不了菜单栏图标时用它在真实屏幕上看。

## 线程

`ClipStore` 只在主线程使用（ADR 0003）。`AppNames.prefetch()` 只把读应用包这一步放到后台（只用 Foundation 和 LaunchServices），结果回到主线程存进缓存。用到它的类型（`AppDelegate`、`HistoryModel`、`ClipboardMonitor`、`Paster`）都标了 `@MainActor`，测试这些类型的 suite 也要标 `@MainActor`。

## 在真实应用里验证

全局快捷键、面板、真正发送 ⌘V 这些行为，单元测试覆盖不到。改动涉及它们时，按下面的步骤运行应用确认。

1. 用 `pgrep -fl PasteMe` 检查用户是否已经开着 PasteMe（用户装在「应用程序」里的发布版也算）。两个实例会争抢全局快捷键（默认是 ⇧⌘V、⌃⇧⌘V、⌃⇧⌘C；开发版也可以在设置里改成别的，两边就不冲突了），复制的内容两边都会记录，需要先和用户确认能否退出。
2. 运行 `scripts/bundle.sh` 打包。打出的是开发版「PasteMe Dev」（ADR 0009），在辅助功能里和用户的 PasteMe 是两项，第一次要单独允许；用 Apple Development 证书签名时，权限在重新打包后仍然有效。SwiftPM 链接出的二进制把 SDK 版本记成和部署目标一样的 14.0，macOS 26 起系统会按旧设计运行它（旧的红绿灯、开关和菜单），所以 `bundle.sh` 链接时用 `-platform_version` 按真实的 SDK 版本声明并检查；`swift run`、`scripts/bench-panel.sh` 构建的二进制仍是旧设计。
3. 把 home 指向临时目录再启动，这样不会碰到用户真实的历史：

   ```bash
   open --env CFFIXED_USER_HOME="$TMPDIR/pasteme-home" build/PasteMe.app
   ```

   启动前先告诉用户会弹系统授权框。PasteMe 启动时没有辅助功能权限，就会请求一次（`AppDelegate` 里的 `Accessibility.requestTrust()`），只跑几秒、用临时 home 也一样；只有 `scripts/bench-panel.sh` 和截图模式在这之前就返回，不会弹。要用 `open` 启动，弹窗署名才是「PasteMe Dev」。从 shell 直接运行 `build/PasteMe.app/Contents/MacOS/PasteMe`、`swift run` 或 DMG 里的应用时，进程算在启动它的终端或 Claude 头上，弹窗写的是「“claude”想控制此 Mac 并访问你的数据」，用户会以为是 Claude 在要权限。通过 ssh 在另一台 Mac 上启动，也会在那台机器的屏幕上弹。

   历史数据库在 `$TMPDIR/pasteme-home/Library/Application Support/PasteMe Dev/history.sqlite`，可以用 `sqlite3` 直接查。拿用户历史的副本来测时，也要放进 `PasteMe Dev` 目录。不设 `CFFIXED_USER_HOME` 时，开发版用 `~/Library/Application Support/PasteMe Dev`，同样碰不到用户的历史。
   设置不随 `CFFIXED_USER_HOME` 隔离（cfprefsd 按真实用户读写），但开发版有自己的偏好域 `io.github.skjz.PasteMe.dev`，改不到用户的 PasteMe（`defaults read io.github.skjz.PasteMe.dev` 可以查看）。所有开发版实例共用这一份设置。
4. 用 `pbcopy` 造测试数据时加上 `LANG=en_US.UTF-8`。不设 `LANG` 时，含中文的内容会被写成空字符串，PasteMe 会直接跳过它。
5. 用截图检查时，面板可能不出现在截图里（例如 computer-use 只截授权应用的窗口）。这时看操作结果：目标应用里粘贴出的文字，以及数据库里条目的增删和顺序。
   要用计算机操作工具点 PasteMe 的窗口时：
   - 它只列出普通应用，找不到只在菜单栏里的 PasteMe。临时把 `Sources/PasteMe/main.swift` 的激活策略改成 `.regular` 再打包，验证完改回来，不提交。
   - 先 `defaults write io.github.skjz.PasteMe.dev showDuringScreenSharing -bool true`，截图里才有面板和预览窗口。
   - 全局快捷键只认真实的按键，要用全屏操作发。开发版可以先在设置里录一个和用户 PasteMe 不冲突的组合（工具不让发带 ⌘C、⌘V 的组合）。
   - 网页预览里的事件看不清时，起一个本机测试页，把 `wheel`、`click`、`keydown` 用 `fetch` 报回本机服务器，比看截图可靠：工具发出的「向下滚」到网页里是 `deltaY` 为负。
   - 验证完 `defaults delete io.github.skjz.PasteMe.dev`，改回激活策略。面板默认不出现在录屏里（`sharingType = .none`），请用户录屏反馈动画问题时，要先在设置窗口的「面板」页打开「共享屏幕时显示面板」，否则录到的只有面板后面的桌面。
6. 验证完在仓库根目录用完整路径退出测试实例，以免误关用户自己的 PasteMe：`pkill -f "$PWD/build/PasteMe.app/Contents/MacOS/PasteMe"`。然后删除临时目录。

## 检查更新

做法和为什么自己写、为什么要自己的签名见 ADR 0010。

- `AppDelegate` 在启动 10 秒后和每小时的定时器里调用 `Updater.checkIfDue()`：只有发布版、`Settings.checksForUpdates` 打开、距 `lastUpdateCheck` 满一天（`UpdateSchedule`）才真的查，查失败不记时间，下一个小时再试。手动检查（菜单栏菜单的「检查更新…」、设置「关于」页的「立即检查」）不看这些条件，结果都弹窗说。
- 自动检查查到的新版本放进 `Updater.available`，菜单栏菜单在 `menuWillOpen` 里据此显示「更新到 PasteMe x.y.z…」，再显示一次 Toast，不弹窗：PasteMe 在后台，弹窗会抢走用户正在打字的窗口。跳过的版本（`skippedUpdateVersion`）自动检查不再提示。
- `UpdateRelease.parse` 按名字找 `PasteMe-<版本>.dmg` 和 `.dmg.sig`，缺了就 `canInstall == false`：自动检查不提示，手动检查弹出「没有通过签名校验」的警告（`Updater.warnUnsigned`），不给下载页面；下载后签名对不上（`UpdateError.badSignature`）也一样。拿到 GitHub 发布权限的人可以故意不传或传错 `.sig`，要是这时让用户去下载页面，用户照着安装说明点「仍要打开」就绕过了校验。`canInstall` 只说明两个文件都在，不说明签名对，所以给用户手动安装的路都在验签之后：这台 Mac 换不了应用时（开发版、`UpdateInstaller.unavailableReason`：从 DMG 或 App Translocation 里运行、没有写权限），按钮是「下载安装包」，照样显示进度、验签，再用 `UpdateInstaller.inspect` 挂载检查里面的应用（和自动替换同一套 `check`：bundle id、版本和 tag 一样、`codesign`），都过了才由 `VerifiedDMG.keep` 放进「下载」文件夹并打开。哪一步失败都不打开发布页：签名只覆盖这一个 DMG，发布页上的别的文件没签过。应用不对（`unexpectedApp`，例如旧版本的签名包顶着新 tag）弹警告，其余失败只说稍后再试。弹窗里的发布说明去掉了链接：它出现在验签之前，文本视图里的链接一点就交给系统打开（`file://` 也行）。`.sig` 最多读 1 KB，解出来必须正好 64 字节；DMG 最多 200 MB，每读一个字节都检查。
- 安装：`Updater.step` 记着下载了多少（`UpdateClient.download` 每 64 KB 回报一次，回到主线程后只往前走）和是否在安装，`UpdateWindow` 按它显示进度条；下载时点取消或关窗口取消外面的 Task，`UpdateClient` 读每一块时检查取消，抛出 `CancellationError` 后窗口关掉、不提示；开始换应用以后不能取消。`UpdateClient.download` 验签后才写盘；`UpdateInstaller.install` 在后台挂载 DMG（`hdiutil`，macOS 27 上提示已弃用，但 macOS 14 没有替代的 `diskutil image`）、拷到同一个卷的临时目录、检查 bundle id、版本和 `codesign --verify`，再 `replaceItemAt`。之后 `Updater.relaunch` 交给 `/bin/sh` 等这个进程结束再 `open`，然后退出。`UpdatesTests` 里换应用的那个测试要现做 DMG、挂载两次，大约 9 秒。
