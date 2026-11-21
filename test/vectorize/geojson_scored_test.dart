import 'dart:convert';
import 'package:carty/vectorize/geojson_scored.dart';
import 'package:carty/benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses metric room Polygons and door connections into ScoredGraph', () {
    final fc = jsonDecode('''
    {"type":"FeatureCollection","features":[
      {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[1,1],[2,1],[2,5],[1,5],[1,1]]]},
       "properties":{"id":0,"type":"room","description":"","confidence":1,"connections":[]}},
      {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[3,1],[5,1],[5,5],[3,5],[3,1]]]},
       "properties":{"id":1,"type":"room","description":"","confidence":1,"connections":[]}},
      {"type":"Feature","geometry":{"type":"Point","coordinates":[2.5,3]},
       "properties":{"id":2,"type":"door","description":"","confidence":1,"connections":[0,1]}}
    ]}''') as Map<String, Object?>;
    final sg = scoredGraphFromGeoJson(fc);
    expect(sg.rooms.length, 2);
    expect(sg.doors.length, 1);
    expect(sg.doors.first.roomA, 0);
    expect(sg.doors.first.roomB, 1);
    expect(sg.rooms.first.polygon.length, 4); // closing dup dropped
  });
}
