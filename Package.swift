// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "GTMSessionFetcher",
    platforms: [
        .macOS(.v10_10),
        .iOS(.v8),
        .tvOS(.v9),
        .watchOS(.v2)
    ],
    products: [
        .library(
            name: "GTMSessionFetcher",
            targets: ["GTMSessionFetcherCore", "GTMSessionFetcherFull"]
        ),
        .library(
            name: "GTMSessionFetcherCore",
            targets: ["GTMSessionFetcherCore"]
        ),
        .library(
            name: "GTMSessionFetcherFull",
            targets: ["GTMSessionFetcherFull"]
        ),
        .library(
            name: "GTMSessionFetcherLogView",
            targets: ["GTMSessionFetcherLogView"]
        )
    ],
    targets: [
        .target(
            name: "GTMSessionFetcherCore",
            path: "Source",
            sources:[
                "GTMSessionFetcher.h",
                "GTMSessionFetcher.m",
                "GTMSessionFetcherLogging.h",
                "GTMSessionFetcherLogging.m",
                "GTMSessionFetcherService.h",
                "GTMSessionFetcherService.m",
                "GTMSessionUploadFetcher.h",
                "GTMSessionUploadFetcher.m"
            ],
            publicHeadersPath: "SwiftPackage"
        ),
        .target(
            name: "GTMSessionFetcherFull",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Source",
            sources: [
                "GTMGatherInputStream.h",
                "GTMGatherInputStream.m",
                "GTMMIMEDocument.h",
                "GTMMIMEDocument.m",
                "GTMReadMonitorInputStream.h",
                "GTMReadMonitorInputStream.m",
            ],
            publicHeadersPath: "SwiftPackage"
        ),
        .target(
            name: "GTMSessionFetcherLogView",
            dependencies: ["GTMSessionFetcherCore"],
            path: "Source",
            sources: [
                "GTMSessionFetcherLogViewController.h",
                "GTMSessionFetcherLogViewController.m"
            ],
            publicHeadersPath: "SwiftPackage"
        ),
        .testTarget(
            name: "GTMSessionFetcherCoreTests",
            dependencies: ["GTMSessionFetcherFull", "GTMSessionFetcherCore"],
            path: "Source/UnitTests"
        )
    ]
)
