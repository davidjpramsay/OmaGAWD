// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "OmaGAWD", platforms: [.macOS(.v14)], products: [.executable(name: "OmaGAWD", targets: ["OmaGAWD"])], targets: [.target(name: "OmaCore"), .executableTarget(name: "OmaGAWD", dependencies: ["OmaCore"], swiftSettings: [.swiftLanguageMode(.v5)]), .testTarget(name: "OmaCoreTests", dependencies: ["OmaCore"])])
