/// The parser that turns a model's text output into strict map modifications
/// against the Carty version-control schema.
///
/// The flow is: raw model text -> [MapUpdate.parse] (tolerant extraction +
/// STRICT schema validation) -> [MapUpdate.apply] over a [MapGraph] -> a new,
/// immutable [MapGraph] that can be committed via the VC engine. Every failure
/// mode is SAFE: a malformed document throws a typed exception
/// and NOTHING is applied — `apply` builds a fresh graph and only returns it on
/// full success, so the input graph is never partially mutated.
///
/// This is the authoritative parser. The native `carty_validate_map_update_json`
/// is only a cheap structural gate at the boundary; the schema-strict rules
/// (op kinds, id ranges, [0,1] coordinates, connection bounds) live here, in the
/// same layer as the version-control engine the result feeds.
library;

import 'dart:convert';

import '../vc/map_graph.dart';
import '../vc/map_node.dart';

/// A model output that is not a well-formed map-update document. Thrown by
/// [MapUpdate.parse]; carrying a precise reason so the failure is debuggable but
/// always recoverable (never a crash, never a partial apply).
class MapUpdateFormatException implements Exception {
  final String message;
  MapUpdateFormatException(this.message);
  @override
  String toString() => 'MapUpdateFormatException: $message';
}

/// A structurally-valid update whose ops cannot apply to the target graph
/// (e.g. "add" reuses a live id, "update" targets a missing id). Distinct from
/// [MapUpdateFormatException] because the document was well-formed — the graph
/// state simply conflicts. Apply is transactional, so the graph is untouched.
class MapUpdateConflictException implements Exception {
  final String message;
  MapUpdateConflictException(this.message);
  @override
  String toString() => 'MapUpdateConflictException: $message';
}

/// The four structural mutations the model may emit.
enum MapOpKind { add, update, remove, connect }

/// One validated operation. Fields are populated per [kind]; unrelated fields
/// are null. Range/shape validation happens at [MapUpdate.parse] time, so a
/// constructed [MapOp] is already schema-valid.
class MapOp {
  final MapOpKind kind;
  final int id;
  final String? type;
  final String? description;
  final double? x;
  final double? y;
  final double? confidence;
  final List<int>? connections;

  const MapOp({
    required this.kind,
    required this.id,
    this.type,
    this.description,
    this.x,
    this.y,
    this.confidence,
    this.connections,
  });
}

/// A parsed, schema-valid batch of operations.
class MapUpdate {
  final List<MapOp> ops;
  const MapUpdate(this.ops);

  /// Parses [rawModelOutput] into a schema-valid [MapUpdate].
  ///
  /// TOLERANT extraction: the model is steered to emit bare JSON, but real
  /// decoder output sometimes wraps it in prose or ```json fences. We locate the
  /// first balanced top-level `{...}` and ignore the rest. STRICT validation:
  /// once decoded, every op must match the schema exactly or this throws
  /// [MapUpdateFormatException] — there is no lenient coercion of bad data.
  static MapUpdate parse(String rawModelOutput) {
    final jsonText = _extractJsonObject(rawModelOutput);

    final Object? decoded;
    try {
      decoded = jsonDecode(jsonText);
    } on FormatException catch (e) {
      throw MapUpdateFormatException('not valid JSON: ${e.message}');
    }

    if (decoded is! Map) {
      throw MapUpdateFormatException('root is not a JSON object');
    }
    final rawOps = decoded['ops'];
    if (rawOps is! List) {
      throw MapUpdateFormatException('missing or non-array "ops"');
    }

    final ops = <MapOp>[];
    for (var i = 0; i < rawOps.length; i++) {
      ops.add(_parseOp(rawOps[i], i));
    }
    return MapUpdate(ops);
  }

  /// Applies these ops, in order, to [base], returning a NEW graph. The input
  /// is never mutated; on any conflict this throws and [base] is untouched
  /// (transactional). Bounds (kMaxNodes, kMaxConnections, [0,1]) are enforced by
  /// [MapNode]/[MapGraph] construction, so the result is always a valid graph.
  MapGraph apply(MapGraph base) {
    var graph = base;
    for (final op in ops) {
      switch (op.kind) {
        case MapOpKind.add:
          if (graph.contains(op.id)) {
            throw MapUpdateConflictException(
                'add: id ${op.id} already exists');
          }
          graph = graph.withNode(MapNode(
            id: op.id,
            type: op.type!,
            description: op.description ?? '',
            x: op.x!,
            y: op.y!,
            confidence: op.confidence!,
            connections: op.connections ?? const [],
          ));
        case MapOpKind.update:
          final existing = graph.node(op.id);
          if (existing == null) {
            throw MapUpdateConflictException(
                'update: id ${op.id} does not exist');
          }
          graph = graph.withNode(existing.copyWith(
            type: op.type,
            description: op.description,
            x: op.x,
            y: op.y,
            confidence: op.confidence,
            connections: op.connections,
          ));
        case MapOpKind.connect:
          final existing = graph.node(op.id);
          if (existing == null) {
            throw MapUpdateConflictException(
                'connect: id ${op.id} does not exist');
          }
          graph = graph.withNode(existing.copyWith(connections: op.connections));
        case MapOpKind.remove:
          if (!graph.contains(op.id)) {
            throw MapUpdateConflictException(
                'remove: id ${op.id} does not exist');
          }
          graph = graph.withoutNode(op.id);
      }
    }
    return graph;
  }

  // ---- strict per-op parsing --------------------------------------------

