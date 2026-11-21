/// Carty — Dart FFI front door to the native bridge (`libcarty.so`).
///
/// This is the ONLY Dart code that touches `dart:ffi` for the bridge; everything
/// else in the app talks to these types. It never reimplements
/// logic — it enforces the *memory ownership contract* declared in
/// `native/include/carty_bridge.h`:
///
///   - The BRIDGE owns each frame's multi-MB pixel buffer.
///   - [CartyFrameBuffer.bytes] is a ZERO-COPY [Uint8List] view (via
///     `Pointer.asTypedList`) into that bridge-owned buffer — no megabytes are
///     copied across the FFI boundary.
///   - Exactly ONE free runs per alloc. That is guaranteed two ways:
///       1. [CartyFrameBuffer.dispose] frees deterministically, and
///       2. a [NativeFinalizer] bound to `carty_frame_free` frees on GC if the
///          caller forgets — so a dropped reference can never leak the buffer.
///     `dispose()` detaches the finalizer first, so the free can never run twice.
///
/// Bindings are generated (`lib/carty_bindings_generated.dart`), never hand
/// edited — regenerate with `dart run ffigen --config ffigen.yaml`.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'carty_bindings_generated.dart';

/// Re-export the bounds the native bridge enforces, so Dart callers can check
/// before crossing the (crash-on-violation) boundary.
const int cartyFrameMaxDim = CARTY_FRAME_MAX_DIM;
const int cartyFrameMaxChannels = CARTY_FRAME_MAX_CHANNELS;

/// World-grid (fusion stage) hard caps + defaults, re-exported so callers can
/// range-check a [Carty.createWorldGrid] request before the native abort. The
/// defaults size one capture segment (51.2 m span / 16 MiB at H=16); see
/// `carty_bridge.h` for why a generous segment grid is cheap.
const int cartyGridMaxN = CARTY_GRID_MAX_N;
const int cartyGridMaxH = CARTY_GRID_MAX_H;
const int cartyGridDefaultN = CARTY_GRID_N;
const int cartyGridDefaultH = CARTY_GRID_H;

const String _libName = 'carty';

/// Opens the bridge shared library for the current platform. On Android the
/// `.so` is packaged into the APK under `lib/<abi>/` and resolved by name.
DynamicLibrary _openBridgeLibrary() {
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError(
    'Carty: unsupported platform ${Platform.operatingSystem}',
  );
}

/// The Carty native bridge. Use [Carty.instance] in the app; inject a library
/// with [Carty.fromLibrary] in tests against the host-built `.so`.
final class Carty {
  Carty._(this._bindings, this._frameFinalizer, this._modelFinalizer,
      this._orthoFinalizer, this._worldGridFinalizer);

  /// Wraps an already-loaded [DynamicLibrary]. Exposed for host tests that load
  /// the unit-test build (`native/build/libcarty_bridge.so`) directly.
  factory Carty.fromLibrary(DynamicLibrary library) {
    final bindings = CartyBindings(library);
    // The finalizer calls `carty_frame_free(token)` on GC. The token is the
    // frame handle pointer (attached per-frame in [CartyFrameBuffer]).
    final frameFinalizer = NativeFinalizer(
      library.lookup<NativeFinalizerFunction>('carty_frame_free'),
    );
    // Same pattern for model handles (freed via carty_model_free on GC).
    final modelFinalizer = NativeFinalizer(
      library.lookup<NativeFinalizerFunction>('carty_model_free'),
    );
    // And for top-down ortho grids (freed via carty_ortho_map_free on GC).
    final orthoFinalizer = NativeFinalizer(
      library.lookup<NativeFinalizerFunction>('carty_ortho_map_free'),
    );
    // And for persistent world-frame fusion grids (freed via
    // carty_world_grid_free on GC — these hold up to ~64 MiB per segment, so a
    // dropped reference must never leak the volume).
    final worldGridFinalizer = NativeFinalizer(
      library.lookup<NativeFinalizerFunction>('carty_world_grid_free'),
    );
    return Carty._(bindings, frameFinalizer, modelFinalizer, orthoFinalizer,
        worldGridFinalizer);
  }

  /// Process-wide instance backed by the platform bridge library.
  static final Carty instance = Carty.fromLibrary(_openBridgeLibrary());

  final CartyBindings _bindings;
  final NativeFinalizer _frameFinalizer;
  final NativeFinalizer _modelFinalizer;
  final NativeFinalizer _orthoFinalizer;
  final NativeFinalizer _worldGridFinalizer;

  /// The bridge ABI version (static C string; never freed by Dart).
  String get version => _bindings.carty_version().cast<Utf8>().toDartString();

  /// Allocates a zero-initialised, bridge-owned frame buffer of
  /// `width * height * channels` bytes. Dimensions must satisfy the bridge
  /// bounds ([cartyFrameMaxDim], [cartyFrameMaxChannels]) — violating them
  /// crashes the process at the native boundary by design (Tiger Style), so
  /// we range-check here first and throw a recoverable error instead.
  CartyFrameBuffer allocFrame({
    required int width,
    required int height,
    required int channels,
  }) {
    if (width <= 0 || width > cartyFrameMaxDim) {
      throw ArgumentError.value(width, 'width', 'must be in 1..$cartyFrameMaxDim');
    }
    if (height <= 0 || height > cartyFrameMaxDim) {
      throw ArgumentError.value(height, 'height', 'must be in 1..$cartyFrameMaxDim');
    }
    if (channels <= 0 || channels > cartyFrameMaxChannels) {
      throw ArgumentError.value(
        channels,
        'channels',
        'must be in 1..$cartyFrameMaxChannels',
      );
    }
    final handle = _bindings.carty_frame_alloc(width, height, channels);
    return CartyFrameBuffer._(this, handle);
  }

