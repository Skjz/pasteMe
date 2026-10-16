# 0005 MCP 服务手写 JSON-RPC，作为同一可执行文件的子命令，只读访问历史

日期：2026-10-16

工单 #8 的 MCP 服务不引入官方 Swift SDK，而是手写所需的少量 JSON-RPC 方法（`initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`），以保持 ADR 0001“不引入第三方依赖”的决定。第一版只有三个只读工具，协议面很小，自己实现的维护成本低于引入并跟进一个依赖。

- 运行方式：`PasteMe mcp` 子命令，通过 stdio 通信。用户在 AI 工具里配置的是应用包内的同一个可执行文件，不需要另装程序。
- 代码位置：协议逻辑在 `PasteMeMCP` 库里，以“一行请求进、一行响应出”的接口实现，可以直接用字符串测试；stdio 循环只是可执行文件里的一层 adapter。
- 数据访问：以只读方式打开 `history.sqlite`，遵守 `Settings` 里的“允许 AI 工具读取剪贴板历史”开关，开关关闭时拒绝所有请求。

## Considered Options

- 官方 Swift SDK：协议细节由 SDK 负责，将来加写操作、资源、提示词比较省事。若 MCP 功能扩展到需要这些能力，再写新 ADR 重新评估。
- 单独的 helper 可执行文件：要多维护一个 target 和打包步骤，没有实际好处。
