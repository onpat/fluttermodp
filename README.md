# fluttermodp

Flutter module player, Developed with Cline.

## Features

- Play tracker file with libopenmpt
  - background playback and control using JNI. (Foreground Service doesn't support dart FFI.)
  - generate buffer in C++ and playback it with Kotlin
  - configure playback speed, format, loop ...
- Control player with REST API (with internal HTTP server).
- Download module file from [ModArchive](https://modarchive.org/) and [AMP](https://amp.dascene.net/).
- auto build apk with Github Actions
- Only Android is supported

## Todo
- implement playback routine in C++ by using Oboe.
- Multi-language support
- iOS support
- better stability in AMP search
- More parameters for search

## Setup

1. Install and setup Flutter and android studio. create virtual device if needed.
2. open this repository.
3. run `flutter pub get` to fetch dependencies.

## Testing

Unit and widget tests are placed in the `test/` directory.

```sh
# Run all tests
flutter test

# Run a specific test file
flutter test test/widget_test.dart

# Run tests with coverage report
flutter test --coverage
```

You can also run static analysis to catch issues before building:

```sh
flutter analyze
```

## Build

The app has two product flavors defined in `android/app/build.gradle.kts`:

| Flavor | Package name | Purpose |
|--------|--------------|---------|
| `dev`  | `net.klovnin.fluttermodp.dev` | Development / CI builds |
| `prod` | `net.klovnin.fluttermodp`     | Release builds |

Run the app on a connected device or emulator with the desired flavor:

```sh
# Debug build (fast, with hot reload)
flutter run --flavor dev

# Profile build (for performance analysis)
flutter run --profile --flavor dev

# Release build (full optimization)
flutter run --release --flavor dev
```

## Creating an APK

Build an APK with the `flutter build apk` command. The flavor must be specified:

```sh
# Debug APK
flutter build apk --debug --flavor dev

# Release APK
flutter build apk --release --flavor dev
```

The generated APK is placed in:

- `build/app/outputs/flutter-apk/app-dev-debug.apk`
- `build/app/outputs/flutter-apk/app-dev-release.apk`

To reduce APK size, you can build separate APKs for each target ABI:

```sh
flutter build apk --release --flavor dev --split-per-abi
```

Note: release builds are signed with the keystore configured in `android/key.properties` (see `android/app/build.gradle.kts`). When building a release APK locally, create this file with your own keystore information (`storeFile`, `storePassword`, `keyAlias`, `keyPassword`). The official release APK is built and signed by GitHub Actions (`.github/workflows/flutter-build.yml`) using the keystore stored in repository secrets.
