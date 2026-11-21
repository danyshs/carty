/// Canonical, deterministic text encoding + content hashing for the Carty
/// version-control engine (local-first).
///
/// Everything the VC engine stores on disk is *content-addressed*: an object's
/// name is a hash of its bytes. That only works if the bytes are **canonical** —
/// the same logical value must always encode to the exact same string, no
/// matter how the in-memory object was built. Two rules guarantee that here:
///
///   1. Map keys are emitted in lexicographic order (never insertion order).
///   2. Output is pretty-printed with a fixed 2-space indent, one value per
///      line — so the result is human-readable AND line-diffable (a one-node
///      change touches one block of lines, like a source file).
///
/// This module is pure (no `dart:io`, no clock, no randomness): the same input
/// always yields the same output across processes, which is what makes the
/// commit DAG reproducible.
library;

import 'dart:convert' show utf8;

/// Encodes a JSON-shaped value (`Map`/`List`/`String`/`num`/`bool`/`null`) into
/// canonical, pretty, deterministic text.
///
/// Determinism contract:
///   - object keys sorted with [Comparable.compare] (lexicographic, stable);
///   - numbers via [num.toString] (Dart emits the shortest round-trip form,
///     which is deterministic for a given value);
///   - strings JSON-escaped.
String canonicalEncode(Object? value) {
  final buffer = StringBuffer();
  _encode(value, buffer, 0);
  return buffer.toString();
}

void _encode(Object? value, StringBuffer out, int depth) {
  if (value == null) {
    out.write('null');
  } else if (value is bool) {
    out.write(value ? 'true' : 'false');
  } else if (value is num) {
    // Reject non-finite: NaN/Infinity are not valid JSON and would round-trip
    // ambiguously, breaking content addressing. Crash at the boundary.
    assert(value.isFinite, 'canonical numbers must be finite, got: $value');
    out.write(value.toString());
  } else if (value is String) {
    _encodeString(value, out);
  } else if (value is List) {
    _encodeList(value, out, depth);
  } else if (value is Map) {
    _encodeMap(value, out, depth);
  } else {
    // A non-JSON type reached the encoder: that is a programming error, not a
    // recoverable state. Fail loudly rather than emit a lossy `toString()`.
    throw ArgumentError('canonicalEncode: unsupported type ${value.runtimeType}');
  }
}

void _encodeList(List<Object?> list, StringBuffer out, int depth) {
  if (list.isEmpty) {
    out.write('[]');
    return;
  }
  final pad = '  ' * (depth + 1);
  out.write('[\n');
  for (var i = 0; i < list.length; i++) {
    out.write(pad);
    _encode(list[i], out, depth + 1);
    if (i != list.length - 1) out.write(',');
    out.write('\n');
  }
  out.write('  ' * depth);
  out.write(']');
}

void _encodeMap(Map<Object?, Object?> map, StringBuffer out, int depth) {
  if (map.isEmpty) {
    out.write('{}');
    return;
  }
  // Sort keys for determinism. Keys must be strings (JSON object keys).
  final keys = map.keys.map((k) {
    assert(k is String, 'canonical map keys must be String, got ${k.runtimeType}');
    return k as String;
  }).toList()
    ..sort(Comparable.compare);

  final pad = '  ' * (depth + 1);
  out.write('{\n');
  for (var i = 0; i < keys.length; i++) {
    final key = keys[i];
    out.write(pad);
    _encodeString(key, out);
    out.write(': ');
    _encode(map[key], out, depth + 1);
    if (i != keys.length - 1) out.write(',');
    out.write('\n');
  }
  out.write('  ' * depth);
  out.write('}');
}

void _encodeString(String value, StringBuffer out) {
  out.write('"');
  for (final unit in value.runes) {
    switch (unit) {
      case 0x22: // "
        out.write(r'\"');
      case 0x5C: // backslash
        out.write(r'\\');
      case 0x08:
        out.write(r'\b');
      case 0x0C:
        out.write(r'\f');
      case 0x0A:
        out.write(r'\n');
      case 0x0D:
        out.write(r'\r');
      case 0x09:
        out.write(r'\t');
      default:
        if (unit < 0x20) {
          out.write('\\u${unit.toRadix4()}');
        } else {
          out.write(String.fromCharCode(unit));
        }
    }
  }
  out.write('"');
}

extension on int {
  /// Lower-case 4-digit hex, for `\uXXXX` control-char escapes.
  String toRadix4() => toRadixString(16).padLeft(4, '0');
}