  static MapOp _parseOp(Object? raw, int index) {
    if (raw is! Map) {
      throw MapUpdateFormatException('ops[$index] is not an object');
    }
    final kind = _parseKind(raw['op'], index);
    final id = _requireId(raw['id'], index);

    switch (kind) {
      case MapOpKind.add:
        return MapOp(
          kind: kind,
          id: id,
          type: _requireNonEmptyString(raw['type'], index, 'type'),
          description: _optionalString(raw['description'], index, 'description'),
          x: _requireUnit(raw['x'], index, 'x'),
          y: _requireUnit(raw['y'], index, 'y'),
          confidence: _requireUnit(raw['confidence'], index, 'confidence'),
          connections: _optionalConnections(raw['connections'], index),
        );
      case MapOpKind.update:
        final connections = _optionalConnections(raw['connections'], index);
        final op = MapOp(
          kind: kind,
          id: id,
          type: _optionalNonEmptyString(raw['type'], index, 'type'),
          description: _optionalString(raw['description'], index, 'description'),
          x: _optionalUnit(raw['x'], index, 'x'),
          y: _optionalUnit(raw['y'], index, 'y'),
          confidence: _optionalUnit(raw['confidence'], index, 'confidence'),
          connections: connections,
        );
        // A no-op update is almost certainly a model mistake; reject it so bad
        // output never silently produces an identical, pointless commit.
        if (op.type == null &&
            op.description == null &&
            op.x == null &&
            op.y == null &&
            op.confidence == null &&
            op.connections == null) {
          throw MapUpdateFormatException(
              'ops[$index]: update has no fields to change');
        }
        return op;
      case MapOpKind.connect:
        final connections = _optionalConnections(raw['connections'], index);
        if (connections == null) {
          throw MapUpdateFormatException(
              'ops[$index]: connect requires a "connections" array');
        }
        return MapOp(kind: kind, id: id, connections: connections);
      case MapOpKind.remove:
        return MapOp(kind: kind, id: id);
    }
  }

  static MapOpKind _parseKind(Object? raw, int index) {
    if (raw is! String) {
      throw MapUpdateFormatException('ops[$index]: "op" must be a string');
    }
    switch (raw) {
      case 'add':
        return MapOpKind.add;
      case 'update':
        return MapOpKind.update;
      case 'remove':
        return MapOpKind.remove;
      case 'connect':
        return MapOpKind.connect;
      default:
        throw MapUpdateFormatException('ops[$index]: unknown op "$raw"');
    }
  }

  static int _requireId(Object? raw, int index) {
    if (raw is! int) {
      throw MapUpdateFormatException('ops[$index]: "id" must be an integer');
    }
    if (raw < 0 || raw >= kMaxNodes) {
      throw MapUpdateFormatException(
          'ops[$index]: id $raw out of range [0,$kMaxNodes)');
    }
    return raw;
  }

  static String _requireNonEmptyString(Object? raw, int index, String field) {
    if (raw is! String || raw.isEmpty) {
      throw MapUpdateFormatException(
          'ops[$index]: "$field" must be a non-empty string');
    }
    return raw;
  }

  static String? _optionalNonEmptyString(Object? raw, int index, String field) {
    if (raw == null) return null;
    return _requireNonEmptyString(raw, index, field);
  }

  static String? _optionalString(Object? raw, int index, String field) {
    if (raw == null) return null;
    if (raw is! String) {
      throw MapUpdateFormatException('ops[$index]: "$field" must be a string');
    }
    return raw;
  }

  static double _requireUnit(Object? raw, int index, String field) {
    final v = _optionalUnit(raw, index, field);
    if (v == null) {
      throw MapUpdateFormatException('ops[$index]: "$field" is required');
    }
    return v;
  }

  static double? _optionalUnit(Object? raw, int index, String field) {
    if (raw == null) return null;
    if (raw is! num || !raw.isFinite) {
      throw MapUpdateFormatException(
          'ops[$index]: "$field" must be a finite number');
    }
    final v = raw.toDouble();
    if (v < 0.0 || v > 1.0) {
      throw MapUpdateFormatException(
          'ops[$index]: "$field" $v out of [0,1]');
    }
    return v;
  }

  static List<int>? _optionalConnections(Object? raw, int index) {
    if (raw == null) return null;
    if (raw is! List) {
      throw MapUpdateFormatException(
          'ops[$index]: "connections" must be an array');
    }
    if (raw.length > kMaxConnections) {
      throw MapUpdateFormatException(
          'ops[$index]: too many connections (${raw.length} > $kMaxConnections)');
    }
    final out = <int>[];
    for (final c in raw) {
      if (c is! int) {
        throw MapUpdateFormatException(
            'ops[$index]: connection ids must be integers');
      }
      if (c < 0 || c >= kMaxNodes) {
        throw MapUpdateFormatException(
            'ops[$index]: connection id $c out of range [0,$kMaxNodes)');
      }
      out.add(c);
    }
    return out;
  }

  // ---- tolerant JSON-object extraction ----------------------------------

  /// Returns the first balanced top-level `{...}` in [raw], skipping any leading
  /// prose or ```json fences and any trailing text. Throws if no balanced object
  /// is present. String literals are respected so braces inside a label do not
  /// confuse the scan — the same contract the native gate upholds.
  static String _extractJsonObject(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) {
      throw MapUpdateFormatException('no JSON object found in model output');
    }
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < raw.length; i++) {
      final c = raw.codeUnitAt(i);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == 0x5C) {
          escaped = true;
        } else if (c == 0x22) {
          inString = false;
        }
        continue;
      }
      switch (c) {
        case 0x22: // "
          inString = true;
        case 0x7B: // {
          depth++;
        case 0x7D: // }
          depth--;
          if (depth == 0) {
            return raw.substring(start, i + 1);
          }
      }
    }
    throw MapUpdateFormatException('unbalanced JSON object in model output');
  }
}
