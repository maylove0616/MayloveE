// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MayloveE",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter.git", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-java.git", exact: "0.23.5"),
    ],
    targets: [
        .executableTarget(
            name: "MayloveE",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterJava", package: "tree-sitter-java"),
            ],
            path: "Sources/MayloveE"
        ),
        .testTarget(
            name: "MayloveETests",
            dependencies: ["MayloveE"],
            path: "Tests/MayloveETests"
        ),
    ]
)
