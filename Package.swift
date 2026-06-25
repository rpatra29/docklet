// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Docklet",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Docklet",
            path: "Sources/Docklet",
            linkerSettings: [
                .linkedFramework("IOKit"),
                // Embed Info.plist into the executable so macOS can attribute the
                // Apple Events (automation) permission prompt + persist the grant.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