  /// Loads a Gemma 4 E2B LiteRT model from [path]. The returned handle owns the
  /// native model; free it with [CartyModelHandle.dispose] (or rely on the GC
  /// finalizer). The bridge aborts on an empty path, so we check here first.
  ///
  /// NOTE: LiteRT is not yet linked into the bridge, so the model is a
  /// path-stashing stub — [CartyModelHandle.inferMapUpdate] returns
  /// `CARTY_INFER_ENOMODEL`. The handle/ownership contract is nonetheless real.
  CartyModelHandle loadModel(String path) {
    if (path.isEmpty) {
      throw ArgumentError.value(path, 'path', 'model path must be non-empty');
    }
    final pathPtr = path.toNativeUtf8();
    try {
      final handle = _bindings.carty_model_load(pathPtr.cast<Char>());
      return CartyModelHandle._(this, handle);
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// GEOMETRIC stage: orthorectify one oblique RGBA [frame] (a
  /// bridge-owned tensor of exactly `width*height*channels` bytes) into a
  /// freshly-allocated, bridge-owned top-down [CartyOrthoMapHandle] occupancy
  /// grid via `carty_ortho_project`. The returned handle owns native memory;
  /// free it with [CartyOrthoMapHandle.dispose] (or rely on the GC finalizer).
  ///
  /// The native boundary ABORTS on a size mismatch or out-of-bounds dims
  /// (Tiger Style), so we range-check the pixel geometry here first and throw
  /// a recoverable error rather than crashing the process at the FFI line.
  CartyOrthoMapHandle orthoProject(
    CartyFrameBuffer frame, {
    required int width,
    required int height,
    required int channels,
  }) {
    frame._ensureLive();
    if (width <= 0 || width > cartyFrameMaxDim) {
      throw ArgumentError.value(width, 'width', 'must be in 1..$cartyFrameMaxDim');
    }
    if (height <= 0 || height > cartyFrameMaxDim) {
      throw ArgumentError.value(
          height, 'height', 'must be in 1..$cartyFrameMaxDim');
    }
    if (channels <= 0 || channels > cartyFrameMaxChannels) {
      throw ArgumentError.value(
          channels, 'channels', 'must be in 1..$cartyFrameMaxChannels');
    }
    final expected = width * height * channels;
    if (expected != frame.lengthInBytes) {
      throw ArgumentError(
          'frame is ${frame.lengthInBytes} bytes != $width*$height*$channels '
          '($expected) — ortho projection precondition');
    }
    final handle =
        _bindings.carty_ortho_project(frame._handle, width, height, channels);
    return CartyOrthoMapHandle._(this, handle);
  }

  /// FUSION stage (the fusion stage): create a persistent, world-anchored 2.5D
  /// voxel-column grid for ONE capture segment — the world accumulator that
  /// [CartyWorldGridHandle.accrete] folds pose-stamped keyframes into. The
  /// returned handle owns native memory (up to ~64 MiB at the caps); free it
  /// with [CartyWorldGridHandle.dispose] (or rely on the GC finalizer).
  ///
  /// The native boundary ABORTS on out-of-cap dims or non-finite/non-positive
  /// resolutions (Tiger Style), so we range-check here first and throw a
  /// recoverable [ArgumentError] instead of crashing the process at the FFI line.
  CartyWorldGridHandle createWorldGrid({
    int n = cartyGridDefaultN,
    int h = cartyGridDefaultH,
    double resM = 0.05,
    double bandM = 0.25,
  }) {
    if (n <= 0 || n > cartyGridMaxN) {
      throw ArgumentError.value(n, 'n', 'must be in 1..$cartyGridMaxN');
    }
    if (h <= 0 || h > cartyGridMaxH) {
      throw ArgumentError.value(h, 'h', 'must be in 1..$cartyGridMaxH');
    }
    if (!resM.isFinite || resM <= 0) {
      throw ArgumentError.value(resM, 'resM', 'must be finite and > 0');
    }
    if (!bandM.isFinite || bandM <= 0) {
      throw ArgumentError.value(bandM, 'bandM', 'must be finite and > 0');
    }
    final shape = malloc<CartyGridShape>();
    try {
      shape.ref
        ..cells_per_side = n
        ..height_bands = h
        ..res_m = resM
        ..band_m = bandM;
      final handle = _bindings.carty_world_grid_create(shape);
      return CartyWorldGridHandle._(this, handle);
    } finally {
      malloc.free(shape);
    }
  }

}

/// A handle to a bridge-owned frame buffer.
///
/// Implements [Finalizable] so the Dart GC keeps the object (and thus the native
/// buffer) alive while in use, and runs the [NativeFinalizer] exactly once if
/// the caller drops it without calling [dispose]. Prefer [dispose] — it frees
/// deterministically and is required to release the (multi-MB) buffer promptly.
final class CartyFrameBuffer implements Finalizable {
  CartyFrameBuffer._(this._carty, this._handle)
    : _sizeInBytes = _carty._bindings.carty_frame_size(_handle) {
    // Attach the GC-time free. `token` is what `carty_frame_free` receives;
    // `detach` is the key [dispose] uses to cancel this before freeing manually.
    // `externalSize` tells the GC how much native memory this object pins, so it
    // can schedule collection under native-memory pressure.
    _carty._frameFinalizer.attach(
      this,
      _handle.cast<Void>(),
      detach: this,
      externalSize: _sizeInBytes,
    );
  }

  final Carty _carty;
  Pointer<CartyFrame> _handle;
  final int _sizeInBytes;
  bool _disposed = false;

  /// Size of the owned buffer in bytes (`width * height * channels`).
  int get lengthInBytes => _sizeInBytes;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// ZERO-COPY view over the bridge-owned pixel buffer. Backed directly by
  /// native memory (`Pointer.asTypedList`) — reads/writes hit the same bytes the
  /// bridge owns, so no multi-MB copy crosses the FFI boundary. The view is
  /// only valid until [dispose]; using it afterwards throws.
  Uint8List get bytes {
    _ensureLive();
    return _carty._bindings.carty_frame_data(_handle).asTypedList(_sizeInBytes);
  }

  /// Frees the native buffer deterministically. Idempotent. Detaches the
  /// [NativeFinalizer] first, so the buffer is freed exactly once even if the
  /// object is later garbage-collected.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _carty._frameFinalizer.detach(this);
    _carty._bindings.carty_frame_free(_handle);
    _handle = nullptr;
  }

  void _ensureLive() {
    if (_disposed) {
      throw StateError('CartyFrameBuffer used after dispose()');
    }
  }
}

/// A handle to a bridge-owned top-down occupancy grid (the [CartyOrthoMap]
/// produced by [Carty.orthoProject]).
///
/// Mirrors [CartyFrameBuffer]'s ownership contract exactly: a [NativeFinalizer]
/// frees the native grid on GC if [dispose] is not called, and [dispose]
/// detaches it first so `carty_ortho_map_free` runs exactly once. The grid is
/// the geometric input to the semantic stage ([CartyModelHandle.inferMapUpdateOrtho]).
final class CartyOrthoMapHandle implements Finalizable {
  CartyOrthoMapHandle._(this._carty, this._handle)
      : _sizeInBytes = _carty._bindings.carty_ortho_map_size(_handle) {
    _carty._orthoFinalizer.attach(
      this,
      _handle.cast<Void>(),
      detach: this,
      externalSize: _sizeInBytes,
    );
  }

