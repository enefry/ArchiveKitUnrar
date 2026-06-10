// swift-tools-version:5.9

import PackageDescription

let package = Package(
  name: "ArchiveKitUnrar",
  platforms: [
    .iOS(.v15),
    .macCatalyst(.v15),
    .macOS(.v12)
  ],
  products: [
    .library(name: "ArchiveKitUnrar", targets: ["ArchiveKitUnrar"]),
  ],
  dependencies: [
    .package(path: "../ArchiveKit"),
    .package(url: "https://github.com/enefry/LoggerProxy.git", from: "2.0.0"),
    .package(url: "https://github.com/enefry/UnrarLib.git", branch: "main"),
  ],
  targets: [
    .target(
        name: "ArchiveKitUnrar",
        dependencies: [
            .product(name: "ArchiveKit", package: "ArchiveKit"),
            .product(name: "LoggerProxy",package: "LoggerProxy"),
            .product(name: "Unrar", package: "UnrarLib"),
        ],
        path: "unrar",
        linkerSettings: [
            .linkedFramework("Foundation"),
        ]
    )
  ]
)
