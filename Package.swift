// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TomTomSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TomTomKit", targets: ["TomTomKit"]),
        .executable(name: "ttsync", targets: ["ttsync"]),
    ],
    targets: [
        .target(
            name: "TomTomKit",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(name: "ttsync", dependencies: ["TomTomKit"]),
        .testTarget(
            name: "TomTomKitTests",
            dependencies: ["TomTomKit"],
            resources: [.copy("Resources")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