  final Carty _carty;
  Pointer<CartyOrthoMap> _handle;
  final int _sizeInBytes;
  bool _disposed = false;

  /// Grid width in cells.
  int get width {
    _ensureLive();
    return _carty._bindings.carty_ortho_map_width(_handle);
  }

  /// Grid height in cells.
  int get height {
    _ensureLive();
    return _carty._bindings.carty_ortho_map_height(_handle);
  }

  /// Occupancy grid size in bytes (`width * height`).
  int get sizeInBytes => _sizeInBytes;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Serializes this grid into the fixed "Spatial Context" cartographic
  /// instruction + a bounded, DETERMINISTIC coarse occupancy summary
  /// (`carty_ortho_to_spatial_prompt`). Exposed mainly for tests/diagnostics —
  /// the production semantic call ([CartyModelHandle.inferMapUpdateOrtho])
  /// builds this prompt natively. Returns the prompt text, or throws
  /// [StateError] on the (bounded-by-construction) ENOSPACE path.
  String spatialPrompt({
    required String instruction,
    int capacity = CARTY_SPATIAL_PROMPT_MAX,
  }) {
    _ensureLive();
    if (capacity <= 0 || capacity > CARTY_SPATIAL_PROMPT_MAX) {
      throw ArgumentError.value(
          capacity, 'capacity', 'must be in 1..$CARTY_SPATIAL_PROMPT_MAX');
    }
    // The strict {"ops":[...]} output contract is owned by Dart
    // (kMapUpdateSchemaContract); the bridge holds no copy and only frames the
    // caller-supplied instruction with a bounded grid summary.
    // Allocate INSIDE try (init null outside): if the second alloc throws,
    // finally still frees the first — nothing leaks on an allocation failure.
    Pointer<Utf8>? instrPtr;
    Pointer<Uint8>? outBuf;
    try {
      instrPtr = instruction.toNativeUtf8();
      outBuf = malloc<Uint8>(capacity);
      final rc = _carty._bindings.carty_ortho_to_spatial_prompt(
        _handle,
        instrPtr.cast<Char>(),
        instrPtr.length,
        outBuf.cast<Char>(),
        capacity,
      );
      if (rc < 0) {
        throw StateError('carty_ortho_to_spatial_prompt failed ($rc)');
      }
      return outBuf.cast<Utf8>().toDartString();
    } finally {
      if (instrPtr != null) malloc.free(instrPtr);
      if (outBuf != null) malloc.free(outBuf);
    }
  }

