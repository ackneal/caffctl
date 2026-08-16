// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "caffctl",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "CaffCtlCore",
            targets: ["CaffCtlCore"]
        ),
        .executable(
            name: "CaffCtlApp",
            targets: ["CaffCtlApp"]
        ),
        .executable(
            name: "caffctl",
            targets: ["CaffCtlCLI"]
        ),
        .executable(
            name: "CaffCtlTestsRunner",
            targets: ["CaffCtlTestsRunner"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CaffCtlCore",
            dependencies: [],
            path: "Sources/CaffCtlCore"
        ),
        .executableTarget(
            name: "CaffCtlApp",
            dependencies: ["CaffCtlCore"],
            path: "Sources/CaffCtlApp"
        ),
        .executableTarget(
            name: "CaffCtlCLI",
            dependencies: ["CaffCtlCore"],
            path: "Sources/CaffCtlCLI"
        ),
        .executableTarget(
            name: "CaffCtlTestsRunner",
            dependencies: ["CaffCtlCore"],
            path: "Sources/CaffCtlTestsRunner"
        ),
        .testTarget(
            name: "CaffCtlTests",
            dependencies: ["CaffCtlCore"],
            path: "Tests/CaffCtlTests",
            swiftSettings: [
                .unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
                ])
            ]
        ),
    ]
)
