// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "Qlift",
    products: [
        .executable(name: "qlift-uic", targets: ["qlift-uic"]),
        .library(name: "Qlift", targets: ["Qlift"]),
    ],
    targets: [
        .target(name: "Qlift", dependencies: ["CQlift"]),
        .target(name: "CQlift", dependencies: ["CQt5Widgets"]),
        .systemLibrary(name: "CQt5Widgets", pkgConfig: "Qt5Widgets"),
        // Qt6 system library target.
        // Run scripts/generate_qt6_swift_module.sh to regenerate
        // Sources/CQt6Widgets/module.modulemap for your local Qt6 installation.
        .systemLibrary(
            name: "CQt6Widgets",
            pkgConfig: "Qt6Widgets",
            providers: [
                .apt(["qt6-base-dev"]),
                .brew(["qt6"]),
            ]
        ),
        .target(name: "qlift-uic")
    ],
    cxxLanguageStandard: .cxx1z
)
