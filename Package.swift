// swift-tools-version: 5.10
//
// Note — iPad handwriting app built with xtool (Linux / WSL) or Xcode.
//
// Targets
//   NoteApp    the app (SwiftUI + UIKit + PDFKit). xtool bundles this library product.
//   NoteKit    platform-neutral core: notebook format, library file system,
//              NAS clients (Synology File Station, WebDAV, Files-app folders), sync.
//              Builds and tests on Linux.
//   InkBridge  Swift wrapper over the note-core InkEngine C API.
//
// note-core is resolved in this order:
//   1. $NOTE_CORE_PATH            (a local checkout; the folder must be named `note-core`)
//   2. ../note-core               (sibling checkout, the recommended layout)
//   3. github.com/lemon7679/note-core, branch $NOTE_CORE_BRANCH (default `main`)
// NOTE_ENGINE_STUB=1 swaps InkBridge for a no-op stand-in so CI without access to
// the private engine can still type-check every app source file.
import Foundation
import PackageDescription

let environment = Context.environment
let useEngineStub = environment["NOTE_ENGINE_STUB"] == "1"

func noteCorePackage() -> Package.Dependency {
    if let path = environment["NOTE_CORE_PATH"], !path.isEmpty {
        return .package(path: path)
    }
    let sibling = URL(fileURLWithPath: Context.packageDirectory)
        .deletingLastPathComponent()
        .appendingPathComponent("note-core")
    if FileManager.default.fileExists(atPath: sibling.appendingPathComponent("Package.swift").path) {
        return .package(path: sibling.path)
    }
    return .package(
        url: "https://github.com/lemon7679/note-core.git",
        branch: environment["NOTE_CORE_BRANCH"] ?? "main"
    )
}

var packageDependencies: [Package.Dependency] = []
var bridgeDependencies: [Target.Dependency] = []
if !useEngineStub {
    packageDependencies.append(noteCorePackage())
    bridgeDependencies.append(.product(name: "InkEngine", package: "note-core"))
}

let package = Package(
    name: "NoteiPad",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool: exactly one library product, the app.
        .library(name: "NoteApp", targets: ["NoteApp"]),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(name: "NoteKit"),
        .target(
            name: "InkBridge",
            dependencies: bridgeDependencies,
            path: useEngineStub ? "Sources/InkBridgeStub" : "Sources/InkBridge"
        ),
        .target(
            name: "NoteApp",
            dependencies: ["NoteKit", "InkBridge"]
        ),
        .testTarget(
            name: "NoteKitTests",
            dependencies: ["NoteKit"]
        ),
    ]
)
