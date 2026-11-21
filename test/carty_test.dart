// Unit tests for the Carty Dart FFI wrapper (lib/carty.dart).
//
// These run on the HOST toolchain against native/build/libcarty_bridge.so
// (the fast `ctest` build of the same translation unit the APK cross-compiles).
// Build it first:  cmake -S native -B native/build -G Ninja && cmake --build native/build
//
// They cover the deterministic half of the memory contract: alloc/size, the
// zero-copy view, and exactly-once free via dispose(). The GC-time
// NativeFinalizer path is correct by construction (attach token == handle,
// detached before manual free) and intentionally not force-GC'd here.

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:carty/carty.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final soPath = File('native/build/libcarty_bridge.so').absolute.path;

  late Carty carty;

  setUpAll(() {
    expect(
      File(soPath).existsSync(),
      isTrue,
      reason: 'Build the host bridge first: cmake --build native/build ($soPath)',
    );
    carty = Carty.fromLibrary(DynamicLibrary.open(soPath));
  });

  test('version is a non-empty bridge string', () {
    expect(carty.version, isNotEmpty);
    expect(carty.version, contains('0.2.0'));
  });

  test('allocFrame sizes the buffer as width*height*channels', () {
    final frame = carty.allocFrame(width: 4, height: 4, channels: 4);
    addTearDown(frame.dispose);
    expect(frame.lengthInBytes, 4 * 4 * 4);
    expect(frame.bytes.length, 64);
  });

  test('a fresh frame is zero-initialised', () {
    final frame = carty.allocFrame(width: 8, height: 8, channels: 3);
    addTearDown(frame.dispose);
    expect(frame.bytes.every((b) => b == 0), isTrue);
  });

  test('bytes is a ZERO-COPY view: writes hit the same native buffer', () {
    final frame = carty.allocFrame(width: 2, height: 2, channels: 1);
    addTearDown(frame.dispose);
    frame.bytes[0] = 42;
    frame.bytes[3] = 7;
    // Re-fetching the view must observe the prior writes — proving it is a view
    // over native memory, not a fresh copy.
    expect(frame.bytes[0], 42);
    expect(frame.bytes[3], 7);
  });

  test('dispose() is idempotent and blocks further use', () {
    final frame = carty.allocFrame(width: 4, height: 4, channels: 1);
    frame.dispose();
    expect(frame.isDisposed, isTrue);
    expect(frame.dispose, returnsNormally); // second dispose is a no-op
    expect(() => frame.bytes, throwsStateError);
  });

  test('out-of-bounds dimensions are rejected before the native boundary', () {
    expect(
      () => carty.allocFrame(width: 0, height: 4, channels: 4),
      throwsArgumentError,
    );
    expect(
      () => carty.allocFrame(
        width: cartyFrameMaxDim + 1,
        height: 4,
        channels: 4,
      ),
      throwsArgumentError,
    );
    expect(
      () => carty.allocFrame(
        width: 4,
        height: 4,
        channels: cartyFrameMaxChannels + 1,
      ),
      throwsArgumentError,
    );
  });

  // Small grid: carty_vectorize scales ~O(n^4), so the default n=1024 grid is
  // unvectorizable in a unit test (a 6 m scene fits a tiny grid anyway).
  test('vectorize() returns a GeoJSON FeatureCollection for an anchored grid', () {
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    addTearDown(grid.dispose);
    // Anchor + occupy via one synthetic depth frame (1 m wall ahead).
    grid.accreteFromDepth(
      depth: Uint16List.fromList([1000, 1000, 1000, 1000]),
      dw: 2,
      dh: 2,
      intrinsics: [40, 40, 1, 1],
      pose: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      keyframeId: 1,
    );
    final fc = grid.vectorize();
    expect(fc['type'], 'FeatureCollection');
    expect(fc['features'], isA<List<Object?>>());
  });

  test('vectorize() throws StateError on an unanchored (empty) grid', () {
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    addTearDown(grid.dispose);
    expect(grid.vectorize, throwsStateError);
  });
}
