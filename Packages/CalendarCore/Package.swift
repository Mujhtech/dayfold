// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CalendarCore", targets: ["CalendarCore"]),
        .library(name: "CalendarPlatform", targets: ["CalendarPlatform"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        .package(url: "https://github.com/openid/AppAuth-iOS.git", exact: "3.0.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0")
    ],
    targets: [
        .target(name: "CalendarCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "CalendarPlatform", dependencies: ["CalendarCore", .product(name: "AppAuth", package: "AppAuth-iOS"), .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]),
        .testTarget(name: "CalendarCoreTests", dependencies: ["CalendarCore", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures")]),
        .testTarget(name: "CalendarPlatformTests", dependencies: ["CalendarPlatform", "CalendarCore", .product(name: "AppAuth", package: "AppAuth-iOS")])
    ]
)
