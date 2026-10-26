// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpareKey",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SpareKey", targets: ["SpareKey"]),
        .library(name: "SpareKeyKit", targets: ["SpareKeyKit"]),
    ],
    targets: [
        .target(
            name: "SpareKeyKit",
            resources: [.copy("Data")],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ImageIO")]
        ),
        .executableTarget(name: "SpareKey", dependencies: ["SpareKeyKit"]),
        .testTarget(name: "SpareKeyKitTests", dependencies: ["SpareKeyKit"]),
    ]
)
