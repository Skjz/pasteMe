// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PasteMe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PasteMe", targets: ["PasteMe"]),
    ],
    targets: [
        // 与界面无关的部分：数据模型、SQLite 存储、剪贴板内容的读写转换。
        .target(name: "PasteMeCore"),
        // 菜单栏应用本体：剪贴板监听、全局快捷键、历史面板。
        .executableTarget(
            name: "PasteMe",
            dependencies: ["PasteMeCore"]
        ),
        .testTarget(
            name: "PasteMeCoreTests",
            dependencies: ["PasteMeCore"]
        ),
    ]
)