  /// Frees the native grid deterministically. Idempotent; detaches the
  /// finalizer so the free runs exactly once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _carty._orthoFinalizer.detach(this);
    _carty._bindings.carty_ortho_map_free(_handle);
    _handle = nullptr;
  }

  void _ensureLive() {
    if (_disposed) {
      throw StateError('CartyOrthoMapHandle used after dispose()');
    }
  }
}

/// The result of a native multimodal inference: a status plus the decoded text.
///
/// [status] >= 0 means success and [text] holds the model's map-update JSON; a
/// negative status is a SAFE failure (e.g. `CARTY_INFER_ENOMODEL` while LiteRT
/// is unlinked) and [text] is empty. Callers must check [status] before reading.
final class CartyInference {
  const CartyInference({required this.status, required this.text});
  final int status;
  final String text;

  bool get ok => status >= 0;
}

/// A handle to a bridge-owned Gemma 4 E2B model.
///
/// Mirrors [CartyFrameBuffer]'s ownership contract: a [NativeFinalizer] frees
/// the native model on GC if [dispose] is not called, and [dispose] detaches it
/// first so the free runs exactly once.
final class CartyModelHandle implements Finalizable {
  CartyModelHandle._(this._carty, this._handle) {
    _carty._modelFinalizer.attach(this, _handle.cast<Void>(), detach: this);
  }

  final Carty _carty;
  Pointer<CartyModel> _handle;
  bool _disposed = false;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Runs a multimodal structured inference: pushes the bridge-owned
  /// [imageSegment] tensor, the [textPrompt], and the normalized spatial bound
  /// `[bx0,by0]-[bx1,by1]` through `carty_infer_map_update`, returning the model
  /// output (or a negative status on safe failure). [outputCapacity] bounds the
  /// native output buffer (context management; <= `CARTY_MAP_UPDATE_MAX`).
  CartyInference inferMapUpdate({
    required CartyFrameBuffer imageSegment,
    required String textPrompt,
    required double bx0,
    required double by0,
    required double bx1,
    required double by1,
    int outputCapacity = CARTY_MAP_UPDATE_MAX,
  }) {
    _ensureLive();
    imageSegment._ensureLive();
    if (outputCapacity <= 0 || outputCapacity > CARTY_MAP_UPDATE_MAX) {
      throw ArgumentError.value(
        outputCapacity,
        'outputCapacity',
        'must be in 1..$CARTY_MAP_UPDATE_MAX',
      );
    }

    // Allocate INSIDE try (init null outside): if the second alloc throws,
    // finally still frees the first — nothing leaks on an allocation failure.
    Pointer<Utf8>? promptPtr;
    Pointer<Uint8>? outBuf;
    try {
      promptPtr = textPrompt.toNativeUtf8();
      outBuf = malloc<Uint8>(outputCapacity);
      final rc = _carty._bindings.carty_infer_map_update(
        _handle,
        imageSegment._handle,
        promptPtr.cast<Char>(),
        bx0,
        by0,
        bx1,
        by1,
        outBuf.cast<Char>(),
        outputCapacity,
      );
      if (rc < 0) {
        return CartyInference(status: rc, text: '');
      }
      // rc is bytes written including the NUL terminator.
      final text = outBuf.cast<Utf8>().toDartString();
      return CartyInference(status: rc, text: text);
    } finally {
      if (promptPtr != null) malloc.free(promptPtr);
      if (outBuf != null) malloc.free(outBuf);
    }
  }

  /// SEMANTIC stage: runs a structured map-update inference
  /// CONDITIONED ON the top-down occupancy [orthoMap]. The bridge builds the
  /// "Spatial Context" prompt from the grid natively (so node coordinates land
  /// in STABLE ground space, not raw oblique-pixel space) and drives Gemma 4
  /// E2B via `carty_infer_map_update_ortho`, returning the model's map-update
  /// JSON — or a negative status on safe failure ([CARTY_INFER_ENOMODEL] when
  /// LiteRT is not linked / the runtime is not configured). [outputCapacity]
  /// bounds the native output buffer (<= `CARTY_MAP_UPDATE_MAX`).
  CartyInference inferMapUpdateOrtho(
    CartyOrthoMapHandle orthoMap, {
    required String instruction,
    int outputCapacity = CARTY_MAP_UPDATE_MAX,
  }) {
    _ensureLive();
    orthoMap._ensureLive();
    if (outputCapacity <= 0 || outputCapacity > CARTY_MAP_UPDATE_MAX) {
      throw ArgumentError.value(
        outputCapacity,
        'outputCapacity',
        'must be in 1..$CARTY_MAP_UPDATE_MAX',
      );
    }

    // Dart owns the {"ops":[...]} contract (kMapUpdateSchemaContract) and passes
    // it down; the bridge frames it with the bounded grid summary natively.
    // Allocate INSIDE try (init null outside): if the second alloc throws,
    // finally still frees the first — nothing leaks on an allocation failure.
    Pointer<Utf8>? instrPtr;
    Pointer<Uint8>? outBuf;
    try {
      instrPtr = instruction.toNativeUtf8();
      outBuf = malloc<Uint8>(outputCapacity);
      final rc = _carty._bindings.carty_infer_map_update_ortho(
        _handle,
        orthoMap._handle,
        instrPtr.cast<Char>(),
        instrPtr.length,
        outBuf.cast<Char>(),
        outputCapacity,
      );
      if (rc < 0) {
        return CartyInference(status: rc, text: '');
      }
      // rc is bytes written including the NUL terminator.
      final text = outBuf.cast<Utf8>().toDartString();
      return CartyInference(status: rc, text: text);
    } finally {
      if (instrPtr != null) malloc.free(instrPtr);
      if (outBuf != null) malloc.free(outBuf);
    }
  }

