// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DiskCleaner",
    platforms: [.macOS(.v13)],
    targets: [
        // 新引擎：规则包、识别、估算、方案、执行、恢复区、审计
        .target(
            name: "CleanerCore",
            resources: [.copy("Engine/RulePack.json")]
        ),
        // CLI：scan / clean（预览与 --apply 执行）/ recovery（list / restore / purge）/ rules
        .executableTarget(
            name: "dclean",
            dependencies: ["CleanerCore"]
        ),
        // 界面状态与纯逻辑（不依赖 AppKit / SwiftUI），可单测
        .target(
            name: "AppCore",
            dependencies: ["CleanerCore"]
        ),
        // GUI 壳（AppKit + SwiftUI，窗口 + 菜单栏）：只渲染 AppModel 的状态、转发用户操作；不含任何删除逻辑
        .executableTarget(
            name: "DiskCleanerApp",
            dependencies: ["CleanerCore", "AppCore"]
        ),
        // 引擎单测（界面逻辑的单测在 AppCoreTests）
        .testTarget(
            name: "CleanerCoreTests",
            dependencies: ["CleanerCore"]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore", "CleanerCore"]
        ),
    ]
)
