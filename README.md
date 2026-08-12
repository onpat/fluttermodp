# fluttermodp

Flutter MOD playback using libopenmpt through Dart FFI.

The shared decoder source is located at `src/libopenmpt`. Android builds it as
`libopenmpt.so` with CMake. iOS builds the same source as the local
`OpenMptNative` Swift package and embeds its dynamic framework in the app.

At runtime, `lib/openmpt_ffi.dart` loads the module asset and renders signed
16-bit interleaved stereo PCM. `flutter_pcm_sound` queues that PCM to the native
audio output on Android and iOS.

```text
assets/cavern.mod
  -> Dart FFI
  -> libopenmpt
  -> PCM int16 stereo
  -> flutter_pcm_sound
  -> device audio output
```

Android can be built with `flutter build apk`. An iOS build requires macOS and
Xcode because the local Swift package compiles libopenmpt for the selected iOS
device or simulator architecture.
