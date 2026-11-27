// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "swift-shader-compiler",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [.library(name: "Shader Compiler", targets: ["Shader Compiler"])],
    dependencies: [
        .package(url: "https://github.com/swift-molecules/swift-shader.git", branch: "main"),
        .package(url: "https://github.com/swift-standards/swift-metal-standard.git", branch: "main"),
        .package(url: "https://github.com/swift-w3c/swift-w3c-webassembly.git", branch: "main"),
        .package(url: "https://github.com/swift-w3c/swift-w3c-wgsl.git", branch: "main"),
        .package(url: "https://github.com/swift-atoms/swift-binary.git", branch: "main"),
        .package(url: "https://github.com/swift-atoms/swift-byte.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "Shader Compiler",
            dependencies: [
                .product(name: "Metal Standard", package: "swift-metal-standard"),
                .product(name: "Shader", package: "swift-shader"),
                .product(name: "W3C WebAssembly", package: "swift-w3c-webassembly"),
                .product(name: "W3C WGSL", package: "swift-w3c-wgsl"),
                .product(name: "Binary", package: "swift-binary"),
            ]
        ),
        .testTarget(
            name: "Shader Compiler Tests",
            dependencies: [
                .target(name: "Shader Compiler"),
                .product(name: "Byte", package: "swift-byte"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    target.swiftSettings =
        (target.swiftSettings ?? []) + [
            .strictMemorySafety(),
            .enableUpcomingFeature("ExistentialAny"),
            .enableUpcomingFeature("InternalImportsByDefault"),
            .enableUpcomingFeature("MemberImportVisibility"),
            .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            .enableUpcomingFeature("InferIsolatedConformances"),
            .enableExperimentalFeature("Lifetimes"),
            .treatAllWarnings(as: .error),
        ]
}
