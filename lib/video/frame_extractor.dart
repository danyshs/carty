/// Video → frame extraction (desktop dev surface).
///
/// Turns a local video file into a *bounded* stream of fixed-size RGBA frames
/// by driving `ffmpeg` (provided by the flake) as a subprocess.
/// The pixels are decoded/scaled by ffmpeg and handed to Dart as raw `rawvideo`
/// bytes — no per-frame image codec in Dart, no unbounded buffering.
///
/// Tiger Style:
///   - Every frame is exactly `width*height*channels` bytes — asserted.
///   - At most [kMaxVideoFrames] frames are emitted; a longer clip is truncated
///     deterministically at that ceiling, never decoded unbounded. The bound
///     mirrors the inference fold ceiling so a clip cannot outgrow the map.
///   - Dimensions are checked against the native frame bounds *before* any byte
///     crosses toward the FFI bridge, so the boundary never sees an illegal size.
///
/// This is a DEV-surface convenience (Linux desktop). On Android the frame
/// source will be the platform decoder, not an ffmpeg subprocess; the rest of
/// the pipeline ([VideoToMapPipeline]) is source-agnostic.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart'
    show MethodChannel, PlatformException, MissingPluginException;

import '../carty_bindings_generated.dart'
    show CARTY_FRAME_MAX_DIM, CARTY_FRAME_MAX_CHANNELS;
import '../inference/engine.dart' show kMaxVideoFrames;

/// Frames are decoded as RGBA — 4 bytes/pixel — matching ffmpeg `-pix_fmt rgba`
/// and the native `CARTY_FRAME_MAX_CHANNELS` ceiling.
const int kExtractChannels = 4;

/// A recoverable failure from the external decoder. Never a crash: a bad file
/// or an ffmpeg error surfaces here so the UI can report it and move on.
class VideoExtractionException implements Exception {
  final String message;
  VideoExtractionException(this.message);
  @override
  String toString() => 'VideoExtractionException: $message';
}

/// Probed metadata for the first video stream of a file.
class VideoInfo {
  final int width;
  final int height;

  /// Container frame rate (frames/sec). May be 0 if ffprobe could not report it.
  final double frameRate;

  /// Duration in seconds, or 0 if unknown.
  final double durationSeconds;

  VideoInfo({
    required this.width,
    required this.height,
    required this.frameRate,
    required this.durationSeconds,
  }) {
    // Preconditions are live invariants: a stream the native
    // boundary could never accept is rejected here, before the FFI line.
    assert(width > 0 && width <= CARTY_FRAME_MAX_DIM, 'width out of range: $width');
    assert(height > 0 && height <= CARTY_FRAME_MAX_DIM,
        'height out of range: $height');
    assert(frameRate >= 0 && frameRate.isFinite, 'bad frameRate: $frameRate');
    assert(durationSeconds >= 0 && durationSeconds.isFinite,
        'bad duration: $durationSeconds');
  }

  @override
  String toString() =>
      'VideoInfo(${width}x$height @ ${frameRate.toStringAsFixed(2)}fps, '
      '${durationSeconds.toStringAsFixed(1)}s)';
}

/// One decoded, scaled frame: a tightly-packed NHWC uint8 RGBA buffer the
/// [VideoToMapPipeline] copies (zero-copy) into a bridge-owned frame.
class ExtractedFrame {
  /// 0-based position in the emitted (sampled) sequence.
  final int index;
  final int width;
  final int height;
  final int channels;
  final Uint8List rgba;

  ExtractedFrame({
    required this.index,
    required this.width,
    required this.height,
    required this.channels,
    required this.rgba,
  }) {
    assert(index >= 0, 'index negative');
    assert(width > 0 && width <= CARTY_FRAME_MAX_DIM, 'width out of range');
    assert(height > 0 && height <= CARTY_FRAME_MAX_DIM, 'height out of range');
    assert(channels > 0 && channels <= CARTY_FRAME_MAX_CHANNELS,
        'channels out of range');
    // The single most important invariant: the buffer is EXACTLY one frame.
    assert(rgba.length == width * height * channels,
        'frame buffer ${rgba.length} != ${width * height * channels}');
  }

  int get sizeInBytes => width * height * channels;
}

