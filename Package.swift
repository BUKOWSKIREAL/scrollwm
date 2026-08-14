// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "scrollwm",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.0"),
    ],
    targets: [
        // 布局引擎：纯逻辑，无 AppKit 依赖，可单元测试
        .target(name: "ScrollCore"),
        // 合成器 mach 客户端（C，规避 Swift 无法导入的函数式 mach 宏）
        .target(name: "CClient"),
        .executableTarget(
            name: "scrollwm",
            dependencies: [
                "ScrollCore",
                "CClient",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ScrollCoreTests", dependencies: ["ScrollCore"]),
    ]
)
