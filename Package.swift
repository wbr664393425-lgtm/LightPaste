// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightPaste",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LightPaste", targets: ["LightPaste"])],
    targets: [
        .executableTarget(name: "LightPaste", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "LightPasteTests", dependencies: ["LightPaste"])
    ],
    swiftLanguageVersions: [.v5]
)
