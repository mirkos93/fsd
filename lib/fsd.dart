// fsd: Flutter FFI plugin wrapping stable-diffusion.cpp.
//
// Public surface = `FsdEngine`, which implements the `ImageGenEngine`
// contract defined below. All native calls go through a long-lived helper
// isolate so the UI thread never blocks on inference.

library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---------------------------------------------------------------------------
// Public contract.
//
// `ImageGenEngine` is the abstract surface a host application talks to;
// `FsdEngine` is this plugin's implementation. The split keeps consumer code
// decoupled from the FFI internals (handy for fakes in widget tests).
// ---------------------------------------------------------------------------

abstract class ImageGenEngine {
  bool get isReady;
  Future<void> loadModel({required String modelPath});
  Future<void> unloadModel();
  Stream<ImageGenProgress> generate({required ImageGenRequest request});
  Future<void> cancel();
}

/// Sampler family. Mirrors `fsd_sampler_t` in fsd.h.
///
/// - [defaultSampler] — LCM sampler + LCM scheduler + cfg=1.0 (the original
///   fsd defaults). With no [ImageGenRequest.loraPath] this produces
///   bit-for-bit identical output to legacy single-arg `fsd_generate` callers
///   for the same seed.
/// - [lcm] — same as default today. Layered with [ImageGenRequest.loraPath]
///   pointing at an LCM LoRA, this is the "4 step" regime: callers should pass
///   [ImageGenRequest.steps] = 4 and let [cfgScale] default to 1.0.
enum FsdSampler {
  defaultSampler,
  lcm,
}

class ImageGenRequest {
  const ImageGenRequest({
    required this.prompt,
    this.negativePrompt = '',
    this.width = 512,
    this.height = 512,
    this.steps = 4,
    this.seed,
    this.sampler = FsdSampler.defaultSampler,
    this.cfgScale,
    this.loraPath,
    this.loraScale,
  });

  final String prompt;
  final String negativePrompt;
  final int width;
  final int height;

  /// Sampling steps. LCM-distilled SD 1.5 converges in 4 steps; vanilla SD
  /// 1.5 wants 20+. When [sampler] is [FsdSampler.lcm] and the caller doesn't
  /// override, 4 is a sane default.
  final int steps;
  final int? seed;
  final FsdSampler sampler;

  /// Classifier-free-guidance scale. Null (the default) means "let fsd pick"
  /// — fsd uses 1.0, the LCM-canonical value. Non-LCM workflows typically
  /// want 7.0 here.
  final double? cfgScale;

  /// Optional LoRA file path. .safetensors or .gguf both work — see
  /// stable-diffusion.cpp's ModelLoader. When set, the LoRA is applied for
  /// this single generate() call. The most common use is an LCM LoRA paired
  /// with `sampler = FsdSampler.lcm`, `steps = 4`, `cfgScale = 1.0`.
  final String? loraPath;

  /// LoRA strength multiplier. Null -> 1.0 (full strength). Range is
  /// effectively 0..1 for LCM LoRAs; higher values amplify both the speed
  /// boost and the "plasticky" look LCM is known for.
  final double? loraScale;
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

typedef _FsdGpuAvailableNative = Int32 Function();
typedef _FsdGpuAvailableDart = int Function();

typedef _StepCbNative = Int32 Function(Int32 step, Int32 total, Pointer<Void> user);

// Mirrors fsd_gen_params_t in fsd.h. Field order MUST match the C layout.
final class _FsdGenParams extends Struct {
  external Pointer<Utf8> prompt;
  external Pointer<Utf8> negativePrompt;
  @Int32()
  external int width;
  @Int32()
  external int height;
  @Int32()
  external int steps;
  @Int64()
  external int seed;
  @Int32()
  external int sampler; // fsd_sampler_t enum
  @Float()
  external double cfgScale;
  external Pointer<Utf8> loraPath;
  @Float()
  external double loraScale;
}

typedef _FsdGenerateV2Native = Int32 Function(
  Pointer<Void>,
  Pointer<_FsdGenParams>,
  Pointer<NativeFunction<_StepCbNative>>,
  Pointer<Void>,
  Pointer<Pointer<Uint8>>,
  Pointer<IntPtr>,
);
typedef _FsdGenerateV2Dart = int Function(
  Pointer<Void>,
  Pointer<_FsdGenParams>,
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
final _FsdGenerateV2Dart _fsdGenerateV2 = _dylib
    .lookupFunction<_FsdGenerateV2Native, _FsdGenerateV2Dart>(
        'fsd_generate_v2');
final _FsdSdCommitDart _fsdSdCommit =
    _dylib.lookupFunction<_FsdSdCommitNative, _FsdSdCommitDart>('fsd_sd_commit');
final _FsdGpuAvailableDart _fsdGpuAvailable = _dylib
    .lookupFunction<_FsdGpuAvailableNative, _FsdGpuAvailableDart>(
        'fsd_gpu_available');

/// The pinned upstream stable-diffusion.cpp commit hash, as reported by the
/// native library. Useful when filing bug reports.
String get nativeStableDiffusionCommit {
  final p = _fsdSdCommit();
  if (p == nullptr) return 'unknown';
  return p.toDartString();
}

/// True if libfsd was compiled with Vulkan compute support AND a Vulkan-capable
/// device is available at runtime. False on CPU-only builds and on devices
/// without a Vulkan ICD. The CPU path remains the default regardless — this
/// is a UI hint, not a switch.
bool get gpuAvailable => _fsdGpuAvailable() != 0;

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
  final loraPtr = (msg.req.loraPath != null && msg.req.loraPath!.isNotEmpty)
      ? msg.req.loraPath!.toNativeUtf8()
      : nullptr;
  final paramsPtr = calloc<_FsdGenParams>();
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
    final p = paramsPtr.ref;
    p.prompt          = promptPtr;
    p.negativePrompt  = negPtr;
    p.width           = msg.req.width;
    p.height          = msg.req.height;
    p.steps           = msg.req.steps;
    p.seed            = msg.req.seed ?? -1;
    p.sampler         = switch (msg.req.sampler) {
      FsdSampler.defaultSampler => 0,
      FsdSampler.lcm            => 1,
    };
    p.cfgScale        = msg.req.cfgScale ?? 0.0; // 0 -> native default (1.0)
    p.loraPath        = loraPtr.cast<Utf8>();
    p.loraScale       = msg.req.loraScale ?? 0.0; // 0 -> native default (1.0)

    final rc = _fsdGenerateV2(
      ctx,
      paramsPtr,
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
    if (loraPtr != nullptr) calloc.free(loraPtr);
    calloc.free(paramsPtr);
    calloc.free(pngOutPtr);
    calloc.free(pngLenPtr);
  }
}