/// SHA-256 content hash, rendered as 64 lowercase hex chars.
///
/// This is the object name in the content-addressed VC store: a commit/graph's
/// identity IS the hash of its canonical bytes. SHA-256
/// replaces the former 64-bit FNV-1a: the FNV hash was fast
/// but only 64 bits wide, so its accidental-collision floor (~2^32 objects by
/// the birthday bound) is too low for a store the user can fork/merge/share —
/// once maps are git-style shared, a name clash silently aliases two distinct
/// maps. A 256-bit digest makes accidental collision effectively impossible and
/// matches the git mental model the product surfaces.
///
/// IMPLEMENTED IN-MODULE ON PURPOSE: this file is pure and dependency-free (no
/// `dart:io`, no clock, no third-party package), which is what makes the commit
/// DAG reproducible across processes and platforms. `package:crypto` is only a
/// *transitive* dep here (no direct pubspec entry), so importing it would couple
/// the VC store's object identity to a dependency that is not ours to keep — a
/// silent removal upstream would break every stored hash. The standard FIPS 180-4
/// SHA-256 below is small, exact, and deterministic, so the seam stays narrow
/// ([contentHash] is the only caller-visible entry).
String contentHash(String canonicalText) {
  assert(canonicalText.isNotEmpty, 'refusing to hash empty content');
  final digest = _sha256(utf8.encode(canonicalText));
  final out = StringBuffer();
  for (final b in digest) {
    out.write(b.toRadixString(16).padLeft(2, '0'));
  }
  final hex = out.toString();
  assert(hex.length == 64, 'SHA-256 digest must render as 64 hex chars');
  return hex;
}

/// FIPS 180-4 SHA-256 over [message], returning the 32-byte digest.
///
/// Self-contained (no `package:crypto`) so [contentHash] — and therefore the VC
/// store's object identity — owns its hashing and never depends on a package
/// that is only transitively present. All arithmetic is masked to 32 bits with
/// `& _mask32` because Dart's native int is 64-bit (and arbitrary-precision on
/// the web), so unmasked rotates/adds would diverge from the spec across
/// platforms — defeating content addressing. Bounded by construction: the work
/// is exactly one pass over a fixed-size padded message (Tiger Style).
const int _mask32 = 0xFFFFFFFF;

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

// `>>>` (logical shift) not `>>` (arithmetic): on Dart Web an int is a 32-bit
// signed JS value, so `>>` sign-extends when the MSB is set and corrupts the
// rotation. `>>>` shifts in zeros, matching the VM's 64-bit behaviour so the
// digest is identical across platforms (content-addressing must not diverge).
int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & _mask32;

List<int> _sha256(List<int> message) {
  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  // Pad: append 0x80, then zeros, then the 64-bit big-endian bit length, so the
  // total is a whole number of 512-bit (64-byte) blocks.
  final bitLen = message.length * 8;
  final padded = <int>[...message, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  // Split the 64-bit length into two 32-bit words before emitting bytes: Dart
  // Web masks shift counts to 5 bits, so `bitLen >> 32` would wrap to `>> 0` and
  // garble the big-endian length block. `/0x100000000` (float divide) extracts
  // the high word portably; the low word masks to 32 bits.
  final hiLen = (bitLen / 0x100000000).floor() & _mask32;
  final loLen = bitLen & _mask32;
  for (var i = 3; i >= 0; i--) {
    padded.add((hiLen >>> (8 * i)) & 0xFF);
  }
  for (var i = 3; i >= 0; i--) {
    padded.add((loLen >>> (8 * i)) & 0xFF);
  }

  final w = List<int>.filled(64, 0);
  for (var block = 0; block < padded.length; block += 64) {
    for (var i = 0; i < 16; i++) {
      final j = block + i * 4;
      w[i] = ((padded[j] << 24) |
              (padded[j + 1] << 16) |
              (padded[j + 2] << 8) |
              padded[j + 3]) &
          _mask32;
    }
    for (var i = 16; i < 64; i++) {
      // `>>>` for the same web sign-extension reason as `_rotr` above.
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }

    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & _mask32;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask32;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask32;
    }

    h0 = (h0 + a) & _mask32;
    h1 = (h1 + b) & _mask32;
    h2 = (h2 + c) & _mask32;
    h3 = (h3 + d) & _mask32;
    h4 = (h4 + e) & _mask32;
    h5 = (h5 + f) & _mask32;
    h6 = (h6 + g) & _mask32;
    h7 = (h7 + h) & _mask32;
  }

  final out = <int>[];
  for (final hv in [h0, h1, h2, h3, h4, h5, h6, h7]) {
    out.add((hv >> 24) & 0xFF);
    out.add((hv >> 16) & 0xFF);
    out.add((hv >> 8) & 0xFF);
    out.add(hv & 0xFF);
  }
  return out;
}
