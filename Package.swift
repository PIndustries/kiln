// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "Kiln",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "kiln", targets: ["Kiln"]),
        .executable(name: "kiln-example-backend", targets: ["ExampleBackend"]),
        .library(name: "KilnVault", targets: ["KilnVault"]),
        .library(name: "KilnKit", targets: ["KilnKit"]),
        .library(name: "KilnIngress", targets: ["KilnIngress"]),
        .library(name: "KilnRuntime", targets: ["KilnRuntime"]),
        .library(name: "KilnBastion", targets: ["KilnBastion"]),
        .library(name: "KilnTelemetry", targets: ["KilnTelemetry"]),
        .library(name: "KilnTerminal", targets: ["KilnTerminal"]),
        .library(name: "KilnSSH", targets: ["KilnSSH"]),
        .library(name: "KilnHTTP", targets: ["KilnHTTP"]),
        .library(name: "KilnWebSocket", targets: ["KilnWebSocket"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(name: "KilnKit"),
        .target(name: "KilnVault", dependencies: ["KilnKit", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "KilnIngress", dependencies: [.product(name: "NIOPosix", package: "swift-nio"), .product(name: "NIOConcurrencyHelpers", package: "swift-nio")]),
        .target(name: "KilnRuntime", dependencies: ["KilnKit", "KilnIngress", "KilnVault"]),
        .target(name: "KilnBastion", dependencies: ["KilnKit", .product(name: "SwiftTerm", package: "SwiftTerm"), .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "KilnTelemetry", dependencies: ["KilnKit"]),
        .target(name: "KilnCommands", dependencies: ["KilnVault", "KilnRuntime", "KilnKit", "KilnTelemetry", "KilnBastion"]),
        .target(name: "KilnTerminal", dependencies: ["KilnKit"]),
        .target(name: "KilnSSH", dependencies: ["KilnBastion", "KilnCommands", "KilnTerminal", .product(name: "NIOSSH", package: "swift-nio-ssh"), .product(name: "NIOPosix", package: "swift-nio"), .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "KilnHTTP", dependencies: [.product(name: "NIOHTTP1", package: "swift-nio")]),
        .target(name: "KilnWebSocket", dependencies: [.product(name: "NIOWebSocket", package: "swift-nio")]),
        .executableTarget(name: "Kiln", dependencies: ["KilnVault", "KilnKit", "KilnBastion", "KilnCommands", "KilnSSH", "KilnRuntime"]),
        .executableTarget(name: "ExampleBackend", dependencies: ["KilnKit", "KilnHTTP", "KilnWebSocket", .product(name: "NIOPosix", package: "swift-nio")]),
        .testTarget(name: "KilnTests", dependencies: ["KilnVault", "KilnKit", "KilnRuntime", "KilnCommands", "KilnTerminal", "KilnTelemetry", "KilnBastion"]),
    ]
)
