// swift-tools-version: 6.2
// Development build of the iOS app on Linux with xtool. `just ios-dev` syncs the
// sources in, builds, signs and installs. It carries no Metadata.appintents, so
// Shortcuts will not list the app's actions; the CI build is for that.
import PackageDescription

let package = Package(
    name: "TetherDev",
    platforms: [.iOS("26.1")],
    products: [
        // xtool builds `product: TetherApp` into the .app; the target keeps its own @main.
        .library(name: "TetherApp", targets: ["TetherApp"]),
    ],
    dependencies: [
        .package(path: "../TetherFramework"),
    ],
    targets: [
        .target(
            name: "TetherApp",
            dependencies: [.product(name: "TetherFramework", package: "TetherFramework")],
            path: "Sources/TetherApp",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("MemberImportVisibility"),
            ]
        ),
    ]
)
