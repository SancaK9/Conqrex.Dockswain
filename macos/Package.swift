// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Dockswain",
    platforms: [
        .macOS(.v13)            // MenuBarExtra needs macOS 13 (Ventura) or newer
    ],
    targets: [
        .executableTarget(
            name: "Dockswain",
            path: "Sources/Dockswain",
            resources: [
                // The SSH/docker helper is shipped next to the binary and located
                // at runtime via Bundle.module. Same role as the Linux dockswain.sh.
                .copy("Backend/dockswain-mac.sh")
            ]
        )
    ]
)
