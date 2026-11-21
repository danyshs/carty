// Throwaway external-verification probe (fusion wiring): runs ONE real video
// frame through the full Dart Geometric->Semantic fusion and prints the concrete
// outcome (ortho grid dims, status, note, accreted node count) so we can record a
// real end-to-end signal. For a real decode, export CARTY_LITERT_RUNTIME +
// CARTY_GEMMA_MODEL first, then:
//   dart run tool/e2e_probe.dart
import 'dart:ffi';
import 'dart:io';

import 'package:carty/carty.dart';
import 'package:carty/vc.dart';
import 'package:carty/video.dart';

Future<void> main() async {
  final so = File('native/build/libcarty_bridge.so').absolute.path;
  final carty = Carty.fromLibrary(DynamicLibrary.open(so));
  final model = carty.loadModel('/tmp/gemma4_e2b.litertlm');

  final dir = Directory.systemTemp.createTempSync('carty_probe_');
  final clip = '${dir.path}/probe.mp4';
  final gen = await Process.run('ffmpeg', [
    '-y', '-loglevel', 'error', '-f', 'lavfi',
    '-i', 'testsrc=duration=2:size=160x120:rate=10', '-pix_fmt', 'yuv420p', clip,
  ]);
  if (gen.exitCode != 0) {
    stderr.writeln('ffmpeg failed: ${gen.stderr}');
    exit(1);
  }

  final frames = await const FfmpegVideoFrameExtractor()
      .extract(clip, targetWidth: 96, targetHeight: 96, sampleFps: 1, maxFrames: 1)
      .toList();
  stdout.writeln('extracted ${frames.length} frame(s)');

  final sw = Stopwatch()..start();
  final result = driveFrame(
    carty: carty,
    model: model,
    frame: frames.first,
    base: MapGraph.empty(),
    instruction: 'reconstruct the overhead map region',
  );
  sw.stop();

  stdout.writeln('--- driveFrame outcome (real Gemma decode) ---');
  stdout.writeln('elapsed     : ${sw.elapsed.inSeconds}s');
  stdout.writeln('status      : ${result.status}');
  stdout.writeln('applied     : ${result.applied}');
  stdout.writeln('node count  : ${result.graph.nodeCount}');
  stdout.writeln('note        : ${result.note}');

  model.dispose();
  dir.deleteSync(recursive: true);
}
