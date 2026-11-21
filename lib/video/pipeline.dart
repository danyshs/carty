/// Video → map pipeline: folds an [ExtractedFrame] stream through the
/// FFI bridge into a live-accreting [MapGraph], OFF the UI thread.
///
/// Two layers, deliberately separated so the FFI path is testable without an
/// isolate or a Flutter binding:
///
///   1. [driveFrame] — the synchronous core, the Geometric→Semantic fusion
///     . Copies ONE frame's pixels (zero-copy) into a bridge-owned
///      buffer, orthorectifies it into a top-down occupancy grid
///      (`carty_ortho_project`), drives Gemma 4 E2B CONDITIONED ON that grid
///      (`carty_infer_map_update_ortho`, with the Dart-owned `{"ops":[...]}`
///      contract passed down), runs the model's output through the authoritative
///      Dart [MapUpdate] parser — the SOLE extraction semantics now that the
///      native pre-gate was retired) — and accretes the result
///      onto the running graph. It NEVER throws for a model-domain failure:
///      ENOMODEL, malformed output, or a graph conflict all return a status
///      + note with the graph left untouched. Only a corrupt FFI boundary crashes.
///
///   2. [VideoToMapPipeline] — spawns a background [Isolate] that opens the
///      bridge there, decodes frames (capped at [kMaxSampleFps]), and folds them
///      through [driveFrame], posting a [PipelineEvent] back so the main isolate
///      stays responsive. A real Gemma decode is
///      tens of seconds, so the isolate THROTTLES hard: while an inference is
///      active, freshly-decoded frames are DROPPED down to a single newest-wins
///      slot, bounding memory regardless of clip length. The graph snapshot
///      crosses the isolate boundary as a canonical GeoJSON FeatureCollection.
///
/// Host reality: when the host LiteRT runtime env vars (`CARTY_LITERT_RUNTIME` /
/// `CARTY_GEMMA_MODEL`) are exported, the Dart-facing `libcarty.so` LINKS the real
/// LiteRT subprocess path (`CARTY_HAVE_LITERT`), so the map ACCRETES real nodes
/// from the grid — each frame is a genuine ~26–60 s Gemma decode. With those vars
/// unset (the default), or on the pre-JNI Android build, the same call safe-fails
/// ENOMODEL and the map stays honestly empty; the architecture is identical either way.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';

import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;

import '../carty.dart';
import '../carty_bindings_generated.dart' show CARTY_INFER_ENOMODEL;
import '../inference/engine.dart' show kMaxVideoFrames;
import '../inference/map_update.dart';
import '../vc/map_graph.dart';
import 'frame_extractor.dart';

/// Outcome of pushing a single frame through the bridge. Pure data; safe by
/// construction (no failure mode here throws).
class FrameDriveResult {
  /// The graph AFTER this frame — equal to the input graph if nothing applied.
  final MapGraph graph;

  /// Native/inference status: >= 0 means the model produced (and we applied)
  /// output; < 0 is a safe failure ([CARTY_INFER_ENOMODEL] etc.). [kDriveBadOutput]
  /// marks well-formed FFI but unusable model text.
  final int status;

  /// Human-readable note for the UI/log (never null).
  final String note;

  const FrameDriveResult({
    required this.graph,
    required this.status,
    required this.note,
  });

  /// The model ran and its output was applied to the graph.
  bool get applied => status >= 0;
}

/// Status sentinel: the bridge returned cleanly but the model TEXT was not a
/// usable map-update (malformed JSON or a graph conflict). Distinct from the
/// native negative codes; positive-shifted out of their range.
const int kDriveBadOutput = -200;

