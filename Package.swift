// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SMSBackupViewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SMSBackupViewer", targets: ["SMSBackupViewer"]),
        .executable(name: "smsbackup-mcp", targets: ["SMSBackupMCP"]),
        .library(name: "SMSBackupCore", targets: ["SMSBackupCore"]),
    ],
    targets: [
        .target(
            name: "SMSBackupCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "SMSBackupViewer",
            dependencies: ["SMSBackupCore"]
        ),
        .executableTarget(
            name: "SMSBackupMCP",
            dependencies: ["SMSBackupCore"]
        ),
        .testTarget(
            name: "SMSBackupCoreTests",
            dependencies: ["SMSBackupCore"]
        ),
    ]
)
