// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cswitch",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Cswitch", targets: ["Cswitch"])],
    targets: [
        .target(name: "CswitchCore"),
        .executableTarget(name: "Cswitch", dependencies: ["CswitchCore"],
                          resources: [.copy("Resources/remote.py"), .copy("Resources/history.py")]),
        .testTarget(name: "CswitchCoreTests", dependencies: ["CswitchCore"]),
        .testTarget(name: "CswitchBackendTests", dependencies: ["Cswitch", "CswitchCore"])
    ],
    swiftLanguageModes: [.v5]
)
