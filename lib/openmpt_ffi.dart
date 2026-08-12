import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart' show rootBundle;

final class _OpenMptModule extends Opaque {}

typedef _CreateModuleNative =
    Pointer<_OpenMptModule> Function(
      Pointer<Void> fileData,
      Size fileSize,
      Pointer<Void> logFunction,
      Pointer<Void> logUser,
      Pointer<Void> errorFunction,
      Pointer<Void> errorUser,
      Pointer<Int32> error,
      Pointer<Pointer<Utf8>> errorMessage,
      Pointer<Void> initialControls,
    );
typedef _CreateModuleDart =
    Pointer<_OpenMptModule> Function(
      Pointer<Void> fileData,
      int fileSize,
      Pointer<Void> logFunction,
      Pointer<Void> logUser,
      Pointer<Void> errorFunction,
      Pointer<Void> errorUser,
      Pointer<Int32> error,
      Pointer<Pointer<Utf8>> errorMessage,
      Pointer<Void> initialControls,
    );

typedef _DestroyModuleNative = Void Function(Pointer<_OpenMptModule> module);
typedef _DestroyModuleDart = void Function(Pointer<_OpenMptModule> module);

typedef _RenderStereoNative =
    Size Function(
      Pointer<_OpenMptModule> module,
      Int32 sampleRate,
      Size frameCount,
      Pointer<Int16> samples,
    );
typedef _RenderStereoDart =
    int Function(
      Pointer<_OpenMptModule> module,
      int sampleRate,
      int frameCount,
      Pointer<Int16> samples,
    );

typedef _GetStringNative = Pointer<Utf8> Function(Pointer<Utf8> key);
typedef _GetStringDart = Pointer<Utf8> Function(Pointer<Utf8> key);

typedef _GetMetadataNative =
    Pointer<Utf8> Function(Pointer<_OpenMptModule> module, Pointer<Utf8> key);
typedef _GetMetadataDart =
    Pointer<Utf8> Function(Pointer<_OpenMptModule> module, Pointer<Utf8> key);

typedef _GetDurationNative = Double Function(Pointer<_OpenMptModule> module);
typedef _GetDurationDart = double Function(Pointer<_OpenMptModule> module);

typedef _FreeStringNative = Void Function(Pointer<Utf8> value);
typedef _FreeStringDart = void Function(Pointer<Utf8> value);

class _OpenMptBindings {
  _OpenMptBindings() : library = _loadLibrary() {
    createModule = library
        .lookupFunction<_CreateModuleNative, _CreateModuleDart>(
          'openmpt_module_create_from_memory2',
        );
    destroyModule = library
        .lookupFunction<_DestroyModuleNative, _DestroyModuleDart>(
          'openmpt_module_destroy',
        );
    renderStereo = library
        .lookupFunction<_RenderStereoNative, _RenderStereoDart>(
          'openmpt_module_read_interleaved_stereo',
        );
    getString = library.lookupFunction<_GetStringNative, _GetStringDart>(
      'openmpt_get_string',
    );
    getMetadata = library.lookupFunction<_GetMetadataNative, _GetMetadataDart>(
      'openmpt_module_get_metadata',
    );
    getDuration = library.lookupFunction<_GetDurationNative, _GetDurationDart>(
      'openmpt_module_get_duration_seconds',
    );
    freeString = library.lookupFunction<_FreeStringNative, _FreeStringDart>(
      'openmpt_free_string',
    );
    silentLogFunction = library.lookup<Void>('openmpt_log_func_silent');
    storeErrorFunction = library.lookup<Void>('openmpt_error_func_store');
  }

  final DynamicLibrary library;
  late final _CreateModuleDart createModule;
  late final _DestroyModuleDart destroyModule;
  late final _RenderStereoDart renderStereo;
  late final _GetStringDart getString;
  late final _GetMetadataDart getMetadata;
  late final _GetDurationDart getDuration;
  late final _FreeStringDart freeString;
  late final Pointer<Void> silentLogFunction;
  late final Pointer<Void> storeErrorFunction;

