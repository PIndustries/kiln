// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "Kiln",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kiln", targets: ["Kiln"]),
        .executable(name: "kiln-example-backend", targets: ["ExampleBackend"]),
        .library(name: "KilnKit", targets: ["KilnKit"]),
        .library(name: "KilnRuntime", targets: ["KilnRuntime"]),
        .library(name: "KilnSSH", targets: ["KilnSSH"]),
        .library(name: "KilnHTTP", targets: ["KilnHTTP"]),
        .library(name: "KilnWebSocket", targets: ["KilnWebSocket"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "KilnKit"),
        .target(name: "KilnRuntime", dependencies: ["KilnKit"]),
        .target(name: "KilnCommands", dependencies: ["KilnRuntime", "KilnKit"]),
        .target(name: "KilnSSH", dependencies: ["KilnCommands", .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "KilnHTTP", dependencies: [.product(name: "NIOHTTP1", package: "swift-nio")]),
        .target(name: "KilnWebSocket", dependencies: [.product(name: "NIOWebSocket", package: "swift-nio")]),
        .executableTarget(name: "Kiln", dependencies: ["KilnCommands", "KilnSSH", "KilnRuntime"]),
        .executableTarget(name: "ExampleBackend", dependencies: ["KilnKit", "KilnHTTP", "KilnWebSocket", .product(name: "NIOPosix", package: "swift-nio")]),
        .testTarget(name: "KilnTests", dependencies: ["KilnKit", "KilnRuntime", "KilnCommands"]),
    ]
)
