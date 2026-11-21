/// Carty video → map pipeline — public barrel.
///
/// The desktop-dev path that turns a local recording into a live D&D-style map:
///   local video file
///     -> [VideoFrameExtractor] (ffmpeg, bounded RGBA frame stream)
///     -> [VideoToMapPipeline] (background isolate; [driveFrame] per frame across
///        the FFI bridge into an accreting [MapGraph])
///     -> [MapGraphPainter] (live spatial render that grows as nodes commit).
///
/// Architecture: this layer sits ABOVE the FFI front door
/// (`lib/carty.dart`), reusing the `lib/inference` seam ([InferenceEngine] /
/// [nativeInferer]) and the `lib/vc` map types. It owns NO new FFI symbols.
library;

export 'video/frame_extractor.dart';
export 'video/map_graph_painter.dart';
export 'video/pipeline.dart';
