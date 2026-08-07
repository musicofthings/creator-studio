// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CreatorStudio",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "StudioDomain", targets: ["StudioDomain"]),
        .library(name: "StudioCapture", targets: ["StudioCapture"]),
        .library(name: "StudioProjectStore", targets: ["StudioProjectStore"]),
        .library(name: "StudioMediaPipeline", targets: ["StudioMediaPipeline"]),
        .library(name: "StudioAI", targets: ["StudioAI"]),
        .library(name: "StudioExport", targets: ["StudioExport"]),
        .executable(name: "studio-demo", targets: ["StudioCLI"]),
    ],
    targets: [
        .target(name: "StudioDomain"),
        .target(
            name: "StudioCapture",
            dependencies: ["StudioDomain"]
        ),
        .target(
            name: "StudioProjectStore",
            dependencies: ["StudioDomain", "StudioCapture"]
        ),
        .target(
            name: "StudioMediaPipeline",
            dependencies: ["StudioDomain"]
        ),
        .target(
            name: "StudioAI",
            dependencies: ["StudioDomain"]
        ),
        .target(
            name: "StudioExport",
            dependencies: ["StudioDomain", "StudioMediaPipeline"]
        ),
        .executableTarget(
            name: "StudioCLI",
            dependencies: [
                "StudioDomain",
                "StudioProjectStore",
                "StudioMediaPipeline",
                "StudioAI",
                "StudioExport",
            ]
        ),
        .testTarget(name: "StudioDomainTests", dependencies: ["StudioDomain"]),
        .testTarget(
            name: "StudioCaptureTests",
            dependencies: ["StudioDomain", "StudioCapture"]
        ),
        .testTarget(
            name: "StudioProjectStoreTests",
            dependencies: ["StudioDomain", "StudioCapture", "StudioProjectStore"]
        ),
        .testTarget(
            name: "StudioMediaPipelineTests",
            dependencies: ["StudioDomain", "StudioMediaPipeline"]
        ),
        .testTarget(
            name: "StudioAITests",
            dependencies: ["StudioDomain", "StudioAI"]
        ),
    ]
)
