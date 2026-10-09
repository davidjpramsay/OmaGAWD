// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OmaGAWD",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OmaGAWD", targets: ["OmaGAWD"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],
    targets: [
        .target(name: "OmaCore"),
        .executableTarget(name: "OmaGAWD", dependencies: ["OmaCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "OmaCoreTests", dependencies: ["OmaCore"]),
        .testTarget(name: "OmaGAWDTests", dependencies: ["OmaGAWD"], resources: [.copy("Fixtures")], swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
