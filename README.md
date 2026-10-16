# PasteMe

仿照 [Paste](https://pasteapp.io) 的 macOS 剪贴板管理工具。常驻菜单栏，记下你复制过的每一样东西，按 ⇧⌘V 从屏幕底部呼出历史，选中后直接粘贴到当前应用。

## 功能（0.1.0）

- 后台记录复制的文本、链接、图片和文件，保存在本地 SQLite，不限条数。
- 复制图片文件时，卡片直接显示图片缩略图。缩略图在复制时保存，原文件之后移走或删除也能看到。
- 同一内容再次复制不会重复记录，只把原记录移到最前。
- 自动跳过密码管理器等应用标记为“敏感”或“临时”的内容（`org.nspasteboard.ConcealedType` 等）。
- 共享屏幕、录屏和截图时，别人看不到面板，本机屏幕上照常显示。需要录教程时，在菜单栏菜单里打开「共享屏幕时显示面板」。这依靠 macOS 的窗口共享设置，个别录屏工具可能不遵守。
- ⇧⌘V 在鼠标所在屏幕底部呼出横向卡片面板，卡片显示类型、来源应用和复制时间。卡片标题栏取来源应用图标的颜色。选中的卡片稍微放大，外面有一圈发光的光标，随选中项在卡片之间滑动；光标样式可以在菜单栏菜单里选「呼吸」或「流光」。面板从屏幕底部滑入、卡片依次出现，收起时向下滑出；开启系统的「减少动态效果」后只做淡入淡出。
- 面板快捷键。面板上的焦点在搜索框或卡片列表上：呼出面板时在搜索框，按 ↓ 或点击卡片进入卡片列表，按 ↑ 或直接打字回到搜索框。编辑文字的按键只在焦点所在的地方起作用，在搜索框里按 ⌘⌫ 不会删掉记录。

  | 按键 | 作用 |
  | --- | --- |
  | 直接输入 | 搜索文本内容和来源应用名；`type:图片`、`app:微信` 按类型、来源应用筛选 |
  | ← → | 选择卡片（焦点在搜索框且已输入文字时，移动文字插入点） |
  | ↓ / ↑ | 焦点移到卡片列表 / 回到搜索框 |
  | ↩ / 双击 | 粘贴到当前应用 |
  | ⇧↩ | 以纯文本粘贴（去掉格式） |
  | ⌘1 … ⌘9 | 粘贴第 1 … 9 条 |
  | ⌘⌫ | 焦点在卡片列表时，删除选中的条目 |
  | ⌘Z | 焦点在卡片列表时，撤销删除（面板关闭前有效） |
  | esc | 清空搜索词和筛选；再按一次关闭面板 |

- 搜索栏旁边可以按类型（文本、链接、图片、文件，可多选）、来源应用和时间（今天、昨天、最近 7 天、最近 30 天）筛选，也可以在搜索框里输入 `type:图片`（或 `type:image`、`type:im`）和 `app:微信`。筛选条件之间、和搜索词之间同时生效；没有结果时会列出是哪些条件。每次呼出面板时清空。
- 暂停记录：按 ⌃⇧⌘V 立即暂停，再按一次恢复；也可以在菜单栏菜单里暂停 5 分钟、30 分钟或 1 小时，到时自动恢复。暂停时菜单栏图标带一道斜杠，切换时屏幕上会短暂提示。重启应用后总是从记录状态开始。
- 菜单栏菜单：暂停记录、登录时启动、共享屏幕时显示面板、查看辅助功能权限、光标样式、清空历史。

## 构建和运行

需要 macOS 14 及以上、Xcode 16 及以上（Swift 6）。

```bash
scripts/bundle.sh
```

```bash
open build/PasteMe.app
```

`scripts/bundle.sh` 编译 release 版本，打包成 `build/PasteMe.app` 并签名。默认使用钥匙串里第一个 “Apple Development” 证书；没有证书时用临时签名。

### 辅助功能权限

PasteMe 通过模拟按下 ⌘V 把内容粘贴到当前应用，这需要在「系统设置 → 隐私与安全性 → 辅助功能」里允许 PasteMe。没有授权时，选中的内容仍会写入剪贴板，手动按 ⌘V 即可。

用固定证书签名时，重新编译后权限保持有效；用临时签名（`PASTEME_SIGN_IDENTITY=-`）则每次重新编译都要在设置里删掉旧条目再重新授权。

### 数据位置

历史保存在 `~/Library/Application Support/PasteMe/history.sqlite`。删除这个文件即清空全部历史。

## 开发

```bash
swift test
```

```bash
swift run PasteMe
```

- `Sources/PasteMeCore`：与界面无关的部分，包括数据模型、SQLite 存储、查询条件（`ClipQuery`）、粘贴流程（`Paster`）、设置（`Settings`）、剪贴板内容的读写转换。测试在 `Tests/PasteMeCoreTests`。
- `Sources/PasteMeApp`：菜单栏应用本体，包括剪贴板轮询、全局快捷键、发送 ⌘V、面板和卡片视图。做成库是为了让面板逻辑也能测试，测试在 `Tests/PasteMeAppTests`。
- `Sources/PasteMe`：可执行文件，只有 `main.swift`，负责启动 `PasteMeApp` 里的 `AppDelegate`。
- 调试构建可以把面板渲染成图片后退出，用于在没有屏幕录制权限时检查界面：

  ```bash
  PASTEME_SNAPSHOT=/tmp/panel.png swift run PasteMe
  ```

代码分层、seam、测试替身，以及怎样在不碰真实历史的情况下运行应用验证改动，见 [docs/architecture.md](docs/architecture.md)。

架构决策记录在 [docs/adr/](docs/adr/)：

- [0001](docs/adr/0001-native-swift-package.md)：用 Swift Package 构建原生应用，不依赖第三方库。
- [0002](docs/adr/0002-deep-modules-and-targets.md)：模块划分和 target 结构，以及重构的推进顺序。
- [0003](docs/adr/0003-single-threaded-clip-store.md)：`ClipStore` 只在单线程使用。
- [0004](docs/adr/0004-like-search-not-fts.md)：搜索用 LIKE，暂不用 FTS5。
- [0005](docs/adr/0005-mcp-handwritten-json-rpc.md)：MCP 服务手写 JSON-RPC。
- [0006](docs/adr/0006-settings-defaults-domain.md)：设置的偏好域沿用 bundle id，在 .app 内用 `UserDefaults.standard` 读写。

术语（条目、Pinboard、Paste Stack 等）的定义见 [GLOSSARY.md](GLOSSARY.md)。

## 计划中

- Pinboard：把条目固定到自建分组，不受历史清理影响。
- 按顺序粘贴（Paste Stack）。
- 设置窗口：自定义快捷键、历史保留时长、忽略的应用。
- PDF、视频等非图片文件的缩略图（QuickLook）。
- 缩略图改用更小的编码以降低内存占用。
- iCloud 同步。
