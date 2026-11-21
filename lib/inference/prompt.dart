/// Multimodal prompt assembly for Carty's on-device cartographer.
///
/// This is the **steering layer**: it lays out the exact prompt the Gemma 4 E2B
/// model sees so that its output is a *strict* map-update JSON document the
/// version-control engine can apply (see [MapUpdate]). The layout has three
/// segments — an **image segment** (the analyzed video frame, which crosses the
/// FFI boundary as a bridge-owned tensor, NOT as text), a **text instruction**,
/// and a normalized **spatial bound** that focuses the model on one region.
///
/// CONTEXT MANAGEMENT (mobile-first, bounded by construction):
/// on-device the context window and RAM are scarce, so everything here is
/// bounded — the instruction is length-capped, the image is referenced by a
/// small descriptor (its pixels never enter the prompt text), and the output is
/// budgeted to [maxOutputBytes] (mirrors the native `CARTY_MAP_UPDATE_MAX`
/// ceiling). The render is **deterministic**: identical inputs produce identical
/// prompt text, which keeps inference reproducible and cache-friendly.
library;

import '../carty_bindings_generated.dart'
    show CARTY_MAP_UPDATE_MAX, CARTY_FRAME_MAX_DIM, CARTY_FRAME_MAX_CHANNELS;
import '../vc/map_node.dart' show kMaxNodes, kMaxConnections;

/// The strict output contract handed to the model. The model MUST emit exactly
/// one JSON object of this shape and nothing else (no prose, no code fences) —
/// the parser is tolerant of stray wrapping but the model is steered to be
/// strict. Kept in sync with [MapUpdate.parse]'s schema.
const String kMapUpdateSchemaContract = '''
You are Carty's on-device cartographer. Convert the analyzed map region into a
strict map-update document. Output ONLY one JSON object, no prose, no markdown.

{"ops": [ <op>, ... ]}

Each <op> is exactly one of:
  {"op":"add","id":<int 0..${kMaxNodes - 1}>,"type":<string>,"description":<string>,"x":<0..1>,"y":<0..1>,"confidence":<0..1>,"connections":[<int>,...]}
  {"op":"update","id":<int>, <subset of: type,description,x,y,confidence,connections>}
  {"op":"remove","id":<int>}
  {"op":"connect","id":<int>,"connections":[<int>,...]}

Rules:
  - Coordinates x,y are normalized to the analyzed region, each in [0,1].
  - At most $kMaxConnections connections per node; ids in 0..${kMaxNodes - 1}.
  - "add" introduces a new id; "update"/"connect" target an existing id.
''';

/// A normalized rectangular region of interest, each coordinate in `[0, 1]`.
/// Steers the model at a sub-frame so its token budget is spent on one area.
class SpatialBounds {
  final double x0;
  final double y0;
  final double x1;
  final double y1;

  SpatialBounds(this.x0, this.y0, this.x1, this.y1) {
    // Preconditions are live invariants. The native boundary
    // (carty_infer_map_update) asserts the same, so we fail here first with a
    // readable message rather than crashing the process at the FFI line.
    assert(x0.isFinite && y0.isFinite && x1.isFinite && y1.isFinite,
        'bounds must be finite');
    assert(x0 >= 0.0 && y0 >= 0.0 && x1 <= 1.0 && y1 <= 1.0,
        'bounds must be in [0,1]');
    assert(x0 <= x1 && y0 <= y1, 'bounds must be ordered (x0<=x1, y0<=y1)');
  }

  /// The whole frame — the default region when no focusing is needed.
  factory SpatialBounds.full() => SpatialBounds(0.0, 0.0, 1.0, 1.0);

  Map<String, Object?> toJson() => {'x0': x0, 'y0': y0, 'x1': x1, 'y1': y1};

  @override
  String toString() => 'SpatialBounds($x0,$y0 -> $x1,$y1)';
}

/// A fully-assembled multimodal prompt: image segment descriptor + text
/// instruction + spatial bound + output budget. Immutable and deterministic.
class MultimodalPrompt {
  /// Upper bound on the free-text instruction (context management). Long
  /// instructions waste the scarce on-device context window.
  static const int kMaxInstructionChars = 2048;

  /// Default output budget — mirrors the native map-update ceiling so Dart and
  /// C agree on how many bytes a single update may produce.
  static const int kDefaultMaxOutputBytes = CARTY_MAP_UPDATE_MAX;

  /// Free-text task for the model (e.g. "Label rooms and connecting doors").
  final String instruction;

  /// The region of the frame the model should focus on.
  final SpatialBounds bounds;

  /// Descriptor of the image-segment tensor that crosses the FFI boundary
  /// alongside this prompt. The pixels themselves are NOT in the text.
  final int imageWidth;
  final int imageHeight;
  final int imageChannels;

  /// Output token/byte budget for this generation (context management).
  final int maxOutputBytes;

  MultimodalPrompt({
    required this.instruction,
    SpatialBounds? bounds,
    required this.imageWidth,
    required this.imageHeight,
    required this.imageChannels,
    this.maxOutputBytes = kDefaultMaxOutputBytes,
  }) : bounds = bounds ?? SpatialBounds.full() {
    assert(instruction.isNotEmpty, 'instruction must be non-empty');
    assert(instruction.length <= kMaxInstructionChars,
        'instruction exceeds $kMaxInstructionChars chars (context budget)');
    assert(imageWidth > 0 && imageWidth <= CARTY_FRAME_MAX_DIM,
        'imageWidth out of range');
    assert(imageHeight > 0 && imageHeight <= CARTY_FRAME_MAX_DIM,
        'imageHeight out of range');
    assert(imageChannels > 0 && imageChannels <= CARTY_FRAME_MAX_CHANNELS,
        'imageChannels out of range');
    assert(maxOutputBytes > 0 && maxOutputBytes <= CARTY_MAP_UPDATE_MAX,
        'maxOutputBytes out of range (<= $CARTY_MAP_UPDATE_MAX)');
  }

  /// Deterministic text layout fed to the model. Three labeled segments in a
  /// fixed order so the same inputs always yield the same prompt string.
  String render() {
    final b = bounds;
    final buf = StringBuffer()
      ..writeln('### CONTRACT')
      ..writeln(kMapUpdateSchemaContract.trim())
      ..writeln()
      ..writeln('### IMAGE SEGMENT')
      ..writeln(
          '<image tensor ${imageWidth}x${imageHeight}x$imageChannels NHWC uint8>')
      ..writeln('region: [${b.x0}, ${b.y0}] -> [${b.x1}, ${b.y1}]')
      ..writeln()
      ..writeln('### INSTRUCTION')
      ..writeln(instruction.trim())
      ..writeln()
      ..write('### OUTPUT (strict JSON only)');
    return buf.toString();
  }

  @override
  String toString() =>
      'MultimodalPrompt(${imageWidth}x${imageHeight}x$imageChannels, $bounds)';
}
