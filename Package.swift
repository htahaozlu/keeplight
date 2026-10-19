// swift-tools-version: 6.0
import PackageDescription

// The app target is `KeeplightApp` (bundled as Keeplight.app/Contents/MacOS/Keeplight by
// scripts/bundle-app.sh) because `Keeplight` and `keeplight` collide on case-insensitive
// file systems, both as source directories and as build products. It is only the entry point;
// the UI lives in `KeeplightUI` so `keeplight-render` can draw it offscreen with fakes.
// `keeplight-render` is a debug-only developer tool and is never bundled (scripts/check-bundle.sh).
let package = Package(
    name: "Keeplight",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DisplayCore", targets: ["DisplayCore"]),
        .executable(name: "keeplight", targets: ["keeplight"]),
        .executable(name: "KeeplightApp", targets: ["KeeplightApp"]),
        .executable(name: "keeplight-render", targets: ["keeplight-render"]),
    ],
    targets: [
        .target(name: "CPrivateDisplay"),
        .target(
            name: "DisplayCore",
            dependencies: ["CPrivateDisplay"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit"),
            ]
        ),
        .target(name: "KeeplightUI", dependencies: ["DisplayCore"]),
        .executableTarget(name: "keeplight", dependencies: ["DisplayCore"]),
        .executableTarget(name: "KeeplightApp", dependencies: ["KeeplightUI"]),
        .executableTarget(name: "keeplight-render", dependencies: ["KeeplightUI", "DisplayCore"]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"]),
        .testTarget(name: "KeeplightUITests", dependencies: ["KeeplightUI"]),
    ]
)