/// A bounded source of fixed-size RGBA frames from a local video file.
///
/// Two implementations sit behind this seam (the rest of the
/// pipeline is source-agnostic):
///   - [FfmpegVideoFrameExtractor] — the Nix host / CI loop, drives `ffmpeg`.
///   - [AndroidVideoFrameExtractor] — the device/emulator, drives the platform
///     decoder over a MethodChannel (ffmpeg is absent on Android).
/// Both honour the same Tiger-Style contract: at most [maxFrames] frames, each
/// exactly `targetWidth*targetHeight*kExtractChannels` bytes.
abstract interface class VideoFrameExtractor {
  /// Probes [videoPath] for the first video stream's geometry and timing.
  /// Throws [VideoExtractionException] on any recoverable failure.
  Future<VideoInfo> probe(String videoPath);

  /// Streams up to [maxFrames] frames, each scaled to [targetWidth]x
  /// [targetHeight] RGBA and sampled at [sampleFps] frames/sec.
  Stream<ExtractedFrame> extract(
    String videoPath, {
    required int targetWidth,
    required int targetHeight,
    double sampleFps,
    int maxFrames,
  });
}

/// Extracts frames from local video files via `ffmpeg`/`ffprobe`. Stateless and
/// reusable; the binaries come from the flake dev shell. This is
/// the HOST/CI frame source — on Android use [AndroidVideoFrameExtractor].
class FfmpegVideoFrameExtractor implements VideoFrameExtractor {
  final String ffmpegPath;
  final String ffprobePath;

  const FfmpegVideoFrameExtractor({
    this.ffmpegPath = 'ffmpeg',
    this.ffprobePath = 'ffprobe',
  });

  /// Probes [videoPath] for the first video stream's geometry and timing.
  /// Throws [VideoExtractionException] if the file is missing, unreadable, or
  /// has no video stream — recoverable, never a crash.
  @override
  Future<VideoInfo> probe(String videoPath) async {
    assert(videoPath.isNotEmpty, 'videoPath must be non-empty');
    if (!File(videoPath).existsSync()) {
      throw VideoExtractionException('file not found: $videoPath');
    }
    final ProcessResult result;
    try {
      result = await Process.run(ffprobePath, [
        '-v', 'error',
        '-select_streams', 'v:0',
        '-show_entries', 'stream=width,height,r_frame_rate',
        '-show_entries', 'format=duration',
        '-of', 'json',
        videoPath,
      ]);
    } on ProcessException catch (e) {
      throw VideoExtractionException('ffprobe failed to launch: ${e.message}');
    }
    if (result.exitCode != 0) {
      throw VideoExtractionException('ffprobe error: ${result.stderr}');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(result.stdout as String);
    } on FormatException catch (e) {
      throw VideoExtractionException('ffprobe JSON: ${e.message}');
    }
    if (decoded is! Map) {
      throw VideoExtractionException('ffprobe: unexpected output');
    }
    final streams = (decoded['streams'] as List?) ?? const [];
    if (streams.isEmpty) {
      throw VideoExtractionException('no video stream in $videoPath');
    }
    final stream = streams.first as Map<String, Object?>;
    final width = (stream['width'] as num?)?.toInt() ?? 0;
    final height = (stream['height'] as num?)?.toInt() ?? 0;
    if (width <= 0 || height <= 0) {
      throw VideoExtractionException('ffprobe: missing stream dimensions');
    }

    final format = (decoded['format'] as Map<String, Object?>?) ?? const {};
    final duration =
        double.tryParse('${format['duration'] ?? ''}') ?? 0.0;

    return VideoInfo(
      width: width,
      height: height,
      frameRate: _parseFrameRate(stream['r_frame_rate']),
      durationSeconds: duration.isFinite && duration > 0 ? duration : 0.0,
    );
  }

