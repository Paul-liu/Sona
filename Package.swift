// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sona",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Sona", targets: ["Sona"])
    ],
    targets: [
        .executableTarget(
            name: "Sona",
            path: "Sources/Sona",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AVKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("MediaPlayer"),
                .linkedFramework("WebKit"),
                .linkedFramework("Network")
            ]
        )
    ]
)
