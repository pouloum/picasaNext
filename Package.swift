// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PicasaNext",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PicasaFormats", targets: ["PicasaFormats"]),
        .library(name: "PicasaCore", targets: ["PicasaCore"]),
        .executable(name: "picasa-cli", targets: ["picasa-cli"]),
        .executable(name: "PicasaNext", targets: ["PicasaViewer"]),
    ],
    targets: [
        // Pure parsers for Picasa 3.x on-disk data (.picasa.ini, contacts.xml, db3/PMP, thumbindex).
        .target(name: "PicasaFormats"),
        // Library: SQLite index, scanner, metadata, thumbnails, faces, Picasa import.
        .target(name: "PicasaCore", dependencies: ["PicasaFormats"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "picasa-cli", dependencies: ["PicasaCore"]),
        .executableTarget(name: "PicasaViewer", dependencies: ["PicasaCore"]),
        // Self-contained test runner: `swift run picasa-tests` (or `TESTS=1 ./build.sh debug`).
        .executableTarget(name: "picasa-tests", dependencies: ["PicasaCore"], path: "Tests/Runner"),
    ]
)