  /// Streams up to [maxFrames] frames from [videoPath], each scaled to
  /// [targetWidth]x[targetHeight] RGBA and sampled at [sampleFps] frames/sec.
  ///
  /// Bounded by construction: the ffmpeg subprocess is killed the
  /// instant [maxFrames] frames have been emitted, so no clip — however long —
  /// decodes more than the ceiling. The byte stream from ffmpeg is reassembled
  /// into exact frame-sized chunks; partial trailing bytes are carried forward.
  @override
  Stream<ExtractedFrame> extract(
    String videoPath, {
    required int targetWidth,
    required int targetHeight,
    double sampleFps = 1.0,
    int maxFrames = kMaxVideoFrames,
  }) async* {
    assert(videoPath.isNotEmpty, 'videoPath must be non-empty');
    assert(targetWidth > 0 && targetWidth <= CARTY_FRAME_MAX_DIM,
        'targetWidth out of range');
    assert(targetHeight > 0 && targetHeight <= CARTY_FRAME_MAX_DIM,
        'targetHeight out of range');
    assert(sampleFps > 0 && sampleFps.isFinite, 'sampleFps must be positive');
    assert(maxFrames > 0 && maxFrames <= kMaxVideoFrames,
        'maxFrames out of range (1..$kMaxVideoFrames)');
    if (!File(videoPath).existsSync()) {
      throw VideoExtractionException('file not found: $videoPath');
    }

    final frameBytes = targetWidth * targetHeight * kExtractChannels;

    final Process process;
    try {
      process = await Process.start(ffmpegPath, [
        '-nostdin',
        '-loglevel', 'error',
        '-i', videoPath,
        '-vf', 'fps=$sampleFps,scale=$targetWidth:$targetHeight',
        '-pix_fmt', 'rgba',
        '-f', 'rawvideo',
        '-',
      ]);
    } on ProcessException catch (e) {
      throw VideoExtractionException('ffmpeg failed to launch: ${e.message}');
    }

    // Drain stderr concurrently so a chatty decoder can never deadlock the
    // stdout pipe we are reading frames from.
    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .forEach(stderrBuffer.write);

    var emitted = 0;
    final pending = BytesBuilder(copy: false);
    try {
      await for (final chunk in process.stdout) {
        pending.add(chunk);
        if (pending.length < frameBytes) continue;

        // Drain every complete frame currently buffered. takeBytes() empties
        // the builder; the partial tail (if any) is pushed back for next chunk.
        final bytes = pending.takeBytes();
        var offset = 0;
        while (bytes.length - offset >= frameBytes && emitted < maxFrames) {
          // Copy out an owned, exact frame buffer (≈ targetW*targetH*4 bytes).
          final rgba =
              Uint8List.fromList(bytes.sublist(offset, offset + frameBytes));
          yield ExtractedFrame(
            index: emitted,
            width: targetWidth,
            height: targetHeight,
            channels: kExtractChannels,
            rgba: rgba,
          );
          offset += frameBytes;
          emitted++;
        }
        if (offset < bytes.length) {
          pending.add(Uint8List.sublistView(bytes, offset));
        }
        if (emitted >= maxFrames) break;
      }
    } finally {
      // Stop the decoder (it may still be producing past our ceiling) and
      // reap it so no zombie subprocess lingers.
      process.kill(ProcessSignal.sigterm);
      await stderrDone.catchError((_) {});
      final code = await process.exitCode;
      // A non-zero code is only an error when we got nothing: a clean early
      // kill after hitting maxFrames returns a signal code, which is expected.
      if (emitted == 0 && code != 0) {
        throw VideoExtractionException(
            'ffmpeg exited $code with no frames: ${stderrBuffer.toString().trim()}');
      }
    }
  }

  /// Parses ffprobe's `r_frame_rate` ("num/den") into frames/sec; 0 if unknown.
  static double _parseFrameRate(Object? raw) {
    if (raw is! String) return 0.0;
    final parts = raw.split('/');
    if (parts.length != 2) return 0.0;
    final num = double.tryParse(parts[0]) ?? 0.0;
    final den = double.tryParse(parts[1]) ?? 0.0;
    if (den == 0 || !num.isFinite || !den.isFinite) return 0.0;
    final fps = num / den;
    return fps.isFinite && fps >= 0 ? fps : 0.0;
  }
}

/// Extracts frames on Android by driving the platform decoder
/// (`MediaMetadataRetriever`) over the `carty/video_frames` MethodChannel —
/// ffmpeg is not present on the device. The Kotlin side decodes/scales one
/// frame at a requested timestamp; this class owns the bounded SAMPLING policy
/// so the bound is enforced Dart-side, before any native decode.
///
/// MethodChannel contract:
///   - `probe(path)` → `{width, height, frameRate, durationSeconds}`
///   - `frameAt(path, timeUs, targetWidth, targetHeight)` → RGBA `Uint8List`
///     of exactly `targetWidth*targetHeight*4` bytes, or `null` when the
///     decoder has no frame at/after that time (end of stream).
///
/// Must run on an isolate whose platform messenger is live — the pipeline
/// isolate calls `BackgroundIsolateBinaryMessenger.ensureInitialized` before
/// constructing this (see `pipeline.dart`).
class AndroidVideoFrameExtractor implements VideoFrameExtractor {
  /// MethodChannel name shared with `MainActivity.kt`.
  static const String channelName = 'carty/video_frames';

