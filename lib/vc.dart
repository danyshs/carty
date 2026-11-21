/// Carty Version-Control Engine — public barrel.
///
/// An immutable, text-diffable, content-addressed DAG for map versions: fork,
/// commit, and PR D&D-style map graphs entirely on-device
/// (local-first). Dart never reaches the native bridge from here — this layer is
/// pure data + filesystem, independent of the FFI surface.
library;

export 'vc/canonical.dart';
export 'vc/map_node.dart';
export 'vc/map_graph.dart';
export 'vc/commit.dart';
export 'vc/merge.dart';
export 'vc/repository.dart';
export 'vc/pull_request.dart';