  /// Frees the native model deterministically. Idempotent; detaches the
  /// finalizer so the free runs exactly once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _carty._modelFinalizer.detach(this);
    _carty._bindings.carty_model_free(_handle);
    _handle = nullptr;
  }

  void _ensureLive() {
    if (_disposed) {
      throw StateError('CartyModelHandle used after dispose()');
    }
  }
}

/// The outcome of a [CartyWorldGridHandle.accrete] call.
///
/// Mirrors the C `CARTY_FUSE_*` status codes. Every value is a SAFE, non-fatal
/// condition — accretion never aborts on data (only a corrupt boundary does, and
/// that crashes the process). [ok] folded the observation; the other three left
/// the grid byte-for-byte untouched. In particular [seenFull] is the expected
/// "start a new segment" signal at the seen-keyframe cap (honest
/// degradation), not an error.
enum CartyFuseStatus {
  /// Observation folded into the grid (`CARTY_FUSE_OK`).
  ok,

  /// `keyframe_id` was already incorporated; grid untouched (`CARTY_FUSE_DUPLICATE`).
  duplicate,

  /// The observation fell entirely off the bounded grid; grid untouched
  /// (`CARTY_FUSE_OUT_OF_BOUNDS`).
  outOfBounds,

  /// The segment already holds `CARTY_GRID_SEEN_MAX` keyframes; grid untouched —
  /// the signal to start a new segment (`CARTY_FUSE_SEEN_FULL`).
  seenFull;

  /// Maps a native `CARTY_FUSE_*` code to the enum. An unrecognised code is a
  /// broken ABI contract, not recoverable data — assert it rather than silently
  /// inventing a status (Tiger Style).
  static CartyFuseStatus _fromCode(int code) {
    switch (code) {
      case CARTY_FUSE_OK:
        return CartyFuseStatus.ok;
      case CARTY_FUSE_DUPLICATE:
        return CartyFuseStatus.duplicate;
      case CARTY_FUSE_OUT_OF_BOUNDS:
        return CartyFuseStatus.outOfBounds;
      case CARTY_FUSE_SEEN_FULL:
        return CartyFuseStatus.seenFull;
      default:
        throw StateError('carty_world_grid_accrete returned unknown status $code');
    }
  }
}

/// The world placement of a [CartyWorldGridHandle]: the world coordinates of
/// grid cell `(0,0,band0)` and whether the grid has been anchored yet. Until the
/// first contributing keyframe anchors it, [anchored] is false and the
/// coordinates are unset — this is the stitching precondition (cross-segment stitching).
final class CartyGridOrigin {
  const CartyGridOrigin({
    required this.x,
    required this.y,
    required this.z,
    required this.anchored,
  });

  /// World X at cell (0,0,band0) (ARCore world X — a ground axis).
  final double x;

  /// World Z at cell (0,0,band0) (ARCore world Z — the second ground axis).
  final double y;

  /// World Y at cell (0,0,band0) (ARCore world Y, up — the height axis).
  final double z;

  /// Whether the first accrete has anchored the origin on a camera.
  final bool anchored;
}

/// The metric resolution of a [CartyWorldGridHandle]: metres per ground cell and
/// per height band. Fixed at create; needed (with [CartyGridOrigin]) to place
/// fused cells in the segment's world frame for vectorize + stitching (cross-segment stitching).
final class CartyGridResolution {
  const CartyGridResolution({required this.resM, required this.bandM});

  /// Metres per ground cell.
  final double resM;

  /// Metres per height band.
  final double bandM;
}

/// A handle to a bridge-owned, world-anchored 2.5D voxel-column fusion grid (the
/// [CartyWorldGrid] created by [Carty.createWorldGrid]).
///
/// Mirrors [CartyOrthoMapHandle]'s ownership contract exactly: a
/// [NativeFinalizer] frees the native grid on GC if [dispose] is not called, and
/// [dispose] detaches it first so `carty_world_grid_free` runs exactly once.
///
/// SCOPE CAVEAT carried from the C ABI (so the Dart reader is not
/// misled): [accrete] registers an already-orthorectified observation using ONLY
/// the pose's horizontal translation + yaw (heading), folds into a single fixed
/// band at the camera-height level (NOT the geometric floor; depth deferred), and
/// inherits the fixed-pose metric scale of `carty_ortho_project`. Full
/// pitch/roll, depth height-banding, and real metric scale arrive with a future
/// raw-frame splat.
final class CartyWorldGridHandle implements Finalizable {
  CartyWorldGridHandle._(this._carty, this._handle)
      : _sizeInBytes = _carty._bindings.carty_world_grid_size(_handle),
        // n is fixed for the grid's lifetime, so the floor photo-map's extent
        // (n*n*3, distinct from the n*n*h log-odds volume) is cached once.
        _colorSizeInBytes = _carty._bindings.carty_world_grid_n(_handle) *
            _carty._bindings.carty_world_grid_n(_handle) *
            3 {
    _carty._worldGridFinalizer.attach(
      this,
      _handle.cast<Void>(),
      detach: this,
      externalSize: _sizeInBytes,
    );
  }