  /// The platform channel; overridable in tests with a mock messenger.
  final MethodChannel channel;

  const AndroidVideoFrameExtractor({
    this.channel = const MethodChannel(channelName),
  });

  @override
  Future<VideoInfo> probe(String videoPath) async {
    assert(videoPath.isNotEmpty, 'videoPath must be non-empty');
    final Map<Object?, Object?>? reply;
    try {
      reply = await channel.invokeMethod<Map<Object?, Object?>>(
        'probe',
        <String, Object?>{'path': videoPath},
      );
    } on PlatformException catch (e) {
      throw VideoExtractionException('probe failed: ${e.message}');
    } on MissingPluginException catch (e) {
      throw VideoExtractionException('probe unavailable: ${e.message}');
    }
    if (reply == null) {
      throw VideoExtractionException('probe: empty reply for $videoPath');
    }
    final map = reply.cast<String, Object?>();
    final width = (map['width'] as num?)?.toInt() ?? 0;
    final height = (map['height'] as num?)?.toInt() ?? 0;
    if (width <= 0 || height <= 0) {
      throw VideoExtractionException('probe: missing stream dimensions');
    }
    final duration = (map['durationSeconds'] as num?)?.toDouble() ?? 0.0;
    return VideoInfo(
      width: width,
      height: height,
      frameRate: (map['frameRate'] as num?)?.toDouble() ?? 0.0,
      durationSeconds: duration.isFinite && duration > 0 ? duration : 0.0,
    );
  }

  @override
  Stream<ExtractedFrame> extract(
    String videoPath, {
    required int targetWidth,
    required int targetHeight,
    double sampleFps = 1.0,
    int maxFrames = kMaxVideoFrames,
  }) async* {
    assert(videoPath.isNotEmpty, 'videoPath must be non-empty');
    assert(targetWidth > 0 && targetWidth <= CARTY_FRAME_MAX_DIM,
        'targetWidth out of range');
    assert(targetHeight > 0 && targetHeight <= CARTY_FRAME_MAX_DIM,
        'targetHeight out of range');
    assert(sampleFps > 0 && sampleFps.isFinite, 'sampleFps must be positive');
    assert(maxFrames > 0 && maxFrames <= kMaxVideoFrames,
        'maxFrames out of range (1..$kMaxVideoFrames)');

    final info = await probe(videoPath);
    final frameBytes = targetWidth * targetHeight * kExtractChannels;
    final stepUs = (1000000 / sampleFps).round();

    // Bound the sample count: never more than maxFrames, and no further than the
    // clip's duration when it is known (an unknown duration falls back to the
    // maxFrames ceiling and stops early on the decoder's first null).
    var count = maxFrames;
    if (info.durationSeconds > 0) {
      final byDuration = (info.durationSeconds * sampleFps).floor() + 1;
      if (byDuration < count) count = byDuration;
    }
    assert(count >= 1 && count <= maxFrames, 'sample count out of range');

    for (var emitted = 0; emitted < count; emitted++) {
      final timeUs = emitted * stepUs;
      final Uint8List? rgba;
      try {
        rgba = await channel.invokeMethod<Uint8List>(
          'frameAt',
          <String, Object?>{
            'path': videoPath,
            'timeUs': timeUs,
            'targetWidth': targetWidth,
            'targetHeight': targetHeight,
          },
        );
      } on PlatformException catch (e) {
        throw VideoExtractionException('frameAt($timeUs): ${e.message}');
      }
      // A null reply means the decoder is out of frames — a clean end of
      // stream, not an error (short clip, or sampling past the last frame).
      if (rgba == null) break;
      if (rgba.length != frameBytes) {
        throw VideoExtractionException(
            'frameAt($timeUs): ${rgba.length} bytes != $frameBytes');
      }
      yield ExtractedFrame(
        index: emitted,
        width: targetWidth,
        height: targetHeight,
        channels: kExtractChannels,
        rgba: rgba,
      );
    }
  }
}
