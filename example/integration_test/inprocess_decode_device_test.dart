/// Integration test: the Phase-A on-device decode gate (A2).
///
/// Proves a REAL Gemma 4 E2B decode runs FULLY IN-PROCESS on the arm64 device,
/// through the exact production FFI seam the app uses
/// (loadModel → orthoProject → inferMapUpdateOrtho → libcarty.so →
/// liblitert-lm.so → Gemma 4 E2B). This is the device counterpart of the host
/// ctest `litert_forward`/`inprocess_decode`: same seam, real arm64 hardware, so
/// it also captures the numbers the host cannot — model-load time, decode time,
/// and the resident engine's RAM cost (RSS before→after).
///
/// Prerequisite: the 2.4 GB model must already live in app-private storage,
/// staged THE WAY A CUSTOMER'S DOES — via the in-app hash-gated downloader
/// (example/lib/model_downloader.dart): launch the app, long-press the "Carty"
/// wordmark → Developer tools → "1 · On-device model" → Download. It lands at
/// getApplicationSupportDirectory()/gemma-4-E2B-it.litertlm (Android files/) and
/// is renamed to the final name only after its SHA-256 verifies. Do NOT `adb
/// push` it (a product-incorrect path that also truncated the file once).
///
/// Run on the connected device:
///   flutter test integration_test/inprocess_decode_device_test.dart \
///     --device-id DEVICE_ID
///
/// SKIPS honestly (never fabricates a pass) when the model is not staged.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:carty/carty.dart';
import 'package:carty/inference/prompt.dart' show kMapUpdateSchemaContract;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The model lives where the in-app downloader puts it: applicationSupport
  // (= getFilesDir() on Android) / gemma-4-E2B-it.litertlm.
  const modelFilename = 'gemma-4-E2B-it.litertlm';
  late String modelPath;

  setUpAll(() async {
    final dir = await getApplicationSupportDirectory();
    modelPath = '${dir.path}${Platform.pathSeparator}$modelFilename';
  });

  testWidgets('Gemma 4 E2B decodes in-process on-device through the FFI seam',
      (tester) async {
    if (!File(modelPath).existsSync()) {
      markTestSkipped('model not staged at $modelPath — see test header');
      return;
    }

    final carty = Carty.instance;

    // RSS before any model work — the baseline for the resident-engine RAM cost.
    final rssBefore = ProcessInfo.currentRss;

    final loadWatch = Stopwatch()..start();
    final model = carty.loadModel(modelPath);
    loadWatch.stop();

    const dim = 64;
    final frame = carty.allocFrame(width: dim, height: dim, channels: 4);
    CartyOrthoMapHandle? ortho;
    try {
      // Deterministic synthetic gradient — enough signal for the geometric
      // stage; the gate measures the seam + decode, not map quality.
      final pixels = frame.bytes;
      for (var y = 0; y < dim; y++) {
        for (var x = 0; x < dim; x++) {
          final i = (y * dim + x) * 4;
          pixels[i] = (x * 4) & 0xFF;
          pixels[i + 1] = (y * 4) & 0xFF;
          pixels[i + 2] = ((x + y) * 2) & 0xFF;
          pixels[i + 3] = 0xFF;
        }
      }

      ortho = carty.orthoProject(frame, width: dim, height: dim, channels: 4);

      final decodeWatch = Stopwatch()..start();
      final inference = model.inferMapUpdateOrtho(
        ortho,
        instruction: kMapUpdateSchemaContract,
      );
      decodeWatch.stop();

      final rssAfter = ProcessInfo.currentRss;
      const mib = 1024 * 1024;
      // ignore: avoid_print
      print('[Carty][gate-A2] bridge=${carty.version} '
          'load=${loadWatch.elapsedMilliseconds}ms '
          'decode=${decodeWatch.elapsedMilliseconds}ms '
          'status=${inference.status} '
          'output=${inference.text.length}B '
          'rss=${rssBefore ~/ mib}->${rssAfter ~/ mib}MiB '
          '(delta=${(rssAfter - rssBefore) ~/ mib}MiB)');
      // ignore: avoid_print
      print('[Carty][gate-A2] decoded text (first 400B): '
          '${inference.text.substring(0, inference.text.length.clamp(0, 400))}');

      // THE GATE: a real decode completed in-process on-device. status >= 0 means
      // the resident engine ran (NOT CARTY_INFER_ENOMODEL); a non-empty output
      // means tokens were actually produced over the weights.
      expect(inference.status, greaterThanOrEqualTo(0),
          reason: 'in-process decode failed on-device (status '
              '${inference.status}); arm64 LiteRT linkage or model staging is wrong');
      expect(inference.text.length, greaterThan(0),
          reason: 'decode produced no output — engine linked but did not generate');
    } finally {
      ortho?.dispose();
      frame.dispose();
      model.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