  final Carty _carty;
  Pointer<CartyWorldGrid> _handle;
  final int _sizeInBytes;
  final int _colorSizeInBytes;
  bool _disposed = false;

  /// Ground cells per side.
  int get n {
    _ensureLive();
    return _carty._bindings.carty_world_grid_n(_handle);
  }

  /// Height bands.
  int get h {
    _ensureLive();
    return _carty._bindings.carty_world_grid_h(_handle);
  }

  /// Size of the log-odds volume in bytes (`n*n*h`).
  int get sizeInBytes => _sizeInBytes;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// ZERO-COPY, read-only view over the bridge-owned `int8` log-odds volume
  /// (`n*n*h` bytes, band-major `idx=(band*n+gy)*n+gx`). Backed directly by
  /// native memory (`Pointer.asTypedList`), so no copy of the (up-to-64-MiB)
  /// volume crosses the FFI boundary. Cells are `int8` (a log-odds of observation
  /// coverage, signed), hence an [Int8List], not [Uint8List]. The view is only
  /// valid until [dispose]; using it afterwards throws. Treat it as read-only —
  /// the bridge owns and mutates these bytes.
  Int8List get cells {
    _ensureLive();
    return _carty._bindings.carty_world_grid_cells(_handle).asTypedList(_sizeInBytes);
  }

  /// Vectorize the fused grid into a parsed GeoJSON FeatureCollection — the seam
  /// that turns the occupancy volume into the scored MapGraph (#7). Exists so the
  /// benchmark gate scores the REAL native vectorizer output, not a committed stub. The
  /// native writer caps output at [CARTY_VEC_OUT_MAX], so one fixed buffer is
  /// bounded-by-construction (Tiger Style) — no grow loop needed. ENOGRID
  /// (unanchored / no observed cells) is a [StateError], not a silent empty map.
  Map<String, Object?> vectorize() {
    _ensureLive();
    const cap = CARTY_VEC_OUT_MAX;
    final buf = malloc<Char>(cap);
    try {
      final rc = _carty._bindings.carty_vectorize(_handle, buf, cap);
      if (rc == CARTY_VEC_ENOGRID) {
        throw StateError(
            'vectorize: grid is unanchored or holds no observed cells');
      }
      if (rc == CARTY_VEC_ENOSPACE) {
        throw StateError('vectorize: output exceeded CARTY_VEC_OUT_MAX ($cap)');
      }
      if (rc <= 0) {
        throw StateError('vectorize: native returned $rc');
      }
      // rc includes the NUL terminator; decode the rc-1 payload bytes as JSON.
      final bytes = buf.cast<Uint8>().asTypedList(rc - 1);
      return jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    } finally {
      malloc.free(buf);
    }
  }

  /// ZERO-COPY, read-only view over the bridge-owned `uint8` floor photo-map
  /// (`n*n*3` bytes, row-major RGB, `idx=(gy*n+gx)*3 + {0:R,1:G,2:B}`, 0 where
  /// unobserved). Backed directly by native memory ([Pointer.asTypedList]), so
  /// no copy crosses the FFI boundary; valid only until [dispose] (throws
  /// afterwards). Treat it as read-only — the bridge owns and mutates these
  /// bytes (painted ONLY by [accreteFromFrame], the one path with pixels).
  ///
  /// HONESTY: this is the top-down floor-OBSERVATION evidence
  /// layer — the real camera color each ground cell was seen with — NOT the D&D
  /// map. Walls/rooms come from the downstream VECTORIZE stage; here walls show
  /// only implicitly as the edge where floor coverage stops.
  Uint8List get color {
    _ensureLive();
    return _carty._bindings
        .carty_world_grid_color(_handle)
        .asTypedList(_colorSizeInBytes);
  }

  /// The grid's world placement (origin + anchored flag). One native call into a
  /// scratch buffer; safe to read before anchoring ([CartyGridOrigin.anchored]
  /// is then false).
  CartyGridOrigin get origin {
    _ensureLive();
    // Allocate INSIDE try (init null outside): if the second alloc throws,
    // finally still frees the first — nothing leaks on an allocation failure.
    Pointer<Double>? buf;
    Pointer<Int>? anchoredPtr;
    try {
      buf = malloc<Double>(3);
      anchoredPtr = malloc<Int>(1);
      _carty._bindings.carty_world_grid_origin(
        _handle,
        buf,
        buf + 1,
        buf + 2,
        anchoredPtr,
      );
      return CartyGridOrigin(
        x: buf[0],
        y: buf[1],
        z: buf[2],
        anchored: anchoredPtr.value != 0,
      );
    } finally {
      if (buf != null) malloc.free(buf);
      if (anchoredPtr != null) malloc.free(anchoredPtr);
    }
  }

