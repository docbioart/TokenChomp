// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "TokenChomp", platforms: [.macOS(.v13)],
    products: [.executable(name: "TokenChomp", targets: ["TokenChomp"])],
    targets: [.target(name: "ChompCore"),
              .executableTarget(name: "TokenChomp", dependencies: ["ChompCore"]),
              .testTarget(name: "ChompCoreTests", dependencies: ["ChompCore"])])
