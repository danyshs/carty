/// Deterministic replay of a pose sidecar. It exists so fusion is TDD-able
/// HEADLESSLY (test ladder rung 1): record on device → replay here
/// → identical fused grid. Determinism is the contract — same lines in, same
/// PoseSamples out, in file order; bounded ingestion means a malformed/truncated
/// line fails safely, never corrupts the stream.
library;

import 'dart:io';
import 'dart:typed_data';

import 'pose_sidecar.dart';

class ReplayHarness {
  ReplayHarness._(this.samples, this.malformedCount);

  /// Parse newline-delimited pose-sidecar [lines]. Blank/whitespace lines are
  /// skipped. A malformed line throws by default (FormatException naming the
  /// 1-based line number); [skipMalformed] drops it and increments
  /// [malformedCount] instead — for tolerant ingestion of a truncated capture.
  factory ReplayHarness.fromLines(Iterable<String> lines,
      {bool skipMalformed = false}) {
    final out = <PoseSample>[];
    var malformed = 0;
    var lineNo = 0;
    for (final raw in lines) {
      lineNo++;
      final line = raw.trim();
      if (line.isEmpty) continue;
      try {
        out.add(PoseSample.fromJsonLine(line));
      } on FormatException catch (e) {
        if (!skipMalformed) {
          throw FormatException('pose sidecar line $lineNo: ${e.message}', line);
        }
        malformed++;
      }
    }
    return ReplayHarness._(out, malformed);
  }

  final List<PoseSample> samples;
  final int malformedCount;

  /// Samples safe to fuse: TRACKING only, in file order. PAUSED poses are
  /// untrustworthy and must not accrete (they would smear the grid).
  Iterable<PoseSample> get trackingOnly =>
      samples.where((s) => s.state == TrackingState.tracking);
}

/// The depth/confidence buffers for one keyframe, read back from disk. Exists so
/// depth reprojection can reproject a recorded depth frame offline — the
/// whole point of depth recording. `confidence` is null when the keyframe recorded none.
class DepthFrame {
  DepthFrame({
    required this.depth,
    required this.confidence,
    required this.dw,
    required this.dh,
  });

  final Uint16List depth; // length dw*dh; value 0 = hole (depth reprojection/occlusion carving must skip)
  final Uint8List? confidence; // length dw*dh, or null
  final int dw, dh;
}

/// Loads [sample]'s sibling `.dep` blobs from [sidecarDir] into typed buffers.
/// Fails safe (FormatException) on a missing file or a byte length that does not
/// match the declared dw×dh×stride — a truncated/partial capture must never read
/// back as silently-wrong geometry (the sidecar invariant). Endianness is pinned
/// little-endian and asserted, so a future big-endian host can never byte-swap a
/// replay into corruption rather than failing loudly.
DepthFrame loadDepthFrame(String sidecarDir, PoseSample sample) {
  final block = sample.depth;
  if (block == null) {
    throw StateError('loadDepthFrame: keyframe ${sample.t} has no depth block');
  }
  assert(Endian.host == Endian.little,
      'replay assumes a little-endian host (sidecar .dep is little-endian)');
  final count = block.dw * block.dh;

  Uint8List readExact(String name, int expectedBytes) {
    final file = File('$sidecarDir/$name');
    if (!file.existsSync()) {
      throw FormatException('depth replay: missing .dep file "$name"');
    }
    final bytes = file.readAsBytesSync();
    if (bytes.length != expectedBytes) {
      throw FormatException(
          'depth replay: "$name" is ${bytes.length} bytes, expected $expectedBytes');
    }
    return bytes;
  }

  final depthBytes = readExact(block.depthPath, count * 2);
  // Copy into an aligned Uint16List view (LE host → bytes map directly).
  final depth = Uint16List.fromList(
      depthBytes.buffer.asUint16List(depthBytes.offsetInBytes, count));

  Uint8List? confidence;
  final confPath = block.confPath;
  if (confPath != null) {
    confidence = Uint8List.fromList(readExact(confPath, count));
  }

  return DepthFrame(
      depth: depth, confidence: confidence, dw: block.dw, dh: block.dh);
}
