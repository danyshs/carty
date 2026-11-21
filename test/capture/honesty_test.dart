import 'package:carty/capture.dart';
import 'package:test/test.dart';

void main() {
  test('ARCore + healthy tracking → HIGH', () {
    final a = deriveAccuracy(
      mode: CaptureMode.arcoreVio,
      tracking: TrackingState.tracking,
      recentTrackingFrames: 28,
      recentTotalFrames: 30,
    );
    expect(a, AccuracyLevel.high);
    expect(a.bannerText, 'HIGH');
  });

  test('PAUSED current state → DEGRADED regardless of mode', () {
    expect(
      deriveAccuracy(
        mode: CaptureMode.arcoreVio,
        tracking: TrackingState.paused,
        recentTrackingFrames: 30,
        recentTotalFrames: 30,
      ),
      AccuracyLevel.degraded,
    );
  });

  test('poor recent tracking ratio → DEGRADED even while TRACKING', () {
    expect(
      deriveAccuracy(
        mode: CaptureMode.arcoreVio,
        tracking: TrackingState.tracking,
        recentTrackingFrames: 5,
        recentTotalFrames: 30, // <50% → degraded
      ),
      AccuracyLevel.degraded,
    );
  });

  test('SLAM fallback with healthy tracking → LOW (relative scale)', () {
    final a = deriveAccuracy(
      mode: CaptureMode.monocularSlam,
      tracking: TrackingState.tracking,
      recentTrackingFrames: 30,
      recentTotalFrames: 30,
    );
    expect(a, AccuracyLevel.low);
    expect(a.bannerText, contains('relative scale'));
  });
}
