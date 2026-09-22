// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CountdownMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CountdownMenuBar", targets: ["CountdownMenuBar"])
    ],
    targets: [
        .executableTarget(name: "CountdownMenuBar")
    ]
)
