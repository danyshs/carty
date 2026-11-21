// Pure-logic guard for the CapturePage honesty banner: the
// banner MUST read HIGH only under ARCore + healthy tracking. CapturePage itself
// lives in example/ (it depends on Flutter platform channels), so the ROOT test
// package cannot import it; this guard pins the banner contract the page renders.
// The REAL widget pump (page + fake CaptureController + synthetic grid) lives in
// example/test/capture_page_widget_test.dart.
import 'package:carty/capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accuracy banner reads HIGH only under ARCore + healthy tracking', () {
    expect(
      deriveAccuracy(
        mode: CaptureMode.arcoreVio,
        tracking: TrackingState.tracking,
        recentTrackingFrames: 30,
        recentTotalFrames: 30,
      ).bannerText,
      'HIGH',
    );

    // Honesty: poor recent tracking can never read HIGH (park-test insurance).
    expect(
      deriveAccuracy(
        mode: CaptureMode.arcoreVio,
        tracking: TrackingState.tracking,
        recentTrackingFrames: 1,
        recentTotalFrames: 30,
      ).bannerText,
      'DEGRADED — tracking poor',
    );
  });
}
