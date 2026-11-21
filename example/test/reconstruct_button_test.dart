// Verifies the "Reconstruct map" button actually reaches the pipeline through
// the injected [PipelineRunner] seam — the Start-button analogue of
// video_picker_button_test.dart. A fake runner returns a controlled
// [PipelineEvent] stream so the wiring is tested without spawning a real
// background isolate or FFI bridge (Tiger Style: test the wiring).
import 'dart:io';

import 'package:carty/vc.dart';
import 'package:carty/video.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:carty_example/video_map_page.dart';

void main() {
  testWidgets('tapping "Reconstruct map" drives the page off the injected runner',
      (tester) async {
    // The page guards on File(path).existsSync(), so point it at a real file.
    final tmp = File(
        '${Directory.systemTemp.createTempSync('carty_recon_').path}/clip.mp4')
      ..writeAsBytesSync(const <int>[0]);
    addTearDown(() => tmp.parent.deleteSync(recursive: true));

    var calls = 0;
    String? sawPath;
    Stream<PipelineEvent> fakeRunner(String videoPath) {
      calls++;
      sawPath = videoPath;
      return Stream<PipelineEvent>.fromIterable([
        const PipelineProcessing(false),
        PipelineDone(frameCount: 0, graph: MapGraph.empty()),
      ]);
    }

    await tester.pumpWidget(MaterialApp(
      home: VideoMapPage(
        bridgeLibrary: 'libcarty.so',
        pipelineRunner: fakeRunner,
      ),
    ));

    await tester.enterText(find.byType(TextField), tmp.path);
    expect(calls, 0, reason: 'runner must not start before the tap');

    await tester.tap(find.widgetWithText(FilledButton, 'Reconstruct map'));
    await tester.pumpAndSettle();

    expect(calls, 1, reason: 'the tap MUST reach the pipeline runner exactly once');
    expect(sawPath, tmp.path, reason: 'the typed path is handed to the runner');
  });
}
