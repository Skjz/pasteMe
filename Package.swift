// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasteMe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PasteMe", targets: ["PasteMe"]),
    ],
    targets: [
        // 与界面无关的部分：数据模型、SQLite 存储、查询、粘贴流程、设置、剪贴板内容的读写转换。
        .target(name: "PasteMeCore"),
        // 菜单栏应用本体：剪贴板监听、全局快捷键、按键发送、历史面板。做成库是为了能测试面板逻辑。
        .target(
            name: "PasteMeApp",
            dependencies: ["PasteMeCore"]
        ),
        // 可执行文件，只有 main.swift。
        .executableTarget(
            name: "PasteMe",
            dependencies: ["PasteMeApp"]
        ),
        .testTarget(
            name: "PasteMeCoreTests",
            dependencies: ["PasteMeCore"]
        ),
        .testTarget(
            name: "PasteMeAppTests",
            dependencies: ["PasteMeApp", "PasteMeCore"]
        ),
    ]
)
