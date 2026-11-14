// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Vitals",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VitalsApp", targets: ["VitalsApp"]),
        .library(name: "VitalsCore", targets: ["VitalsCore"]),
        .library(name: "VitalsUI", targets: ["VitalsUI"]),
    ],
    targets: [
        // 采样与模型：不依赖任何 UI 框架，可被单测直接驱动。
        .target(name: "VitalsCore"),

        // SwiftUI 视图层：只依赖 VitalsCore，不知道数据从哪来。
        .target(name: "VitalsUI", dependencies: ["VitalsCore"]),

        // App 壳：菜单栏图标 + 悬浮窗，组装 VitalsUI。
        .executableTarget(name: "VitalsApp", dependencies: ["VitalsCore", "VitalsUI"]),

        // 本机 Command Line Tools 既不含 XCTest 也不含 swift-testing，
        // 所以测试是一个零依赖的可执行目标（scripts/test.sh 跑它）。
        .executableTarget(name: "VitalsCoreTests", dependencies: ["VitalsCore"], path: "Tests/VitalsCoreTests"),
    ],
    swiftLanguageModes: [.v5]
)
