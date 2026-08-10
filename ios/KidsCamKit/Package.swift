// swift-tools-version:5.10
import PackageDescription

// KidsCamKit holds every piece of KidsCam that is pure logic: crypto, the wire
// formats pinned in `shared/protocol.md`, the pairing state machine and the REST
// client. Keeping it free of UIKit/AVFoundation means the whole security core is
// testable with `swift test` on any platform that has a Swift toolchain, not just
// on a machine with Xcode.
//
// On Apple platforms the crypto comes from CryptoKit. Elsewhere (Linux CI,
// `swift test` on a dev box) the identical API is provided by swift-crypto, which
// is only linked where CryptoKit does not exist.
let package = Package(
    name: "KidsCamKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "KidsCamKit", targets: ["KidsCamKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "KidsCamKit",
            dependencies: [
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows])
                )
            ]
        ),
        .testTarget(
            name: "KidsCamKitTests",
            dependencies: ["KidsCamKit"],
            resources: [
                // Symlink to `shared/test-vectors/kidscam-v1.json`. The vectors are
                // never copied into this tree — both implementations must load the
                // one normative file (see shared/protocol.md).
                .copy("Resources/kidscam-v1.json")
            ]
        )
    ]
)
