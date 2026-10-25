# 开发 PasteMe

构建、测试、代码结构和数据位置。代码怎么分层、各处的 seam 和测试替身、怎样在不碰真实历史的情况下运行应用验证改动，见 [architecture.md](architecture.md)。

## 构建和运行

需要 macOS 14 及以上、Xcode 16 及以上（Swift 6）。

```bash
scripts/bundle.sh
```

```bash
open build/PasteMe.app
```

`scripts/bundle.sh` 编译 release 版本，打包成开发版 `build/PasteMe.app`（名字是 PasteMe Dev，见下面的「开发版」）并签名。默认使用钥匙串里第一个 “Apple Development” 证书；没有证书时用临时签名。发布用的 DMG 由 `scripts/make-dmg.sh` 打包，步骤见 [releasing.md](releasing.md)。

## 开发版

自己用 `scripts/bundle.sh` 打包的是开发版「PasteMe Dev」，和发布版的 PasteMe 互不影响（ADR 0009）：

- 在辅助功能里和发布版是两项，要分别允许。用固定证书签名时，重新编译后权限保持有效；用临时签名（`PASTEME_SIGN_IDENTITY=-`）则每次重新编译都要在设置里删掉旧条目再重新授权。
- 历史和缓存在 `~/Library/Application Support/PasteMe Dev` 和 `~/Library/Caches/PasteMe Dev`，设置在偏好域 `io.github.skjz.PasteMe.dev`。`swift run`、基准和测试也用这一套，碰不到你在用的 PasteMe。

发布版的数据位置见[使用说明](guide.md#数据存在哪里)。

## 测试

```bash
swift test
```

```bash
swift run PasteMe
```

- `Sources/PasteMeCore`：与界面无关的部分，包括数据模型、SQLite 存储、查询条件（`ClipQuery`）、粘贴流程（`Paster`）、设置（`Settings`）、剪贴板内容的读写转换。测试在 `Tests/PasteMeCoreTests`。
- `Sources/PasteMeApp`：菜单栏应用本体，包括剪贴板轮询、全局快捷键、发送 ⌘V、面板和卡片视图。做成库是为了让面板逻辑也能测试，测试在 `Tests/PasteMeAppTests`。
- `Sources/PasteMe`：可执行文件，只有 `main.swift`，负责启动 `PasteMeApp` 里的 `AppDelegate`。

## 截图模式

调试构建可以把面板渲染成图片后退出，用于在没有屏幕录制权限时检查界面：

```bash
PASTEME_SNAPSHOT=/tmp/panel.png swift run PasteMe
```

- `PASTEME_SNAPSHOT_QUERY='type:图片 报销'` 先在搜索框里输入这段文字，用来检查筛选和搜索结果。
- `PASTEME_SNAPSHOT_DELETE=1` 先删除选中的卡片，用来检查删除后其他卡片有没有移动。
- `PASTEME_SNAPSHOT_TAB=1` 切到第一个 Pinboard。
- `PASTEME_SNAPSHOT_PREVIEW=1`、`PASTEME_SNAPSHOT_EDITOR=1` 打开预览窗口、新建 Pinboard 的窗口，另存为 `<文件名>-preview.png`、`<文件名>-editor.png`。
- `PASTEME_SNAPSHOT_APPEARANCE=light` 或 `dark` 不管系统设置，按浅色或深色外观画。
- `PASTEME_SNAPSHOT_RENAME=1` 在选中卡片的标题栏里编辑标题；`PASTEME_SNAPSHOT_HINTS=n` 往右选 n 张，再当作按住了 ⌘，画出 ⌘1…⌘9。

截图模式画不出面板的半透明材质，背景是纯色的。

## 架构决策

记录在 [adr/](adr/)：

- [0001](adr/0001-native-swift-package.md)：用 Swift Package 构建原生应用，不依赖第三方库。
- [0002](adr/0002-deep-modules-and-targets.md)：模块划分和 target 结构，以及重构的推进顺序。
- [0003](adr/0003-single-threaded-clip-store.md)：`ClipStore` 只在单线程使用。
- [0004](adr/0004-like-search-not-fts.md)：搜索用 LIKE，暂不用 FTS5。
- [0005](adr/0005-mcp-handwritten-json-rpc.md)：MCP 服务手写 JSON-RPC。
- [0006](adr/0006-settings-defaults-domain.md)：设置的偏好域沿用 bundle id，在 .app 内用 `UserDefaults.standard` 读写。
- [0007](adr/0007-pinboard-shares-clip-rows.md)：Pinboard 引用历史里的条目，不另存一份。
- [0008](adr/0008-text-subtype-is-not-a-kind.md)：文本子类型不是新的类型，代码的语言也存在同一列。
- [0009](adr/0009-development-variant.md)：开发版用自己的 bundle id、偏好域和数据目录，和发布版互不影响。
- [0010](adr/0010-self-signed-updates.md)：自动更新的安装包用发布者自己的 Ed25519 钥匙签名。
- [0011](adr/0011-self-signed-release-certificate.md)：发布版用自签名证书「PasteMe Release」签名，启动时清掉失效的授权条目。

术语（条目、Pinboard、Paste Stack 等）的定义见 [GLOSSARY.md](../GLOSSARY.md)。
