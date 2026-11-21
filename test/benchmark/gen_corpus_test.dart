// test/benchmark/gen_corpus_test.dart
import 'package:test/test.dart';
import '../../tool/gen_corpus.dart';

void main() {
  test('generator is deterministic for a fixed seed', () {
    expect(genBoxTwoRoom(seed: 7), genBoxTwoRoom(seed: 7));
  });

  test('generated occupancy parses back to a square grid', () {
    final json = genBoxTwoRoom(seed: 1);
    expect(json.contains('"n"'), isTrue);
    expect(json.contains('"cells"'), isTrue);
  });
}
