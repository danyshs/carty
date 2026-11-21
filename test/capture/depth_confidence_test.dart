// confidence weighting confidence-plane smoke test: folding the same hit with full confidence
// (conf=null) vs. reduced confidence (conf[1*4+1]=150) must yield different
// grid hashes — proving the conf weighting changes the log-odds magnitude.
// The .so must be built first (cmake --build native/build).
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:carty/carty.dart';
import 'package:crypto/crypto.dart';
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

  test('accreteFromDepth conf path differs from null path', () {
    // A 4x4 frame with one in-bounds hit (u=1,v=1,Z=2.0m), identity pose.
    final depth = Uint16List(16)..[1 * 4 + 1] = 2000;
    const k = <double>[2.0, 2.0, 1.5, 1.5];
    const pose = <double>[1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1];

    // NULL conf -> full fold.
    final gNull = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(gNull.dispose);
    final sNull = gNull.accreteFromDepth(
        depth: depth, dw: 4, dh: 4, intrinsics: k, pose: pose, keyframeId: 1);
    final fullHash = sha256.convert(gNull.cells).toString();

    // Mid confidence (150) -> reduced fold, so a different grid hash.
    final conf = Uint8List(16)..[1 * 4 + 1] = 150;
    final gConf = carty.createWorldGrid(n: 8, h: 8, resM: 0.5, bandM: 0.5);
    addTearDown(gConf.dispose);
    final sConf = gConf.accreteFromDepth(
        depth: depth, dw: 4, dh: 4, conf: conf,
        intrinsics: k, pose: pose, keyframeId: 1);
    final confHash = sha256.convert(gConf.cells).toString();

    expect(sNull, CartyFuseStatus.ok);
    expect(sConf, CartyFuseStatus.ok);
    expect(confHash, isNot(equals(fullHash)),
        reason: 'conf weighting must change the fold magnitude');
  });
}
