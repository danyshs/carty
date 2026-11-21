import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:carty/benchmark/grid_occupancy.dart';
import 'package:carty/carty.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final soPath = File('native/build/libcarty_bridge.so').absolute.path;
  late Carty carty;

  setUpAll(() {
    expect(File(soPath).existsSync(), isTrue,
        reason: 'Build the host bridge first: cmake --build native/build');
    carty = Carty.fromLibrary(DynamicLibrary.open(soPath));
  });

  test('occupancyFromGrid collapses occupied bands to a ground map', () {
    final grid = carty.createWorldGrid(n: 96, h: 16, resM: 0.1, bandM: 0.25);
    addTearDown(grid.dispose);
    grid.accreteFromDepth(
      depth: Uint16List.fromList([1000, 1000, 1000, 1000]),
      dw: 2,
      dh: 2,
      intrinsics: [40, 40, 1, 1],
      pose: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      keyframeId: 1,
    );
    final occ = occupancyFromGrid(grid);
    expect(occ.n, grid.n);
    expect(occ.resM, grid.resolution.resM);
    expect(occ.cells.where((c) => c == 1), isNotEmpty); // something was fused
  });
}
