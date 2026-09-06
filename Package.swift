// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Freemind",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Freemind", targets: ["Freemind"]),
               .executable(name: "freemind-helper", targets: ["FreemindHelper"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")],
    targets: [
        .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources/SwiftTerm",
                exclude: ["iOS", "Mac/README.md"], resources: [.process("Apple/Metal/Shaders.metal")]),
        .target(name: "FreemindCore"),
        .executableTarget(name: "Freemind", dependencies: ["FreemindCore", "SwiftTerm", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "FreemindHelper", dependencies: ["FreemindCore"]),
        .testTarget(name: "FreemindCoreTests", dependencies: ["FreemindCore"])
    ],
    swiftLanguageModes: [.v5]
)
