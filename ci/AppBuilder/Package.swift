// swift-tools-version: 5.10
// CI only: links the NoteApp library into an executable the way xtool does
// (the library's @main supplies `main`), so the app can run in the iOS Simulator.
import PackageDescription

let package = Package(
    name: "NoteAppBuilder",
    platforms: [.iOS(.v17)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "NoteAppExec",
            dependencies: [.product(name: "NoteApp", package: "note-ipad")]
        ),
    ]
)
