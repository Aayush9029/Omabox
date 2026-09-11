// swift-tools-version: 6.1
import PackageDescription

#if TUIST
import struct ProjectDescription.PackageSettings
let packageSettings = PackageSettings(productTypes: [
    "Dependencies": .staticFramework,
    "Sharing": .staticFramework,
    "IdentifiedCollections": .staticFramework,
    "OrderedCollections": .staticFramework,
    "CasePaths": .staticFramework,
    "SwiftNavigation": .staticFramework,
    "SwiftUINavigation": .staticFramework,
    "Tagged": .staticFramework,
    "IssueReporting": .staticFramework,
])
#endif

let package = Package(name: "OmaboxDependencies", dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.17.1"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", exact: "2.10.0"),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", exact: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", exact: "1.10.0"),
    .package(url: "https://github.com/pointfreeco/swift-navigation", exact: "2.11.1"),
    .package(url: "https://github.com/pointfreeco/swift-tagged", exact: "0.10.0"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.7.3"),
])