/// Drives ONE [frame] through the Geometric→Semantic fusion into
/// [base], returning the new graph (or [base] unchanged) plus a status. SAFE by
/// construction: the only thing that aborts is a genuinely corrupt boundary
/// (NULL handle), which is a fatal bug, not a recoverable state.
///
/// The pipeline per frame is:
///   1. zero-copy the pixels into a bridge-owned tensor;
///   2. GEOMETRIC — `carty_ortho_project` → a top-down occupancy grid, so node
///      coordinates land in STABLE ground space, not raw oblique-pixel space;
///   3. SEMANTIC — `carty_infer_map_update_ortho` drives Gemma 4 E2B conditioned
///      on that grid; the Dart-owned `{"ops":[...]}` contract ([instruction]) is
///      passed down and the "Spatial Context" grid summary is framed natively;
///   4. the authoritative Dart [MapUpdate] parser is the SOLE extraction
///      semantics — malformed text raises and never mutates the map (the old
///      native pre-gate was retired);
///   5. the parsed update is merged onto the running graph.
///
/// Both the bridge tensor and the ortho grid are disposed deterministically
/// (exactly-once free) before returning. [instruction] is the strict output
/// contract (`kMapUpdateSchemaContract`), passed through to the native decode.
FrameDriveResult driveFrame({
  required Carty carty,
  required CartyModelHandle model,
  required ExtractedFrame frame,
  required MapGraph base,
  required String instruction,
}) {
  // Allocate the bridge-owned tensor; dimensions were already bounded when the
  // frame was constructed, so this can only fail on a real boundary violation.
  final buffer = carty.allocFrame(
    width: frame.width,
    height: frame.height,
    channels: frame.channels,
  );
  try {
    // Precondition: the frame is exactly one tensor's worth of bytes.
    assert(frame.rgba.length == buffer.lengthInBytes,
        'frame ${frame.rgba.length} != buffer ${buffer.lengthInBytes}');
    // Zero-copy write straight into the native, bridge-owned pixel buffer.
    buffer.bytes.setAll(0, frame.rgba);

    // GEOMETRIC stage: orthorectify the oblique frame into a top-down grid.
    final ortho = carty.orthoProject(
      buffer,
      width: frame.width,
      height: frame.height,
      channels: frame.channels,
    );
    try {
      // SEMANTIC stage: a real Gemma decode conditioned on the occupancy grid.
      // The strict {"ops":[...]} contract ([instruction]) is Dart-owned and
      // passed down; the bridge frames it with the grid summary natively.
      final inf = model.inferMapUpdateOrtho(ortho, instruction: instruction);
      if (inf.status < 0) {
        // The bridge was reached and answered with a safe negative status
        // (e.g. ENOMODEL when LiteRT is not linked / configured). Graph untouched.
        return FrameDriveResult(
          graph: base,
          status: inf.status,
          note: inf.status == CARTY_INFER_ENOMODEL
              ? 'frame ${frame.index}: ENOMODEL (LiteRT/Gemma not linked here)'
              : 'frame ${frame.index}: inference safe-failed (${inf.status})',
        );
      }

      // The authoritative Dart parser is the SOLE extraction semantics
      //): malformed model text raises MapUpdateFormatException
      // and never mutates the map. The old native pre-gate
      // (carty_validate_map_update_json) duplicated this and was retired.
      try {
        final next = MapUpdate.parse(inf.text).apply(base);
        return FrameDriveResult(
          graph: next,
          status: inf.status,
          note: 'frame ${frame.index}: applied (${next.nodeCount} nodes)',
        );
      } on MapUpdateFormatException catch (e) {
        return FrameDriveResult(
            graph: base, status: kDriveBadOutput, note: 'malformed: ${e.message}');
      } on MapUpdateConflictException catch (e) {
        return FrameDriveResult(
            graph: base, status: kDriveBadOutput, note: 'conflict: ${e.message}');
      }
    } finally {
      ortho.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

// ---- Pipeline events (main-isolate facing) --------------------------------

/// One observation from a running pipeline. Sealed so the UI must handle every
/// case.
sealed class PipelineEvent {
  const PipelineEvent();
}

/// A frame was processed; [graph] is the live map AFTER it.
class PipelineFrame extends PipelineEvent {
  final int index;
  final int processed;

  /// Frames decoded but DROPPED by the throttle so far (an inference was active
  /// when they arrived). Surfaced so the UI can show the real:processed ratio.
  final int dropped;
  final int status;
  final String note;
  final MapGraph graph;
  const PipelineFrame({
    required this.index,
    required this.processed,
    required this.dropped,
    required this.status,
    required this.note,
    required this.graph,
  });
}

/// The background isolate's inference-busy state flipped. [isProcessing] is true
/// while a (multi-second) grid-conditioned Gemma decode is actively running, so
/// the UI can show a loading overlay over the map canvas and frames decoded in
/// the meantime are being dropped by the throttle.
class PipelineProcessing extends PipelineEvent {
  final bool isProcessing;
  const PipelineProcessing(this.isProcessing);
}

/// The clip finished cleanly; [graph] is the final map and [frameCount] the
/// number of frames folded in.
class PipelineDone extends PipelineEvent {
  final int frameCount;
  final MapGraph graph;
  const PipelineDone({required this.frameCount, required this.graph});
}

/// The pipeline failed before completion (e.g. ffmpeg/decoder error). Recoverable
/// — the UI reports it; nothing is half-committed.
class PipelineFailed extends PipelineEvent {
  final String message;
  const PipelineFailed(this.message);
}

/// Sendable configuration handed to the background isolate. Only primitives +
/// the reply [SendPort], so it crosses the isolate boundary cleanly.
class _PipelineConfig {
  final SendPort reply;
  final String videoPath;
  final String bridgeLibrary;
  final String modelPath;
  final int targetWidth;
  final int targetHeight;
  final double sampleFps;
  final int maxFrames;
  final String instruction;

  /// Token that lets the spawned isolate talk to platform channels (the Android
  /// frame source). Null on hosts without a root isolate (pure-Dart tests) or
  /// where the ffmpeg source is used — selection falls back to ffmpeg then.
  final RootIsolateToken? rootIsolateToken;

  const _PipelineConfig({
    required this.reply,
    required this.videoPath,
    required this.bridgeLibrary,
    required this.modelPath,
    required this.targetWidth,
    required this.targetHeight,
    required this.sampleFps,
    required this.maxFrames,
    required this.instruction,
    required this.rootIsolateToken,
  });
}

/// Runs the video→map fold on a background isolate, surfacing a [PipelineEvent]
/// stream the UI can drive a [MapGraph] painter from. The UI thread never
/// touches ffmpeg, the decoder bytes, or the FFI calls — all of that lives in
/// the spawned isolate.
class VideoToMapPipeline {
  /// Hard ceiling on the decode sample rate (frames/sec). The incoming video
  /// stream is downsampled to AT MOST this rate before it ever reaches the FFI
  /// bridge — a single grid-conditioned Gemma decode is tens of seconds, so
  /// decoding faster than this only feeds the throttle more frames to drop.
  static const double kMaxSampleFps = 20.0;

  /// Default region instruction for the on-device cartographer.
  static const String kDefaultInstruction =
      'Reconstruct the overhead D&D-style map region: label rooms, doors, '
      'corridors and the connections between them.';

  /// Starts the pipeline and returns its event stream. Cancelling the stream
  /// subscription tears the isolate down. [bridgeLibrary] is the bridge `.so`
  /// (a name like `libcarty.so` resolved by the loader, or an absolute path for
  /// host/dev runs).
  Stream<PipelineEvent> run({
    required String videoPath,
    required String modelPath,
    String bridgeLibrary = 'libcarty.so',
    int targetWidth = 224,
    int targetHeight = 224,
    double sampleFps = 1.0,
    int maxFrames = kMaxVideoFrames,
    String instruction = kDefaultInstruction,
  }) {
    // Downsample to AT MOST kMaxSampleFps before any byte reaches the bridge.
    final cappedFps =
        (sampleFps > 0 && sampleFps.isFinite) ? sampleFps : 1.0;
    final effectiveFps =
        cappedFps > kMaxSampleFps ? kMaxSampleFps : cappedFps;
    final controller = StreamController<PipelineEvent>();
    final receive = ReceivePort();
    Isolate? isolate;
    var closed = false;

    Future<void> shutdown() async {
      if (closed) return;
      closed = true;
      receive.close();
      isolate?.kill(priority: Isolate.immediate);
      if (!controller.isClosed) await controller.close();
    }

    receive.listen((Object? message) {
      if (message is! Map) return;
      switch (message['kind']) {
        case 'processing':
          if (controller.isClosed) return;
          controller.add(PipelineProcessing(message['busy'] as bool));
        case 'frame':
          if (controller.isClosed) return;
          controller.add(PipelineFrame(
            index: message['index'] as int,
            processed: message['processed'] as int,
            dropped: message['dropped'] as int,
            status: message['status'] as int,
            note: message['note'] as String,
            graph: MapGraph.fromFeatureCollection(
                (message['fc'] as Map).cast<String, Object?>()),
          ));
        case 'done':
          if (!controller.isClosed) {
            controller.add(PipelineDone(
              frameCount: message['count'] as int,
              graph: MapGraph.fromFeatureCollection(
                  (message['fc'] as Map).cast<String, Object?>()),
            ));
          }
          shutdown();
        case 'error':
          if (!controller.isClosed) {
            controller.add(PipelineFailed(message['message'] as String));
          }
          shutdown();
      }
    });

    controller.onCancel = shutdown;

    Isolate.spawn(
      _isolateEntry,
      _PipelineConfig(
        reply: receive.sendPort,
        videoPath: videoPath,
        bridgeLibrary: bridgeLibrary,
        modelPath: modelPath,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
        sampleFps: effectiveFps,
        maxFrames: maxFrames,
        instruction: instruction,
        // Captured on the root isolate so the spawned isolate can reach the
        // Android frame-source channel; null in pure-Dart test contexts.
        rootIsolateToken: RootIsolateToken.instance,
      ),
    ).then((spawned) {
      isolate = spawned;
      if (closed) spawned.kill(priority: Isolate.immediate);
    }).catchError((Object e) {
      if (!controller.isClosed) {
        controller.add(PipelineFailed('failed to spawn pipeline isolate: $e'));
      }
      shutdown();
    });

    return controller.stream;
  }
}

/// Picks the frame source for the running platform. On Android the platform
/// decoder is the only one available (ffmpeg is absent), reached over a
/// MethodChannel — which first needs THIS spawned isolate's binary messenger
/// bootstrapped from the root isolate's [token]. Everywhere else (the Nix host /
/// CI loop) the ffmpeg source is used, exactly as before. If we are on Android
/// but somehow have no token, we fall through to ffmpeg, which fails honestly
/// (file-not-found) rather than silently doing nothing.
VideoFrameExtractor _selectExtractor(RootIsolateToken? token) {
  if (Platform.isAndroid && token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    return const AndroidVideoFrameExtractor();
  }
  return const FfmpegVideoFrameExtractor();
}

/// Background-isolate body: opens the bridge HERE (per-isolate FFI), decodes
/// frames, and folds them through [driveFrame] under a STATEFUL THROTTLE, posting
/// events. Any throw is reported as a single 'error' event — never an isolate
/// crash the parent cannot observe.
///
/// Throttle invariant (bounded by construction): a real
/// grid-conditioned Gemma decode is tens of seconds, while the extractor decodes
/// frames far faster. So AT MOST one inference runs at a time and AT MOST one
/// frame — the freshest — waits behind it. Every frame decoded while an inference
/// is active overwrites that single slot (newest-wins) and is counted DROPPED, so
/// frame memory is O(1) regardless of clip length. We deliberately do NOT run an
/// inference per decoded frame.
Future<void> _isolateEntry(_PipelineConfig config) async {
  final reply = config.reply;
  Carty carty;
  CartyModelHandle model;
  try {
    carty = Carty.fromLibrary(DynamicLibrary.open(config.bridgeLibrary));
    model = carty.loadModel(config.modelPath);
  } catch (e) {
    reply.send({'kind': 'error', 'message': 'bridge load failed: $e'});
    return;
  }

  var graph = MapGraph.empty();
  var processed = 0;
  var dropped = 0;

  // Throttle state: one inference in flight (`busy`), one freshest frame queued
  // (`pending`). `streamDone` flips when the decoder is exhausted.
  var busy = false;
  ExtractedFrame? pending;
  var streamDone = false;
  final allDone = Completer<void>();

  void finish() {
    if (!allDone.isCompleted) allDone.complete();
  }

  void process() {
    // Only ever entered when idle (no inference in flight).
    assert(!busy, 'process() re-entered while an inference is active');
    final frame = pending;
    if (frame == null) {
      if (streamDone) finish();
      return;
    }
    pending = null;
    busy = true;
    reply.send({'kind': 'processing', 'busy': true});
    // Defer the (blocking, multi-second) decode onto a fresh event-loop task so
    // frames decoded in the meantime reach the listener and coalesce into the
    // single `pending` slot (newest-wins) instead of being processed in lockstep.
    Future<void>(() {
      final result = driveFrame(
        carty: carty,
        model: model,
        frame: frame,
        base: graph,
        instruction: config.instruction,
      );
      graph = result.graph;
      processed++;
      reply.send({
        'kind': 'frame',
        'index': frame.index,
        'processed': processed,
        'dropped': dropped,
        'status': result.status,
        'note': result.note,
        'fc': graph.toFeatureCollection(),
      });
    }).whenComplete(() {
      busy = false;
      if (pending != null) {
        process(); // a fresher frame waited — keep folding
      } else {
        reply.send({'kind': 'processing', 'busy': false});
        if (streamDone) finish();
      }
    });
  }

  late StreamSubscription<ExtractedFrame> sub;
  try {
    final extractor = _selectExtractor(config.rootIsolateToken);
    sub = extractor
        .extract(
          config.videoPath,
          targetWidth: config.targetWidth,
          targetHeight: config.targetHeight,
          sampleFps: config.sampleFps,
          maxFrames: config.maxFrames,
        )
        .listen(
      (frame) {
        // Newest-wins: a frame arriving while one is in flight or already queued
        // displaces the queued one, which is DROPPED (bounded single-slot buffer).
        if (busy || pending != null) dropped++;
        pending = frame;
        if (!busy) process();
      },
      onError: (Object e) {
        reply.send({'kind': 'error', 'message': '$e'});
        finish();
      },
      onDone: () {
        streamDone = true;
        // If nothing is in flight or waiting we are done; otherwise the
        // processor drains `pending` and finishes from its whenComplete.
        if (!busy && pending == null) finish();
      },
      cancelOnError: true,
    );

    await allDone.future;
    await sub.cancel();

    reply.send({
      'kind': 'done',
      'count': processed,
      'dropped': dropped,
      'fc': graph.toFeatureCollection(),
    });
  } catch (e) {
    reply.send({'kind': 'error', 'message': '$e'});
  } finally {
    model.dispose();
  }
}
