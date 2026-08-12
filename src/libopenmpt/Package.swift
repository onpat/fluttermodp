// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OpenMptNative",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        // A dynamic product keeps the C API visible to Dart's
        // DynamicLibrary.process() lookup on iOS.
        .library(name: "OpenMptNative", type: .dynamic, targets: ["OpenMptNative"]),
    ],
    targets: [
        .target(
            name: "OpenMptNative",
            path: ".",
            exclude: [
                "build",
                "contrib",
                "doc",
                "examples",
                "libopenmpt/in_openmpt",
                "libopenmpt/libopenmpt_test",
                "libopenmpt/plugin-common",
                "libopenmpt/xmp-openmpt",
                "openmpt123",
                "test",
                ".clang-format",
                "LICENSE",
                "Makefile",
                "README.md",
            ],
            sources: [
                "common",
                "libopenmpt",
                "sounddsp",
                "soundlib",
            ],
            publicHeadersPath: "swiftpm/include",
            cSettings: [
                .define("LIBOPENMPT_BUILD"),
                .define("LIBOPENMPT_BUILD_DLL"),
                .define("MPT_WITH_ZLIB"),
                .headerSearchPath("."),
                .headerSearchPath("common"),
                .headerSearchPath("src"),
            ],
            cxxSettings: [
                .define("LIBOPENMPT_BUILD"),
                .define("LIBOPENMPT_BUILD_DLL"),
                .define("MPT_WITH_ZLIB"),
                .headerSearchPath("."),
                .headerSearchPath("common"),
                .headerSearchPath("src"),
                .unsafeFlags(["-fexceptions", "-frtti", "-fvisibility=hidden"]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
