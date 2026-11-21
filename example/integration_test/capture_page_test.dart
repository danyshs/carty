// Device integration test for the live capture path. Drives the REAL
// carty/capture channel: start → short record (walk the device) → stop, then
// asserts the returned sidecar parses as pose samples (ReplayHarness). ARCore
// needs real hardware (the emulator returns UNKNOWN_ERROR),
// so this is skipped until the on-device run un-skips it.
import 'dart:io';

import 'package:carty/capture.dart';
import 'package:carty_example/capture_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('record→stop returns a parseable pose sidecar', (tester) async {
    final controller = ChannelCaptureController();
    await tester.pumpWidget(MaterialApp(
      home: CapturePage(controller: controller),
    ));

    await tester.tap(find.widgetWithText(FilledButton, 'Record'));
    await tester.pumpAndSettle();

    // Walk the device for ~3 s so ARCore accumulates TRACKING keyframes.
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();

    final result = await controller.stop();
    expect(result.frameCount, greaterThan(0));
    final lines = File(result.sidecarPath).readAsLinesSync();
    expect(() => ReplayHarness.fromLines(lines), returnsNormally);
  }, skip: true); // un-skip on the device run; ARCore needs real hardware.
}
