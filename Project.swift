import ProjectDescription

let project = Project(
    name: "Omabox",
    options: .options(defaultKnownRegions: ["en"], developmentRegion: "en"),
    settings: .settings(base: [
        "SWIFT_VERSION": "6.0",
        "SWIFT_STRICT_CONCURRENCY": "complete",
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
        "CODE_SIGN_STYLE": "Automatic",
        "DEVELOPMENT_TEAM": "4538W4A79B",
        "ARCHS": "arm64",
    ]),
    targets: [
        .target(
            name: "Omabox",
            destinations: .macOS,
            product: .app,
            bundleId: "ca.optimalapps.omabox",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Omabox/Info.plist"),
            resources: [
                .glob(pattern: "Omabox/Resources/**", excluding: ["Omabox/Resources/Guest", "Omabox/Resources/Guest/**"]),
                .folderReference(path: "Omabox/Resources/Guest"),
            ],
            buildableFolders: ["Omabox/Sources"],
            entitlements: .file(path: "Omabox/Omabox.entitlements"),
            dependencies: [
                .external(name: "Dependencies"),
                .external(name: "Sharing"),
                .external(name: "CasePaths"),
                .external(name: "IdentifiedCollections"),
                .external(name: "Tagged"),
                .external(name: "SwiftNavigation"),
                .external(name: "SwiftUINavigation"),
                .sdk(name: "Virtualization", type: .framework),
            ],
            settings: .settings(
                base: [
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
                ],
                configurations: [
                    .debug(name: "Debug"),
                    .release(name: "Release", settings: ["CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO"]),
                ]
            )
        ),
        .target(
            name: "OmaboxTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "ca.optimalapps.omabox.tests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            buildableFolders: ["OmaboxTests"],
            dependencies: [.target(name: "Omabox"), .external(name: "DependenciesTestSupport"), .external(name: "CustomDump")]
        ),
        .target(
            name: "OmaboxUITests",
            destinations: .macOS,
            product: .uiTests,
            bundleId: "ca.optimalapps.omabox.uitests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            buildableFolders: ["OmaboxUITests"],
            dependencies: [.target(name: "Omabox")]
        ),
    ],
    schemes: [
        .scheme(
            name: "Omabox",
            shared: true,
            buildAction: .buildAction(targets: ["Omabox"]),
            testAction: .targets(["OmaboxTests", "OmaboxUITests"], options: .options(coverage: true)),
            runAction: .runAction(configuration: "Debug")
        )
    ]
)
