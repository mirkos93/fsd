// fsd: Flutter FFI plugin wrapping stable-diffusion.cpp.
//
// Public surface = `FsdEngine`, which implements the `ImageGenEngine`
// contract Tacita expects. All native calls go through a long-lived helper
// isolate so the UI thread never blocks on inference.

library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Public contract — must match Tacita's lib/imagegen/image_gen_engine.dart
// ---------------------------------------------------------------------------

abstract class ImageGenEngine {
  bool get isReady;
  Future<void> loadModel({required String modelPath});
  Future<void> unloadModel();
  Stream<ImageGenProgress> generate({required ImageGenRequest request});
  Future<void> cancel();
}

class ImageGenRequest {
  const ImageGenRequest({
    required this.prompt,
    this.negativePrompt = '',
    this.width = 512,
    this.height = 512,
    this.steps = 4,
    this.seed,
  });
  final String prompt;
  final String negativePrompt;
  final int width;
  final int height;
  final int steps;
  final int? seed;
}

sealed class ImageGenProgress {}

class ImageGenStep extends ImageGenProgress {
  ImageGenStep({required this.step, required this.total});
  final int step;
  final int total;
}

class ImageGenDone extends ImageGenProgress {
  ImageGenDone({required this.pngBytes});
  final Uint8List pngBytes;
}

class ImageGenError extends ImageGenProgress {
  ImageGenError({required this.message});
  final String message;
}

// ---------------------------------------------------------------------------
// FFI bindings (hand-rolled — small enough that ffigen is not worth it).
// ---------------------------------------------------------------------------

const String _libName = 'fsd';

final DynamicLibrary _dylib = () {
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isIOS || Platform.isMacOS) {
    // iOS xcframework is a static lib merged into Runner.app; symbols are
    // already in the process namespace, so process() resolves them.
    return DynamicLibrary.process();
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('fsd: unsupported platform ${Platform.operatingSystem}');
}();

typedef _FsdLoadNative = Pointer<Void> Function(Pointer<Utf8>);
typedef _FsdLoadDart = Pointer<Void> Function(Pointer<Utf8>);

typedef _FsdFreeNative = Void Function(Pointer<Void>);
typedef _FsdFreeDart = void Function(Pointer<Void>);

typedef _FsdRequestCancelNative = Void Function(Pointer<Void>);
typedef _FsdRequestCancelDart = void Function(Pointer<Void>);

typedef _FsdFreeBytesNative = Void Function(Pointer<Uint8>);
typedef _FsdFreeBytesDart = void Function(Pointer<Uint8>);

typedef _FsdSdCommitNative = Pointer<Utf8> Function();
typedef _FsdSdCommitDart = Pointer<Utf8> Function();

typedef _StepCbNative = Int32 Function(Int32 step, Int32 total, Pointer<Void> user);

typedef _FsdGenerateNative = Int32 Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  Int32,
  Int32,
  Int32,
  Int64,
  Pointer<NativeFunction<_StepCbNative>>,
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<IntPtr>,
);
typedef _FsdGenerateDart = int Function(
  Pointer<Void>,
  Pointer<Utf8>,
  Pointer<Utf8>,
  int,
  int,
  int,
  int,
  Pointer<NativeFunction<_StepCbNative>>,
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<IntPtr>,
);

final _FsdLoadDart _fsdLoad =
    _dylib.lookupFunction<_FsdLoadNative, _FsdLoadDart>('fsd_load');
final _FsdFreeDart _fsdFree =
    _dylib.lookupFunction<_FsdFreeNative, _FsdFreeDart>('fsd_free');
final _FsdRequestCancelDart _fsdRequestCancel = _dylib
    .lookupFunction<_FsdRequestCancelNative, _FsdRequestCancelDart>(
        'fsd_request_cancel');
final _FsdFreeBytesDart _fsdFreeBytes = _dylib
    .lookupFunction<_FsdFreeBytesNative, _FsdFreeBytesDart>('fsd_free_bytes');
final _FsdGenerateDart _fsdGenerate =
    _dylib.lookupFunction<_FsdGenerateNative, _FsdGenerateDart>('fsd_generate');
