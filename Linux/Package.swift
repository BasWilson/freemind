// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "FreemindLinux",
    products: [.executable(name: "freemind-linux", targets: ["FreemindLinux"])],
    dependencies: [.package(name: "Freemind", path: "..")],
    targets: [
        .systemLibrary(name: "CVTE", pkgConfig: "vte-2.91-gtk4", providers: [.apt(["libgtk-4-dev", "libvte-2.91-gtk4-dev"])]),
        .systemLibrary(name: "CSourceView", pkgConfig: "gtksourceview-5", providers: [.apt(["libgtksourceview-5-dev"])]),
        .target(name: "LinuxUI", dependencies: ["CVTE", "CSourceView"]),
        .executableTarget(name: "FreemindLinux", dependencies: ["LinuxUI", .product(name: "FreemindCore", package: "Freemind")])
    ],
    swiftLanguageModes: [.v5]
)
