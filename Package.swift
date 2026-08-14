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
        .executableTarget(
            name: "scrollwm",
            dependencies: [
                "ScrollCore",
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "ScrollCoreTests", dependencies: ["ScrollCore"]),
    ]
)
