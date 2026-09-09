// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyCalendar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MyCalendar",
            path: "Sources/MyCalendar"
        )
    ]
)