  /// The grid's metric resolution (metres per ground cell / per band).
  CartyGridResolution get resolution {
    _ensureLive();
    final buf = malloc<Double>(2);
    try {
      _carty._bindings.carty_world_grid_resolution(_handle, buf, buf + 1);
      return CartyGridResolution(resM: buf[0], bandM: buf[1]);
    } finally {
      malloc.free(buf);
    }
  }

  /// Registers ONE keyframe's top-down [observation] into the persistent world
  /// grid at the given world [pose] (a 16-element 4x4 ROW-MAJOR camera->world
  /// extrinsic from ARCore, translation in the 4th column). [keyframeId] is a
  /// stable per-keyframe key (e.g. the pose-sidecar timestamp) — re-feeding the
  /// same id is a [CartyFuseStatus.duplicate] no-op (literal idempotency).
  ///
  /// The native boundary ABORTS on a non-finite pose entry or a wrong-shaped
  /// pose (Tiger Style), so we validate [pose] here first (length 16, all
  /// finite) and throw a recoverable [ArgumentError] rather than crashing the
  /// process at the FFI line. Returns the [CartyFuseStatus]; only
  /// [CartyFuseStatus.ok] mutates the grid.
  CartyFuseStatus accrete({
    required CartyOrthoMapHandle observation,
    required List<double> pose,
    required int keyframeId,
  }) {
    _ensureLive();
    observation._ensureLive();
    if (pose.length != 16) {
      throw ArgumentError.value(
          pose.length, 'pose.length', 'a 4x4 pose must have 16 entries');
    }
    for (var i = 0; i < 16; i++) {
      if (!pose[i].isFinite) {
        throw ArgumentError.value(pose[i], 'pose[$i]', 'must be finite');
      }
    }
    final posePtr = malloc<CartyPose>();
    try {
      _fillPose(posePtr, pose);
      final rc = _carty._bindings.carty_world_grid_accrete(
        _handle,
        observation._handle,
        posePtr,
        keyframeId,
      );
      return CartyFuseStatus._fromCode(rc);
    } finally {
      malloc.free(posePtr);
    }
  }

  /// The metric sibling of [accrete]; same ownership/idempotency contract, adds
  /// K + full extrinsics (K re-enters here). Registers ONE raw [frame] into the
  /// persistent world grid using real camera intrinsics [intrinsics] (fx, fy, cx,
  /// cy) and the full [pose] (16-element 4x4 row-major cam->world). This is the
  /// real-extrinsics path — precise metric reconstruction rather than
  /// the fixed-pose approximation of [accrete].
  ///
  /// The native boundary ABORTS on a non-finite K/pose entry, bad dims, channels
  /// not in {3,4}, or a frame size mismatch (Tiger Style), so we validate all
  /// inputs first and throw a recoverable [ArgumentError] rather than crashing the
  /// process at the FFI line. Returns the [CartyFuseStatus]; only
  /// [CartyFuseStatus.ok] mutates the grid.
  CartyFuseStatus accreteFromFrame({
    required CartyFrameBuffer frame,
    required int width,
    required int height,
    required int channels,
    required List<double> intrinsics, // fx, fy, cx, cy
    required List<double> pose, // 16-element 4x4 row-major cam->world
    required int keyframeId,
  }) {
    _ensureLive();
    frame._ensureLive();
    if (intrinsics.length != 4) {
      throw ArgumentError.value(
          intrinsics.length, 'intrinsics.length', 'must have 4 entries (fx,fy,cx,cy)');
    }
    for (var i = 0; i < 4; i++) {
      if (!intrinsics[i].isFinite) {
        throw ArgumentError.value(intrinsics[i], 'intrinsics[$i]', 'must be finite');
      }
    }
    if (pose.length != 16) {
      throw ArgumentError.value(
          pose.length, 'pose.length', 'a 4x4 pose must have 16 entries');
    }
    for (var i = 0; i < 16; i++) {
      if (!pose[i].isFinite) {
        throw ArgumentError.value(pose[i], 'pose[$i]', 'must be finite');
      }
    }
    if (channels != 3 && channels != 4) {
      throw ArgumentError.value(channels, 'channels', 'must be 3 or 4');
    }
    if (width <= 0) {
      throw ArgumentError.value(width, 'width', 'must be > 0');
    }
    if (height <= 0) {
      throw ArgumentError.value(height, 'height', 'must be > 0');
    }
    final expected = width * height * channels;
    if (expected != frame.bytes.length) {
      throw ArgumentError(
          'frame is ${frame.bytes.length} bytes != $width*$height*$channels '
          '($expected) — accreteFromFrame precondition');
    }
    // Allocate INSIDE try (init null outside): if the second malloc throws,
    // finally still frees the first — nothing leaks on an allocation failure.
    Pointer<CartyIntrinsics>? kPtr;
    Pointer<CartyPose>? posePtr;
    try {
      kPtr = malloc<CartyIntrinsics>();
      posePtr = malloc<CartyPose>();
      _fillIntrinsics(kPtr, intrinsics);
      _fillPose(posePtr, pose);
      final rc = _carty._bindings.carty_world_grid_accrete_from_frame(
        _handle,
        frame._handle,
        width,
        height,
        channels,
        kPtr,
        posePtr,
        keyframeId,
      );
      return CartyFuseStatus._fromCode(rc);
    } finally {
      if (kPtr != null) malloc.free(kPtr);
      if (posePtr != null) malloc.free(posePtr);
    }
  }

