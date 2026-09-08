// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "FreemindCore", targets: ["FreemindCore"]),
    .executable(name: "freemind-helper", targets: ["FreemindHelper"])
]
var dependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
var platformTargets: [Target] = []

#if os(macOS)
products += [.executable(name: "Freemind", targets: ["Freemind"])]
dependencies += [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")]
platformTargets += [
    .target(name: "SwiftTerm", path: "Vendor/SwiftTerm/Sources/SwiftTerm",
            exclude: ["iOS", "Mac/README.md"], resources: [.process("Apple/Metal/Shaders.metal")]),
    .executableTarget(name: "Freemind", dependencies: ["FreemindCore", "SwiftTerm", .product(name: "Sparkle", package: "Sparkle")],
                      linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .testTarget(name: "FreemindTests", dependencies: ["Freemind"])
]
#else
dependencies += [.package(url: "https://github.com/apple/swift-crypto", exact: "4.5.2")]
coreDependencies += [.product(name: "Crypto", package: "swift-crypto"), "LinuxProcess"]
platformTargets += [.target(name: "LinuxProcess")]
#endif

let package = Package(
    name: "Freemind",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: platformTargets + [
        .target(name: "FreemindCore", dependencies: coreDependencies),
        .executableTarget(name: "FreemindHelper", dependencies: ["FreemindCore"]),
        .testTarget(name: "FreemindCoreTests", dependencies: ["FreemindCore", "FreemindHelper"])
    ],
    swiftLanguageModes: [.v5]
)
