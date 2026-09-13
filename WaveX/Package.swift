// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WaveX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WaveX",
            path: "Sources/WaveX",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
