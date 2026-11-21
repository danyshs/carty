/// The headless replay→fuse loop — the backbone of the Demo Spine,
/// exercised on the host before it ever runs live. It folds each TRACKING
/// keyframe's observation into ONE world grid and reports a SHA-256 of the grid
/// bytes: that hash is the deterministic signal the test ladder rests on (record
/// → replay → identical hash). It mutates nothing it does not own (the caller
/// owns grid + observations) and drops PAUSED poses (ReplayHarness.trackingOnly).
library;

import 'package:crypto/crypto.dart';

import '../carty.dart';
import 'replay.dart';
import 'pose_sidecar.dart';

typedef ObservationProvider = CartyOrthoMapHandle Function(PoseSample sample);

/// Supplies a raw camera frame for a given pose sample. The loop disposes the
/// returned [CartyFrameBuffer] immediately after folding it — the provider
/// must allocate a fresh buffer each call (mirrors [ObservationProvider]).
typedef FrameProvider = CartyFrameBuffer Function(PoseSample sample);

class FusionStats {
  const FusionStats({
    required this.accreted,
    required this.duplicate,
    required this.outOfBounds,
    required this.seenFull,
  });
  final int accreted, duplicate, outOfBounds, seenFull;
}

class FusionResult {
  const FusionResult({required this.stats, required this.gridSha256});
  final FusionStats stats;
  final String gridSha256;
}

class FusionLoop {
  FusionLoop(this.carty);
  final Carty carty;

  /// The metric replay path — folds each TRACKING keyframe's raw camera frame
  /// through [CartyWorldGridHandle.accreteFromFrame] (K + full extrinsics),
  /// exactly where [run] folds pre-ortho'd observations via [accrete]. This is
  /// the host-proven path the live device loop will mirror:
  /// same determinism contract (record → replay → identical SHA-256), same
  /// ownership contract (the loop disposes each frame the provider creates).
  FusionResult runFromFrames({
    required ReplayHarness replay,
    required CartyWorldGridHandle grid,
    required FrameProvider frames,
    required List<double> intrinsics, // fx, fy, cx, cy — fixed for the session
    required int width, // frame geometry is fixed per capture session,
    required int height, // exactly like intrinsics; CartyFrameBuffer
    required int channels, // doesn't expose per-dim sizes, so pass them here
  }) {
    var accreted = 0, duplicate = 0, outOfBounds = 0, seenFull = 0;
    for (final sample in replay.trackingOnly) {
      final frame = frames(sample);
      try {
        final status = grid.accreteFromFrame(
          frame: frame,
          width: width,
          height: height,
          channels: channels,
          intrinsics: intrinsics,
          pose: sample.toPoseMatrix(),
          keyframeId: sample.t,
        );
        switch (status) {
          case CartyFuseStatus.ok:
            accreted++;
          case CartyFuseStatus.duplicate:
            duplicate++;
          case CartyFuseStatus.outOfBounds:
            outOfBounds++;
          case CartyFuseStatus.seenFull:
            seenFull++;
        }
      } finally {
        frame.dispose();
      }
    }
    final digest = sha256.convert(grid.cells).toString();
    return FusionResult(
      stats: FusionStats(
        accreted: accreted,
        duplicate: duplicate,
        outOfBounds: outOfBounds,
        seenFull: seenFull,
      ),
      gridSha256: digest,
    );
  }

  /// The DEPTH replay path — folds each TRACKING keyframe's recorded depth blob
  /// through [CartyWorldGridHandle.accreteFromDepth] (sensor pose + scaled K),
  /// the sibling of [runFromFrames] that places WALLS (the floor photo-map path
  /// cannot). This is the input half of the honest end-to-end gate (#7): record
  /// a depth sidecar → replay here → real fused grid → vectorize. Same
  /// determinism contract (identical grid SHA-256) and ownership contract as the
  /// other loops. Keyframes with no depth block are skipped (a mixed capture is
  /// valid — only TRACKING frames that carry depth fuse here).
  FusionResult runFromDepth({
    required ReplayHarness replay,
    required CartyWorldGridHandle grid,
    required String sidecarDir,
  }) {
    var accreted = 0, duplicate = 0, outOfBounds = 0, seenFull = 0;
    for (final sample in replay.trackingOnly) {
      final block = sample.depth;
      if (block == null) continue;
      final frame = loadDepthFrame(sidecarDir, sample);
      final status = grid.accreteFromDepth(
        depth: frame.depth,
        dw: frame.dw,
        dh: frame.dh,
        conf: frame.confidence,
        intrinsics: [block.fx, block.fy, block.cx, block.cy],
        pose: block.toSensorPoseMatrix(),
        keyframeId: sample.t,
      );
      switch (status) {
        case CartyFuseStatus.ok:
          accreted++;
        case CartyFuseStatus.duplicate:
          duplicate++;
        case CartyFuseStatus.outOfBounds:
          outOfBounds++;
        case CartyFuseStatus.seenFull:
          seenFull++;
      }
    }
    final digest = sha256.convert(grid.cells).toString();
    return FusionResult(
      stats: FusionStats(
        accreted: accreted,
        duplicate: duplicate,
        outOfBounds: outOfBounds,
        seenFull: seenFull,
      ),
      gridSha256: digest,
    );
  }

  /// Replay [replay]'s TRACKING samples into [grid] using [observe] to supply
  /// each keyframe's top-down observation. The observation is disposed after it
  /// is folded (the loop owns only what it creates here). Returns the status
  /// tally + the grid's SHA-256 (the determinism signal).
  FusionResult run({
    required ReplayHarness replay,
    required CartyWorldGridHandle grid,
    required ObservationProvider observe,
  }) {
    var accreted = 0, duplicate = 0, outOfBounds = 0, seenFull = 0;
    for (final sample in replay.trackingOnly) {
      final obs = observe(sample);
      try {
        final status = grid.accrete(
          observation: obs,
          pose: sample.toPoseMatrix(),
          keyframeId: sample.t,
        );
        switch (status) {
          case CartyFuseStatus.ok:
            accreted++;
          case CartyFuseStatus.duplicate:
            duplicate++;
          case CartyFuseStatus.outOfBounds:
            outOfBounds++;
          case CartyFuseStatus.seenFull:
            seenFull++;
        }
      } finally {
        obs.dispose();
      }
    }
    final digest = sha256.convert(grid.cells).toString();
    return FusionResult(
      stats: FusionStats(
        accreted: accreted,
        duplicate: duplicate,
        outOfBounds: outOfBounds,
        seenFull: seenFull,
      ),
      gridSha256: digest,
    );
  }
}
