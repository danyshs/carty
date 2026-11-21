/// Inference orchestration: wires a multimodal [MultimodalPrompt]
/// through a "raw inferer" to the strict [MapUpdate] parser and, optionally, to
/// a version-control commit. This is the seam between the model and the map.
///
/// The model call is injected as a [RawInferer] so the deterministic pieces —
/// prompt layout, parsing, applying, committing — are fully testable WITHOUT
/// loading the (multi-gigabyte, not-yet-acquired) Gemma 4 E2B weights. The
/// production wiring lives in [nativeInferer], which calls the FFI bridge; with
/// LiteRT unlinked that path raises [InferenceUnavailable] rather than
/// fabricating a result (fail safely).
library;

import '../carty.dart';
import '../carty_bindings_generated.dart' show CARTY_INFER_ENOMODEL;
import '../vc/map_graph.dart';
import '../vc/repository.dart';
import 'map_update.dart';
import 'prompt.dart';

/// Upper bound on frames folded in a single video clip (bounded
/// by construction). A clip longer than this is a programming error, not silent
/// truncation — it is rejected. Matches the spatial-graph node ceiling so a
/// clip cannot, even pathologically, outgrow the map it builds.
const int kMaxVideoFrames = 1024;

/// Produces the model's raw text output for a given prompt. Injected into
/// [InferenceEngine] so tests can supply canned Gemma output and production can
/// supply the real (FFI) path.
typedef RawInferer = String Function(MultimodalPrompt prompt);

/// The model could not run (e.g. LiteRT/weights not linked, or the native call
/// returned a negative status). Recoverable — never a crash.
class InferenceUnavailable implements Exception {
  final int status;
  final String message;
  InferenceUnavailable(this.status, this.message);
  @override
  String toString() => 'InferenceUnavailable($status): $message';
}

/// Ties a [RawInferer] to the parse/apply/commit pipeline.
class InferenceEngine {
  final RawInferer _infer;
  const InferenceEngine(this._infer);

  /// Runs the model for [prompt] and applies the resulting [MapUpdate] onto
  /// [base], returning a NEW graph. Propagates [MapUpdateFormatException] /
  /// [MapUpdateConflictException] on bad output, and [InferenceUnavailable] if
  /// the model could not run — in all cases [base] is left untouched.
  MapGraph generate(MapGraph base, MultimodalPrompt prompt) {
    final raw = _infer(prompt);
    return MapUpdate.parse(raw).apply(base);
  }

  /// [generate] against the current branch tip, then commits the result,
  /// advancing the branch. Returns the new commit id. On any failure nothing is
  /// written (commit only runs after a successful apply).
  String commitGeneration(
    MapRepository repo,
    MultimodalPrompt prompt, {
    required int timestampMillis,
    String message = 'ai: map update',
    String author = 'gemma-4-e2b',
  }) {
    final base = repo.readGraphAt(repo.headCommitId);
    final next = generate(base, prompt);
    return repo.commit(
      next,
      message: message,
      author: author,
      timestampMillis: timestampMillis,
    );
  }

  /// Folds the model over an ordered sequence of [prompts] — one per analyzed
  /// VIDEO frame/segment — accreting each frame's [MapUpdate] onto the running
  /// graph, so the map is built up across the clip. Returns the final graph.
  ///
  /// The fold is transactional toward the caller: the running
  /// graph is a local immutable value, so if any frame's output is malformed
  /// ([MapUpdateFormatException]), conflicts ([MapUpdateConflictException]), or
  /// the model cannot run ([InferenceUnavailable]), this throws and [base] —
  /// the caller's graph — is never mutated. Nothing is half-applied to it.
  ///
  /// Bounded by construction: at most [maxFrames] frames; a longer clip is a
  /// programming error and raises [ArgumentError] rather than truncating.
  MapGraph generateSequence(
    MapGraph base,
    List<MultimodalPrompt> prompts, {
    int maxFrames = kMaxVideoFrames,
  }) {
    assert(maxFrames > 0 && maxFrames <= kMaxVideoFrames,
        'maxFrames out of range (1..$kMaxVideoFrames)');
    if (prompts.length > maxFrames) {
      throw ArgumentError(
          'clip has ${prompts.length} frames > maxFrames $maxFrames');
    }
    var graph = base;
    for (final prompt in prompts) {
      graph = generate(graph, prompt);
    }
    return graph;
  }

  /// [generateSequence] over a whole clip, then commits the accreted result as
  /// ONE commit on the current branch tip (one commit per clip). Returns the new
  /// commit id. On any per-frame failure nothing is written (commit runs only
  /// after the full clip folds successfully).
  String commitSequence(
    MapRepository repo,
    List<MultimodalPrompt> prompts, {
    required int timestampMillis,
    int maxFrames = kMaxVideoFrames,
    String message = 'ai: clip map update',
    String author = 'gemma-4-e2b',
  }) {
    final base = repo.readGraphAt(repo.headCommitId);
    final next = generateSequence(base, prompts, maxFrames: maxFrames);
    return repo.commit(
      next,
      message: message,
      author: author,
      timestampMillis: timestampMillis,
    );
  }
}

/// Production [RawInferer] backed by the native bridge. Calls
/// `carty_infer_map_update` with the bridge-owned [imageSegment] tensor and the
/// prompt's bounds; on any negative status (e.g. [CARTY_INFER_ENOMODEL] while
/// LiteRT is unlinked) it throws [InferenceUnavailable]. The image segment must
/// outlive the call (the caller owns/disposes it).
RawInferer nativeInferer(CartyModelHandle model, CartyFrameBuffer imageSegment) {
  return (MultimodalPrompt prompt) {
    final b = prompt.bounds;
    final result = model.inferMapUpdate(
      imageSegment: imageSegment,
      textPrompt: prompt.render(),
      bx0: b.x0,
      by0: b.y0,
      bx1: b.x1,
      by1: b.y1,
      outputCapacity: prompt.maxOutputBytes,
    );
    if (result.status < 0) {
      throw InferenceUnavailable(
        result.status,
        result.status == CARTY_INFER_ENOMODEL
            ? 'LiteRT/Gemma 4 E2B weights not linked yet (native stub)'
            : 'native inference failed',
      );
    }
    return result.text;
  };
}
