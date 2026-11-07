// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CatchWhatYouSee",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-app.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .target(name: "CaptureCore"),
        .target(name: "CaptureNative", dependencies: ["CaptureCore"]),
        .executableTarget(name: "CopySelectionFixture", path: "Tests/CopySelectionFixture"),
        .executableTarget(name: "CaptureCoreChecks", dependencies: ["CaptureCore", "CaptureNative"], path: "Tests/CaptureCoreChecks"),
        .executableTarget(name: "CatchWhatYouSee", dependencies: ["CaptureCore", "CaptureNative"], path: "Sources/Tendedero", exclude: ["Resources"])
    ]
)
