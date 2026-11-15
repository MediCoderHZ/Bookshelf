// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Bookshelf",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bookshelf", targets: ["Bookshelf"])
    ],
    targets: [
        .executableTarget(
            name: "Bookshelf",
            path: "Bookshelf",
            exclude: [
                "Resources/Assets.xcassets",
                "Resources/PrivacyInfo.xcprivacy",
                "Support/Bookshelf.entitlements",
                "Support/Info.plist"
            ]
        ),
        .testTarget(
            name: "BookshelfTests",
            dependencies: ["Bookshelf"],
            path: "BookshelfTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
