// swift-tools-version:6.2
import PackageDescription

// CribWireKit holds every piece of CribWire that is pure logic: crypto, the wire
// formats pinned in `shared/protocol.md`, the pairing state machine and the REST
// client. Keeping it free of UIKit/AVFoundation means the whole security core is
// testable with `swift test` on any platform that has a Swift toolchain, not just
// on a machine with Xcode.
//
// On Apple platforms the crypto comes from CryptoKit. Elsewhere (Linux CI,
// `swift test` on a dev box) the identical API is provided by swift-crypto, which
// is only linked where CryptoKit does not exist.
let package = Package(
    name: "CribWireKit",
    platforms: [
        // Matches the app's floor (`ios/project.yml`).
        .iOS(.v26),
        // Deliberately *not* raised alongside iOS. macOS appears here only so
        // `swift test` runs on a dev machine and on the macOS CI runner; nothing
        // ships to macOS. Requiring macOS 26 would make the package refuse to
        // resolve on the `macos-15` runner in `.github/workflows/ios.yml` — a
        // self-inflicted CI failure with no product behind it.
        .macOS(.v13)
    ],
    products: [
        .library(name: "CribWireKit", targets: ["CribWireKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "CribWireKit",
            dependencies: [
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows])
                )
            ]
        ),
        .testTarget(
            name: "CribWireKitTests",
            dependencies: ["CribWireKit"],
            resources: [
                // Symlink to `shared/test-vectors/cribwire-v1.json`. The vectors are
                // never copied into this tree — both implementations must load the
                // one normative file (see shared/protocol.md).
                .copy("Resources/cribwire-v1.json")
            ]
        )
    ],
    // swift-tools-version 6.2 would otherwise default every target to the Swift
    // 6 language mode. Pinned to v5 to stay in step with SWIFT_VERSION in
    // `ios/project.yml`: the two must move to Swift 6 together, or the same
    // source file means different things depending on which builds it.
    swiftLanguageModes: [.v5]
)
