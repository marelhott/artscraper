// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArtScraper",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ArtScraper", targets: ["ArtScraper"])],
    targets: [
        .executableTarget(
            name: "ArtScraper",
            path: "macos/Sources/ArtScraper"
        ),
        .testTarget(
            name: "ArtScraperTests",
            dependencies: ["ArtScraper"],
            path: "macos/Tests/ArtScraperTests"
        ),
    ]
)
