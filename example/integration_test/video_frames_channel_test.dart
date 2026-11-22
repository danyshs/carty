/// Integration test: validates that AndroidVideoFrameExtractor correctly drives
/// the carty/video_frames MethodChannel (MediaMetadataRetriever on-device).
///
/// Prerequisite: stage a test clip into the app's cache before running:
///   adb push clip.mp4 /data/local/tmp/test_clip.mp4
///   adb shell run-as com.carty.carty_example sh -c
///     'mkdir -p cache/file_picker && cp /data/local/tmp/test_clip.mp4 cache/file_picker/test_clip.mp4'
///
/// Run with:
///   flutter test integration_test/video_frames_channel_test.dart \
///     --device-id DEVICE_ID
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:carty/video/frame_extractor.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late String clipPath;

  setUpAll(() async {
    final cacheDir = await getTemporaryDirectory();
    clipPath = '${cacheDir.path}/file_picker/test_clip.mp4';
  });

  testWidgets('staged clip is readable', (tester) async {
    expect(File(clipPath).existsSync(), isTrue,
        reason: 'Stage the test clip first — see test header for adb commands');
  });

  testWidgets('probe() returns valid VideoInfo', (tester) async {
    if (!File(clipPath).existsSync()) {
      markTestSkipped('test clip not staged');
      return;
    }
    const extractor = AndroidVideoFrameExtractor();
    final info = await extractor.probe(clipPath);
    debugPrint('[Carty][test] probe: ${info.width}x${info.height} '
        '@ ${info.frameRate.toStringAsFixed(2)}fps, '
        '${info.durationSeconds.toStringAsFixed(2)}s');
    expect(info.width, greaterThan(0));
    expect(info.height, greaterThan(0));
    expect(info.durationSeconds, greaterThan(0));
  });

  testWidgets('extract() yields RGBA frames with correct byte count',
      (tester) async {
    if (!File(clipPath).existsSync()) {
      markTestSkipped('test clip not staged');
      return;
    }
    const extractor = AndroidVideoFrameExtractor();
    const targetW = 64;
    const targetH = 64;
    const expectedBytes = targetW * targetH * 4;

    final frames = await extractor
        .extract(
          clipPath,
          targetWidth: targetW,
          targetHeight: targetH,
          sampleFps: 1.0,
          maxFrames: 3,
        )
        .toList();

    expect(frames, isNotEmpty, reason: 'clip yielded no frames');
    for (final f in frames) {
      expect(f.rgba.length, equals(expectedBytes),
          reason: 'frame ${f.index}: ${f.rgba.length} != $expectedBytes');
      expect(f.width, equals(targetW));
      expect(f.height, equals(targetH));
    }
    debugPrint('[Carty][test] got ${frames.length} frame(s); '
        'frame 0 RGBA[0..3]: '
        '${frames.first.rgba[0]},${frames.first.rgba[1]},'
        '${frames.first.rgba[2]},${frames.first.rgba[3]}');
  });
}