final _FsdSdCommitDart _fsdSdCommit =
    _dylib.lookupFunction<_FsdSdCommitNative, _FsdSdCommitDart>('fsd_sd_commit');

/// The pinned upstream stable-diffusion.cpp commit hash, as reported by the
/// native library. Useful when filing bug reports.
String get nativeStableDiffusionCommit {
  final p = _fsdSdCommit();
  if (p == nullptr) return 'unknown';
  return p.toDartString();
}

// ---------------------------------------------------------------------------
// Helper-isolate protocol
// ---------------------------------------------------------------------------

class _LoadRequest {
  _LoadRequest(this.id, this.modelPath);
  final int id;
  final String modelPath;
}

class _UnloadRequest {
  _UnloadRequest(this.id);
  final int id;
}

class _GenerateRequest {
  _GenerateRequest(this.id, this.req, this.streamPort);
  final int id;
  final ImageGenRequest req;
  final SendPort streamPort;
}

class _AckOk {
  _AckOk(this.id, [this.payload]);
  final int id;
  final Object? payload;
}

class _AckErr {
  _AckErr(this.id, this.message);
  final int id;
  final String message;
}

// ---------------------------------------------------------------------------
// FsdEngine — public API
// ---------------------------------------------------------------------------

class FsdEngine implements ImageGenEngine {
  FsdEngine();

  Isolate? _isolate;
  SendPort? _toIsolate;
  ReceivePort? _fromIsolate;
  final Map<int, Completer<Object?>> _pending = {};
  int _nextId = 1;
  bool _isReady = false;

  // The native ctx pointer is shared across isolates as a raw address so the
  // main isolate can issue cancel without going through the helper.
  int _ctxAddr = 0;

  @override
  bool get isReady => _isReady;

  Future<void> _ensureIsolate() async {
    if (_isolate != null) return;
    final initPort = ReceivePort();
    _isolate = await Isolate.spawn<SendPort>(
      _isolateMain,
      initPort.sendPort,
      debugName: 'fsd-worker',
    );

    final completer = Completer<SendPort>();
    initPort.listen((dynamic msg) {
      if (msg is SendPort && !completer.isCompleted) {
        completer.complete(msg);
      }
    });
    _toIsolate = await completer.future;
    initPort.close();

    _fromIsolate = ReceivePort();
    _fromIsolate!.listen(_handleFromIsolate);
    _toIsolate!.send(_fromIsolate!.sendPort);
  }

  void _handleFromIsolate(dynamic msg) {
    if (msg is _AckOk) {
      _pending.remove(msg.id)?.complete(msg.payload);
    } else if (msg is _AckErr) {
      _pending.remove(msg.id)?.completeError(StateError(msg.message));
    }
  }

  Future<Object?> _send(Object Function(int) build) async {
    await _ensureIsolate();
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _toIsolate!.send(build(id));
    return completer.future;
  }

  @override
  Future<void> loadModel({required String modelPath}) async {
    if (_isReady) {
      throw StateError('fsd: model already loaded; call unloadModel first');
    }
    final result = await _send((id) => _LoadRequest(id, modelPath)) as int;
    if (result == 0) {
      throw StateError('fsd: failed to load model at $modelPath');
    }
    _ctxAddr = result;
    _isReady = true;
  }

  @override
  Future<void> unloadModel() async {
    if (!_isReady) return;
    await _send((id) => _UnloadRequest(id));
    _ctxAddr = 0;
    _isReady = false;
  }

  @override
  Stream<ImageGenProgress> generate({required ImageGenRequest request}) {
    if (!_isReady) {
      return Stream.value(ImageGenError(message: 'fsd: model not loaded'));
    }
    final controller = StreamController<ImageGenProgress>();
    final eventsPort = ReceivePort();
    eventsPort.listen((dynamic msg) {
      if (msg is ImageGenProgress) {
        controller.add(msg);
        if (msg is ImageGenDone || msg is ImageGenError) {
          eventsPort.close();
          controller.close();
        }
      }
    });

    _ensureIsolate().then((_) {
      _toIsolate!
          .send(_GenerateRequest(_nextId++, request, eventsPort.sendPort));
    });

    return controller.stream;
  }