  /// The DEPTH path (depth reprojection): folds a reprojected raw depth buffer
  /// into the grid at each hit's real world-Y band — the depth-aware sibling of
  /// [accreteFromFrame]. [depth] is row-major uint16 millimetres of length
  /// [dw]*[dh] (0 = hole, skipped); [intrinsics] is the depth-camera {fx,fy,cx,cy}
  /// already scaled to dw×dh; [pose] is the 16-element 4x4 row-major cam->world of
  /// the PHYSICAL SENSOR (use [DepthBlock.toSensorPoseMatrix], NOT the display
  /// pose). Same ownership/idempotency/status contract as [accreteFromFrame].
  ///
  /// The native boundary ABORTS on a non-finite K/pose or bad dims, so we validate
  /// first and throw a recoverable [ArgumentError] rather than crashing the process.
  CartyFuseStatus accreteFromDepth({
    required Uint16List depth,
    required int dw,
    required int dh,
    Uint8List? conf,
    required List<double> intrinsics, // fx, fy, cx, cy
    required List<double> pose, // 16-element 4x4 row-major sensor cam->world
    required int keyframeId,
  }) {
    _ensureLive();
    if (intrinsics.length != 4) {
      throw ArgumentError.value(intrinsics.length, 'intrinsics.length',
          'must have 4 entries (fx,fy,cx,cy)');
    }
    for (var i = 0; i < 4; i++) {
      if (!intrinsics[i].isFinite) {
        throw ArgumentError.value(intrinsics[i], 'intrinsics[$i]', 'must be finite');
      }
    }
    if (pose.length != 16) {
      throw ArgumentError.value(
          pose.length, 'pose.length', 'a 4x4 pose must have 16 entries');
    }
    for (var i = 0; i < 16; i++) {
      if (!pose[i].isFinite) {
        throw ArgumentError.value(pose[i], 'pose[$i]', 'must be finite');
      }
    }
    if (dw <= 0) throw ArgumentError.value(dw, 'dw', 'must be > 0');
    if (dh <= 0) throw ArgumentError.value(dh, 'dh', 'must be > 0');
    if (depth.length != dw * dh) {
      throw ArgumentError(
          'depth is ${depth.length} elements != $dw*$dh (${dw * dh}) '
          '— accreteFromDepth precondition');
    }
    if (conf != null && conf.length != dw * dh) {
      throw ArgumentError(
          'conf.length ${conf.length} != dw*dh ${dw * dh} '
          '— accreteFromDepth precondition');
    }
    // Allocate INSIDE try (init null outside): if any later malloc throws,
    // finally still frees what was acquired — nothing leaks on failure.
    Pointer<Uint16>? depthPtr;
    Pointer<CartyIntrinsics>? kPtr;
    Pointer<CartyPose>? posePtr;
    Pointer<Uint8>? confPtr;
    try {
      depthPtr = malloc<Uint16>(depth.length);
      kPtr = malloc<CartyIntrinsics>();
      posePtr = malloc<CartyPose>();
      confPtr = conf == null ? nullptr : malloc<Uint8>(conf.length);
      depthPtr.asTypedList(depth.length).setAll(0, depth);
      if (conf != null) confPtr.asTypedList(conf.length).setAll(0, conf);
      _fillIntrinsics(kPtr, intrinsics);
      _fillPose(posePtr, pose);
      final rc = _carty._bindings.carty_world_grid_accrete_from_depth(
        _handle,
        depthPtr,
        dw,
        dh,
        confPtr,
        kPtr,
        posePtr,
        keyframeId,
      );
      return CartyFuseStatus._fromCode(rc);
    } finally {
      if (depthPtr != null) malloc.free(depthPtr);
      if (kPtr != null) malloc.free(kPtr);
      if (posePtr != null) malloc.free(posePtr);
      if (confPtr != null && confPtr != nullptr) malloc.free(confPtr);
    }
  }

  /// Frees the native grid deterministically. Idempotent; detaches the finalizer
  /// so the free runs exactly once.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _carty._worldGridFinalizer.detach(this);
    _carty._bindings.carty_world_grid_free(_handle);
    _handle = nullptr;
  }

  void _ensureLive() {
    if (_disposed) {
      throw StateError('CartyWorldGridHandle used after dispose()');
    }
  }
}

/// Copies a validated 16-entry row-major cam->world pose into native memory.
void _fillPose(Pointer<CartyPose> dst, List<double> pose) {
  assert(pose.length == CARTY_POSE_LEN);
  for (var i = 0; i < CARTY_POSE_LEN; i++) {
    dst.ref.cam_to_world[i] = pose[i];
  }
}

/// Copies validated {fx, fy, cx, cy} into native memory.
void _fillIntrinsics(Pointer<CartyIntrinsics> dst, List<double> intrinsics) {
  assert(intrinsics.length == 4);
  dst.ref
    ..fx_px = intrinsics[0]
    ..fy_px = intrinsics[1]
    ..cx_px = intrinsics[2]
    ..cy_px = intrinsics[3];
}
