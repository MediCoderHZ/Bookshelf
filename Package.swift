// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Bookshelf",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bookshelf", targets: ["Bookshelf"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "Bookshelf",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Bookshelf",
            exclude: [
                "Resources/Assets.xcassets",
                "Resources/PrivacyInfo.xcprivacy",
                "Support/Bookshelf.entitlements",
                "Support/Info.plist"
            ],
            resources: [.copy("Resources/ThirdPartyNotices.txt"), .copy("Resources/relaunch.sh"),
                        .process("Resources/zh-Hans.lproj"), .process("Resources/en.lproj")]
        ),
        .testTarget(
            name: "BookshelfTests",
            dependencies: ["Bookshelf"],
            path: "BookshelfTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
