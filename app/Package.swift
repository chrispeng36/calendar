// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyCalendar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MyCalendar",
            path: "Sources/MyCalendar",
            resources: [
                // 保留原始方向参考与照片资源；3D 跟随猫由连续网格实时渲染。
                .copy("../../Resources/pet9"),
                .copy("../../Resources/pet-base.png"),
                .copy("../../Resources/pet-head.png"),
                .copy("../../Resources/pet-body.png"),
                .copy("../../Resources/pet-eyes.png")
            ]
        )
    ]
)