  @override
  Future<void> cancel() async {
    if (_ctxAddr != 0) {
      _fsdRequestCancel(Pointer<Void>.fromAddress(_ctxAddr));
    }
  }

  /// Tear down the helper isolate. Call when disposing the engine.
  Future<void> dispose() async {
    if (_isReady) await unloadModel();
    _isolate?.kill(priority: Isolate.immediate);
    _fromIsolate?.close();
    _isolate = null;
    _toIsolate = null;
    _fromIsolate = null;
  }
}

// ---------------------------------------------------------------------------
// Helper-isolate entrypoint
// ---------------------------------------------------------------------------

void _isolateMain(SendPort initPort) {
  final inbox = ReceivePort();
  initPort.send(inbox.sendPort);

  SendPort? replyPort;
  Pointer<Void> ctx = nullptr;

  inbox.listen((dynamic msg) {
    if (msg is SendPort) {
      replyPort = msg;
      return;
    }
    if (msg is _LoadRequest) {
      final pathPtr = msg.modelPath.toNativeUtf8();
      try {
        if (ctx != nullptr) _fsdFree(ctx);
        ctx = _fsdLoad(pathPtr);
        replyPort?.send(_AckOk(msg.id, ctx.address));
      } catch (e) {
        replyPort?.send(_AckErr(msg.id, 'load failed: $e'));
      } finally {
        calloc.free(pathPtr);
      }
      return;
    }
    if (msg is _UnloadRequest) {
      if (ctx != nullptr) {
        _fsdFree(ctx);
        ctx = nullptr;
      }
      replyPort?.send(_AckOk(msg.id));
      return;
    }
    if (msg is _GenerateRequest) {
      _runGenerate(ctx, msg);
      return;
    }
  });
}

void _runGenerate(Pointer<Void> ctx, _GenerateRequest msg) {
  if (ctx == nullptr) {
    msg.streamPort.send(ImageGenError(message: 'fsd: context is null'));
    return;
  }

  final promptPtr = msg.req.prompt.toNativeUtf8();
  final negPtr = msg.req.negativePrompt.toNativeUtf8();
  final pngOutPtr = calloc<Pointer<Uint8>>();
  final pngLenPtr = calloc<IntPtr>();

  // Synchronous, isolate-local callback. Runs on this isolate's thread, so we
  // post events to the main isolate via msg.streamPort right away. Returning
  // 0 would request cancel, but upstream sd's progress hook ignores the
  // return value — actual cancel goes through fsd_request_cancel.
  final stepCallable = NativeCallable<_StepCbNative>.isolateLocal(
    (int step, int total, Pointer<Void> _) {
      msg.streamPort.send(ImageGenStep(step: step, total: total));
      return 1;
    },
    exceptionalReturn: 0,
  );

  try {
    final seed = msg.req.seed ?? -1;
    final rc = _fsdGenerate(
      ctx,
      promptPtr,
      negPtr,
      msg.req.width,
      msg.req.height,
      msg.req.steps,
      seed,
      stepCallable.nativeFunction,
      nullptr,
      pngOutPtr,
      pngLenPtr,
    );

    if (rc == 0) {
      final dataPtr = pngOutPtr.value;
      final len = pngLenPtr.value;
      if (dataPtr == nullptr || len <= 0) {
        msg.streamPort.send(ImageGenError(message: 'fsd: empty PNG buffer'));
      } else {
        // Copy out then free C buffer — never hold a Dart view over native
        // memory whose lifetime is shorter than the view.
        final bytes = Uint8List.fromList(dataPtr.asTypedList(len));
        _fsdFreeBytes(dataPtr);
        msg.streamPort.send(ImageGenDone(pngBytes: bytes));
      }
    } else if (rc == -3) {
      msg.streamPort.send(ImageGenError(message: 'cancelled'));
    } else {
      msg.streamPort.send(ImageGenError(message: 'fsd_generate rc=$rc'));
    }
  } catch (e) {
    msg.streamPort.send(ImageGenError(message: 'fsd: $e'));
  } finally {
    stepCallable.close();
    calloc.free(promptPtr);
    calloc.free(negPtr);
    calloc.free(pngOutPtr);
    calloc.free(pngLenPtr);
  }
}