  static DynamicLibrary _loadLibrary() {
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libopenmpt.so');
    }
    if (Platform.isIOS) {
      // iOS links native dependencies into the application process.
      return DynamicLibrary.process();
    }
    throw UnsupportedError(
      'libopenmpt is only configured for Android and iOS.',
    );
  }

  String libraryString(String key) {
    final nativeKey = key.toNativeUtf8();
    try {
      final value = getString(nativeKey);
      if (value == nullptr) {
        return '';
      }
      try {
        return value.toDartString();
      } finally {
        freeString(value);
      }
    } finally {
      malloc.free(nativeKey);
    }
  }

  String moduleMetadata(Pointer<_OpenMptModule> module, String key) {
    final nativeKey = key.toNativeUtf8();
    try {
      final value = getMetadata(module, nativeKey);
      if (value == nullptr) {
        return '';
      }
      try {
        return value.toDartString();
      } finally {
        freeString(value);
      }
    } finally {
      malloc.free(nativeKey);
    }
  }
}

/// Owns one libopenmpt module and renders signed 16-bit interleaved stereo PCM.
class OpenMptDecoder {
  OpenMptDecoder._(this._bindings, this._module, this.description);

  final _OpenMptBindings _bindings;
  Pointer<_OpenMptModule> _module;
  final String description;

  bool get isDisposed => _module == nullptr;

  static Future<OpenMptDecoder> fromAsset(String assetPath) async {
    final asset = await rootBundle.load(assetPath);
    final bytes = asset.buffer.asUint8List(
      asset.offsetInBytes,
      asset.lengthInBytes,
    );
    return fromBytes(bytes);
  }

  static OpenMptDecoder fromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError.value(bytes, 'bytes', 'Module data is empty.');
    }

    final bindings = _OpenMptBindings();
    final nativeBytes = malloc<Uint8>(bytes.length);
    final error = calloc<Int32>();
    final errorMessage = calloc<Pointer<Utf8>>();
    Pointer<_OpenMptModule> module = nullptr;

    try {
      nativeBytes.asTypedList(bytes.length).setAll(0, bytes);
      module = bindings.createModule(
        nativeBytes.cast<Void>(),
        bytes.length,
        bindings.silentLogFunction,
        nullptr,
        bindings.storeErrorFunction,
        nullptr,
        error,
        errorMessage,
        nullptr,
      );

      if (module == nullptr) {
        final messagePointer = errorMessage.value;
        final message = messagePointer == nullptr
            ? 'unknown libopenmpt error'
            : messagePointer.toDartString();
        throw StateError(
          'Could not load module (error ${error.value}): $message',
        );
      }

      final version = bindings.libraryString('library_version');
      final title = bindings.moduleMetadata(module, 'title');
      final type = bindings.moduleMetadata(module, 'type_long');
      final duration = bindings.getDuration(module);
      final description =
          'Initialization succeeded: '
          '${type.isEmpty ? 'module' : type} loaded by '
          '${version.isEmpty ? 'libopenmpt' : version} '
          '(title: ${title.isEmpty ? '(untitled)' : title}, '
          'size: ${bytes.length} bytes, duration: '
          '${duration.toStringAsFixed(2)} sec).';

      return OpenMptDecoder._(bindings, module, description);
    } catch (_) {
      if (module != nullptr) {
        bindings.destroyModule(module);
      }
      rethrow;
    } finally {
      final messagePointer = errorMessage.value;
      if (messagePointer != nullptr) {
        bindings.freeString(messagePointer);
      }
      calloc.free(errorMessage);
      calloc.free(error);
      malloc.free(nativeBytes);
    }
  }

  Uint8List renderStereo({required int frameCount, required int sampleRate}) {
    if (isDisposed) {
      throw StateError('The libopenmpt module has already been disposed.');
    }
    if (frameCount <= 0 || sampleRate <= 0) {
      throw ArgumentError('frameCount and sampleRate must be positive.');
    }

    const channelCount = 2;
    final samples = malloc<Int16>(frameCount * channelCount);
    try {
      final renderedFrames = _bindings.renderStereo(
        _module,
        sampleRate,
        frameCount,
        samples,
      );
      final byteCount = renderedFrames * channelCount * sizeOf<Int16>();
      return Uint8List.fromList(samples.cast<Uint8>().asTypedList(byteCount));
    } finally {
      malloc.free(samples);
    }
  }

  void dispose() {
    if (!isDisposed) {
      _bindings.destroyModule(_module);
      _module = nullptr;
    }
  }
}
