// swift-tools-version: 6.2
import PackageDescription
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let nativeLibraries: [LinkerSetting] = [
    .unsafeFlags(["-L\(root)/build/lib", "-Xlinker", "-rpath", "-Xlinker", "\(root)/build/lib"]),
    .linkedLibrary("tailcat"),
]
var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.3.0"),
]
var targets: [Target] = [
    .systemLibrary(name: "CTailcat"),
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
    .target(name: "Tailcat", dependencies: ["CTailcat"], swiftSettings: [.swiftLanguageMode(.v6)], linkerSettings: nativeLibraries),
    .target(name: "CatflapCore", dependencies: ["Tailcat", "CSQLite", .product(name: "Crypto", package: "swift-crypto")], swiftSettings: [.swiftLanguageMode(.v6)]),
    .testTarget(name: "TailcatTests", dependencies: ["Tailcat", "CTailcat", .product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "CatflapCoreTests", dependencies: ["CatflapCore", "Tailcat", .product(name: "Crypto", package: "swift-crypto")]),
    .testTarget(name: "CatflapE2ETests", dependencies: ["CatflapCore", "catflap"]),
]
var executableDependencies: [Target.Dependency] = [
    "CatflapCore", "CTailcat", .product(name: "ArgumentParser", package: "swift-argument-parser"),
]
#if os(Linux)
targets += [
    .systemLibrary(name: "CGtk", path: "Sources/CGtk/GTK", pkgConfig: "gtk4", providers: [.apt(["libgtk-4-dev"])]),
    .systemLibrary(name: "CAdwaita", path: "Sources/CGtk/Adwaita", pkgConfig: "libadwaita-1", providers: [.apt(["libadwaita-1-dev"])]),
    .systemLibrary(name: "CGtkLayerShell", path: "Sources/CGtk/LayerShell", pkgConfig: "gtk4-layer-shell-0"),
    .systemLibrary(name: "CWayland", path: "Sources/CGtk/Wayland", pkgConfig: "wayland-client", providers: [.apt(["libwayland-dev"])]),
    .target(name: "CDataControl", dependencies: ["CWayland"], path: "Sources/CDataControl"),
    .target(name: "CGtkShim", dependencies: ["CGtk", "CAdwaita", "CGtkLayerShell", "CWayland"], path: "Sources/CGtkShim"),
    .target(name: "CatflapLinux", dependencies: ["CatflapCore", "CGtk", "CAdwaita", "CGtkLayerShell", "CWayland", "CDataControl", "CGtkShim"]),
    .testTarget(name: "CatflapLinuxTests", dependencies: ["CatflapLinux", "CatflapCore", "catflap"]),
]
executableDependencies.append("CatflapLinux")
#elseif os(macOS)
targets += [
    .target(name: "CatflapMac", dependencies: ["CatflapCore", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]),
    .testTarget(name: "CatflapMacTests", dependencies: ["CatflapMac"]),
]
executableDependencies.append("CatflapMac")
#endif
targets.append(.executableTarget(name: "catflap", dependencies: executableDependencies, linkerSettings: nativeLibraries))

let package = Package(
    name: "Catflap",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "catflap", targets: ["catflap"])],
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
