// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsage",
    platforms: [.macOS(.v14)],
    products: [
        // Pure value types. The sandboxed cmux sidebar extension links this and
        // nothing else, so it never carries credential-reading code.
        .library(name: "UsageModels", targets: ["UsageModels"]),
        // Credential access and provider HTTP. Daemon-only.
        .library(name: "UsageFetch", targets: ["UsageFetch"]),
        .executable(name: "aiusaged", targets: ["aiusaged"]),
        // Sets CLIProxyAPI routing weights from the daemon snapshot.
        .executable(name: "aiusage", targets: ["aiusage"]),
    ],
    targets: [
        .target(name: "UsageModels"),
        .target(name: "UsageFetch", dependencies: ["UsageModels"]),
        .executableTarget(name: "aiusaged", dependencies: ["UsageFetch", "UsageModels"]),
        .target(name: "ProxySteer", dependencies: ["UsageModels"]),
        .executableTarget(name: "aiusage", dependencies: ["ProxySteer", "UsageModels"]),
        .testTarget(name: "UsageFetchTests", dependencies: ["UsageFetch", "UsageModels"]),
        .testTarget(name: "ProxySteerTests", dependencies: ["ProxySteer", "UsageModels"]),
    ]
)
