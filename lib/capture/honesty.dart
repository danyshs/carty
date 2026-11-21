/// The honesty overlay's logic core — the park-test insurance.
/// It exists so the demo can NEVER over-claim: it maps capture mode + live
/// tracking health to a single accuracy banner the buyer can read. Deleting it
/// would let the UI imply HIGH accuracy while VIO is failing — the exact
/// over-claim the project forbids. Pure + deterministic so it is unit-tested.
library;

import 'pose_sidecar.dart';

/// Where pose comes from. ARCore VIO is metric/high-accuracy;
/// monocular SLAM is the relative-scale, explicitly-low-accuracy fallback.
enum CaptureMode { arcoreVio, monocularSlam }

enum AccuracyLevel {
  high,
  low,
  degraded;

  String get bannerText {
    switch (this) {
      case AccuracyLevel.high:
        return 'HIGH';
      case AccuracyLevel.low:
        return 'LOW — relative scale';
      case AccuracyLevel.degraded:
        return 'DEGRADED — tracking poor';
    }
  }
}

/// Minimum fraction of recent frames that must be TRACKING to call accuracy
/// trustworthy. Below this the banner drops to DEGRADED (honest under sun/grass).
const double _kHealthyTrackingRatio = 0.5;

/// Derive the live accuracy banner. Order matters: a poor *current* or *recent*
/// tracking signal overrides everything (degraded); otherwise the SLAM fallback
/// is always LOW (relative scale); only ARCore + healthy tracking is HIGH.
AccuracyLevel deriveAccuracy({
  required CaptureMode mode,
  required TrackingState tracking,
  required int recentTrackingFrames,
  required int recentTotalFrames,
}) {
  final ratio = recentTotalFrames <= 0
      ? 0.0
      : recentTrackingFrames / recentTotalFrames;
  if (tracking == TrackingState.paused || ratio < _kHealthyTrackingRatio) {
    return AccuracyLevel.degraded;
  }
  if (mode == CaptureMode.monocularSlam) {
    return AccuracyLevel.low;
  }
  return AccuracyLevel.high;
}
