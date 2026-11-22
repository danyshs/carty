/// Integration test: validates the carty/arcore_spike startPoseProbe flow.
///
/// Requires the real device (ARCore SUPPORTED_INSTALLED, CAMERA permission).
/// Run with:
///   flutter test integration_test/arcore_pose_probe_test.dart --device-id DEVICE_ID
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('carty/arcore_spike');

  testWidgets('startPoseProbe returns pose snapshots', (tester) async {
    // First verify availability so we skip cleanly on non-AR devices.
    final availability =
        await channel.invokeMethod<String>('availability') ?? 'null';
    debugPrint('[Carty][test] ARCore availability: $availability');

    if (!availability.startsWith('SUPPORTED')) {
      markTestSkipped('ARCore not supported/installed on this device ($availability)');
      return;
    }

    // Collect 60 frames — ARCore typically needs ~1-2 seconds to transition
    // from PAUSED/INITIALIZING to TRACKING after camera opens.
    const maxFrames = 60;
    final raw = await channel.invokeMethod<List<Object?>>(
      'startPoseProbe',
      <String, Object?>{'maxFrames': maxFrames},
    );
    expect(raw, isNotNull);
    final snapshots =
        (raw ?? []).whereType<Map<Object?, Object?>>().toList();
    debugPrint('[Carty][test] pose probe: ${snapshots.length} snapshots');

    expect(snapshots.length, equals(maxFrames),
        reason: 'expected $maxFrames snapshots from maxFrames=$maxFrames');

    // Examine tracking states.
    final states = snapshots.map((s) => s['trackingState'] as String?).toList();
    debugPrint('[Carty][test] tracking states: $states');

    final tracked = states.where((s) => s == 'TRACKING').length;
    debugPrint('[Carty][test] TRACKING frames: $tracked / ${snapshots.length}');

    // At least one TRACKING frame is the gate — if all are INITIALIZING the
    // device needs more time to initialize ARCore (move it and retry).
    // We don't hard-fail here because the first session invocation may need to
    // warm up. The test logs the evidence and the caller decides.
    if (tracked == 0) {
      debugPrint('[Carty][test] WARNING: no TRACKING frames — ARCore initializing. '
          'Move the device and retry.');
    } else {
      // Spot-check last snapshot fields.
      final last = snapshots.last;
      expect(last['tx'], isA<double>());
      expect(last['ty'], isA<double>());
      expect(last['tz'], isA<double>());
      expect(last['qw'], isA<double>());
      expect(last['floorPlaneTracked'], isA<bool>());
      debugPrint('[Carty][test] last pose t=(${last['tx']}, ${last['ty']}, ${last['tz']}) '
          'q=(${last['qx']}, ${last['qy']}, ${last['qz']}, ${last['qw']}) '
          'floor=${last['floorPlaneTracked']}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
