// Android frame-source tests (third-class video input).
//
// The product's third-class input is a pre-recorded clip picked off the device.
// On the Nix host the frames come from ffmpeg ([FfmpegVideoFrameExtractor]); on
// Android ffmpeg is absent, so frames come from the platform decoder via the
// `carty/video_frames` MethodChannel ([AndroidVideoFrameExtractor]).
//
// These tests pin the Dart half of that channel WITHOUT a device: the platform
// side is mocked so the bounding, exact-size, sequential-index, and
// error-translation invariants are verified on the host loop.
// The real Kotlin MediaMetadataRetriever side is validated live on the emulator.

import 'package:carty/video.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AndroidVideoFrameExtractor.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // A fake platform decoder. `durationSeconds` drives how many frames a
  // sampled extraction yields; `frameCap` lets a test force an early end-of-
  // stream (null frame) the way a short/odd clip would. Records calls so the
  // bound can be asserted from the platform side too.
  late double fakeDuration;
  late int frameCap; // frames available before the decoder returns null
  late List<MethodCall> calls;

  Uint8List rgbaOf(int w, int h, int seed) {
    final bytes = Uint8List(w * h * 4);
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = (seed + i) & 0xff;
    }
    return bytes;
  }

  setUp(() {
    fakeDuration = 5.0;
    frameCap = 1 << 30; // effectively unbounded unless a test lowers it
    calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'probe':
          return <String, Object?>{
            'width': 1920,
            'height': 1080,
            'frameRate': 30.0,
            'durationSeconds': fakeDuration,
          };
        case 'frameAt':
          final args = (call.arguments as Map).cast<String, Object?>();
          final tw = args['targetWidth'] as int;
          final th = args['targetHeight'] as int;
          final timeUs = args['timeUs'] as int;
          // Index = call order among frameAt calls already recorded.
          final frameIndex =
              calls.where((c) => c.method == 'frameAt').length - 1;
          if (frameIndex >= frameCap) return null; // decoder exhausted
          return rgbaOf(tw, th, timeUs & 0xff);
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  group('AndroidVideoFrameExtractor.probe', () {
    test('maps the channel reply to VideoInfo', () async {
      final info = await const AndroidVideoFrameExtractor().probe('/sd/clip.mp4');
      expect(info.width, 1920);
      expect(info.height, 1080);
      expect(info.frameRate, 30.0);
      expect(info.durationSeconds, 5.0);
      expect(calls.single.method, 'probe');
      expect((calls.single.arguments as Map)['path'], '/sd/clip.mp4');
    });

    test('a PlatformException becomes a recoverable VideoExtractionException',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'DECODE', message: 'bad file');
      });
      expect(
        () => const AndroidVideoFrameExtractor().probe('/sd/clip.mp4'),
        throwsA(isA<VideoExtractionException>()),
      );
    });
  });

  group('AndroidVideoFrameExtractor.extract', () {
    test('yields bounded, exact-size, sequentially-indexed RGBA frames',
        () async {
      final frames = await const AndroidVideoFrameExtractor()
          .extract('/sd/clip.mp4',
              targetWidth: 64, targetHeight: 48, sampleFps: 2.0, maxFrames: 8)
          .toList();

      // 5 s at 2 fps would be ~10–11 frames; the maxFrames ceiling clamps to 8.
      expect(frames.length, 8);
      for (var i = 0; i < frames.length; i++) {
        expect(frames[i].index, i);
        expect(frames[i].width, 64);
        expect(frames[i].height, 48);
        expect(frames[i].channels, kExtractChannels);
        expect(frames[i].rgba.length, 64 * 48 * kExtractChannels);
      }
    });

    test('never decodes past maxFrames even for a long clip', () async {
      fakeDuration = 3600.0; // an hour
      final frames = await const AndroidVideoFrameExtractor()
          .extract('/sd/clip.mp4',
              targetWidth: 32, targetHeight: 32, sampleFps: 30.0, maxFrames: 12)
          .toList();
      expect(frames.length, 12);
      // The bound holds on the PLATFORM side too: at most maxFrames frameAt
      // calls ever cross the channel (no unbounded decode behind our back).
      expect(calls.where((c) => c.method == 'frameAt').length, 12);
    });

    test('stops cleanly when the decoder runs out of frames (null reply)',
        () async {
      fakeDuration = 100.0; // sampling would want many frames…
      frameCap = 3; // …but the decoder only has 3
      final frames = await const AndroidVideoFrameExtractor()
          .extract('/sd/clip.mp4',
              targetWidth: 16, targetHeight: 16, sampleFps: 1.0, maxFrames: 50)
          .toList();
      expect(frames.length, 3);
      expect(frames.last.index, 2);
    });

    test('samples timestamps monotonically from t=0 at the requested fps',
        () async {
      await const AndroidVideoFrameExtractor()
          .extract('/sd/clip.mp4',
              targetWidth: 16, targetHeight: 16, sampleFps: 4.0, maxFrames: 3)
          .toList();
      final times = calls
          .where((c) => c.method == 'frameAt')
          .map((c) => (c.arguments as Map)['timeUs'] as int)
          .toList();
      // 4 fps → 250 000 µs step, starting at 0.
      expect(times, <int>[0, 250000, 500000]);
    });

    test('a mid-stream PlatformException surfaces as VideoExtractionException',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'probe') {
          return <String, Object?>{
            'width': 100,
            'height': 100,
            'frameRate': 30.0,
            'durationSeconds': 5.0,
          };
        }
        throw PlatformException(code: 'DECODE', message: 'frame failed');
      });
      expect(
        () => const AndroidVideoFrameExtractor()
            .extract('/sd/clip.mp4',
                targetWidth: 16, targetHeight: 16, sampleFps: 1.0, maxFrames: 4)
            .toList(),
        throwsA(isA<VideoExtractionException>()),
      );
    });
  });
}
