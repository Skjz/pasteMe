# 0002 按七个深模块组织代码，应用本体移入 PasteMeApp 库

日期：2026-10-16

对照工单 #1–#13 检查现有代码，发现改动会集中在几处浅接口上：粘贴流程写在 `AppDelegate`；剪贴板轮询和“记不记录”的判断混在一起；`ClipStore.recent` 只接受一个搜索字符串；`HotKey` 不支持多个快捷键；面板按键无条件拦截；没有统一的设置。如果不调整，每个工单都要在这些地方各自加分支，调用方之间也会重复。因此决定：在多个工单都会改动的地方，用小接口把复杂度收进下面七个模块，测试也从这些接口进行。

| 模块 | 接口要点 | 隐藏的复杂度 | 主要服务的工单 |
| --- | --- | --- | --- |
| `ClipQuery` + `ClipStore.items(matching:)` | 一个查询值类型；搜索框语法解析为它 | SQL 拼接、转义、搜索哪些列、Pinboard 范围 | #4 #8 #9，以及 #5 #10 #11 新增的可搜索字段 |
| `Recorder` | `record(content, from:)`、`pause(until:)` | 暂停、忽略的应用、入库、触发附加信息处理、通知 Paste Stack | #5 #6 #7 #11 |
| `EnrichmentQueue` + `Enricher` | `enqueue(id)`、`backfill()`；每种附加信息一个 `Enricher` | 处理状态、后台执行后回主线程写库、补做旧条目、限速、隐私开关 | #5 #11，以及文件缩略图 |
| `Paster` | `paste(id, as: mode, into:)` | 读取完整内容、按模式变换、写剪贴板、移到最前、记录粘贴事件、发送 ⌘V | #6 #12 #13 |
| `PanelKeymap` | 按键 + 面板上下文 → 面板命令（或交给搜索框） | 焦点规则（见工单 #1 的决定） | #1 #2 |
| `HotKeyCenter`、`Settings` | 注册快捷键并按 id 分发；集中定义所有开关 | Carbon 事件分发；`UserDefaults(suiteName: "io.github.skjz.PasteMe")`，应用和 MCP 子进程共用 | #3 #6 #7 #8 #11 #12 #13 |
| `MCPServer` | 一行 JSON-RPC 请求进，一行响应出 | 协议方法、工具定义、只读访问历史（见 ADR 0005） | #8 |

Target 结构：

- `PasteMeCore`：模型、`ClipStore`（含迁移）、`ClipQuery`、`Recorder`、`EnrichmentQueue` 及其 Vision / LinkPresentation adapter、`Paster`、Paste Stack 的核心逻辑、`Settings`、`PasteboardCodec`、`Thumbnailer`。
- `PasteMeMCP`：MCP 协议，依赖 Core。
- `PasteMeApp`：AppKit / SwiftUI 部分，包括剪贴板轮询、`HotKeyCenter`、监听 ⌘V 的 event tap、按键发送、面板、`PanelKeymap`、视图。
- `PasteMe`：可执行文件，只有 `main.swift`，参数为 `mcp` 时启动 MCP 服务，否则启动应用。

应用代码从可执行 target 移进 `PasteMeApp` 库，是为了让面板逻辑也能被测试（`PasteMeAppTests`）。

## 推进顺序

先做一次重构，建立几乎每个工单都会用到的部分：拆出 `PasteMeApp`，抽出 `ClipQuery`、`Paster`、`Settings`。其余模块等第一个用到它的工单再建：`Recorder` 随 #7，`EnrichmentQueue` 随 #5，`HotKeyCenter` 随 #7，Paste Stack 随 #6，`MCPServer` 随 #8。不提前建只有一个实现、还没有调用方的 seam。

## Considered Options

- 一次搭好七个模块的空架子：接口会在做真实功能时返工，且会出现暂时无人使用的 seam。
- 不单独重构、各工单顺手改：前几个工单改动过大，并行开发时会在 `AppDelegate` 和 `ClipStore` 上冲突。
