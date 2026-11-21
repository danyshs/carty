// Verifies the "Choose video file" button actually reaches the picker and the
// returned path lands in the page (is the BUTTON wired, or does
// only the picker work in isolation?). Uses an injected fake VideoPicker — the
// same seam the future Android SAF picker will implement.
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:carty_example/video_map_page.dart';

void main() {
  testWidgets('tapping "Choose video file" invokes the picker and stores path',
      (tester) async {
    var calls = 0;
    Future<String?> fakePicker() async {
      calls++;
      return '/tmp/fake_recording.mp4';
    }

    await tester.pumpWidget(MaterialApp(
      home: VideoMapPage(
        bridgeLibrary: 'libcarty.so',
        videoPicker: fakePicker,
      ),
    ));

    expect(calls, 0, reason: 'picker must not run before the tap');
    expect(find.text('Video selected: /tmp/fake_recording.mp4'), findsNothing);

    final button = find.widgetWithText(FilledButton, 'Choose video file');
    expect(button, findsOneWidget, reason: 'the button must be present');

    await tester.tap(button);
    await tester.pumpAndSettle();

    expect(calls, 1, reason: 'the tap MUST reach the picker exactly once');
    // The chosen path is surfaced both in the field and the status banner.
    expect(find.text('Video selected: /tmp/fake_recording.mp4'), findsOneWidget);
  });

  testWidgets('a cancelled pick (null) leaves the page with no selection',
      (tester) async {
    Future<String?> cancelPicker() async => null;

    await tester.pumpWidget(MaterialApp(
      home: VideoMapPage(
        bridgeLibrary: 'libcarty.so',
        videoPicker: cancelPicker,
      ),
    ));

    await tester.tap(find.widgetWithText(FilledButton, 'Choose video file'));
    await tester.pumpAndSettle();

    // Still in the "no video loaded" state.
    expect(find.textContaining('No video loaded'), findsOneWidget);
  });
}
