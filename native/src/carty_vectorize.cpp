/*
 * carty_vectorize.cpp — Vectorize stage: fused CartyWorldGrid -> MapGraph GeoJSON
 * via classical CV. See carty_bridge.h for the FFI contract and
 * carty_vectorize_internal.h for the per-stage helpers (unit-tested in isolation).
 */
#include "carty_bridge.h"
#include "carty_bridge_internal.h"   // CARTY_ASSERT + concrete CartyWorldGrid
#include "carty_vectorize_internal.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <utility>
#include <vector>

namespace {

constexpr int32_t kNoRoom = -1;   // wall, exterior, or not visited yet
constexpr int32_t kInFlood = -2;  // queued in the current component, id not known yet
constexpr int kNeighbours = 4;

/* a cell of the 2D top-down ground grid */
struct GridCell {
  int32_t col, row;
};

/* Only INTERIOR walls (not the outer boundary ring) seal, so a 1-cell-wide room
 * against the border isn't mistaken for a doorway and sealed away from flood-fill. */
bool seals_doorway(const uint8_t *labels, int32_t grid_side, GridCell cell) {
  const int32_t idx = (cell.row * grid_side) + cell.col;
  const bool wall_up = cell.row > 1 && labels[idx - grid_side] == kCellWall;
  const bool wall_down = cell.row < grid_side - 2 && labels[idx + grid_side] == kCellWall;
  const bool wall_left = cell.col > 1 && labels[idx - 1] == kCellWall;
  const bool wall_right = cell.col < grid_side - 2 && labels[idx + 1] == kCellWall;
  return (wall_up && wall_down) || (wall_left && wall_right);
}

/* Sealing pre-pass (morphological closing of <=1-cell doorways): a non-wall cell with
 * wall on BOTH vertical OR BOTH horizontal neighbours counts as wall, so a doorway gap
 * does not 4-connect two rooms into one component. Written to a separate mask so
 * detect_doors still reads the ORIGINAL labels. */
void seal_doorways(const uint8_t *labels, int32_t grid_side, std::vector<uint8_t> &sealed) {
  for (int32_t row = 0; row < grid_side; ++row) {
    for (int32_t col = 0; col < grid_side; ++col) {
      const int32_t idx = (row * grid_side) + col;
      const bool interior = col > 0 && col < grid_side - 1 && row > 0 && row < grid_side - 1;
      bool wall = labels[idx] == kCellWall;
      if (!wall && interior) {
        wall = seals_doorway(labels, grid_side, {col, row});
      }
      sealed[idx] = wall ? kCellWall : kCellFloor;
    }
  }
}

struct FloodState {
  std::vector<uint8_t> sealed;
  std::vector<int32_t> queue;  // at most every cell, enqueued once
  int32_t *room_ids;
  int32_t grid_side;
};

/* BFS the component holding seed. Its members land in queue[0, returned count);
 * exterior is set when any member touches the grid border. */
int32_t flood_component(FloodState &state, int32_t seed, bool *exterior) {
  const int32_t side = state.grid_side;
  int32_t head = 0;
  int32_t tail = 0;
  state.queue[tail++] = seed;
  state.room_ids[seed] = kInFlood;
  *exterior = false;
  while (head < tail) {
    const int32_t cell = state.queue[head++];
    const int32_t col = cell % side;
    const int32_t row = cell / side;
    if (col == 0 || row == 0 || col == side - 1 || row == side - 1) {
      *exterior = true;
    }
    const int32_t neighbours[kNeighbours] = {cell - 1, cell + 1, cell - side, cell + side};
    const bool in_grid[kNeighbours] = {col > 0, col < side - 1, row > 0, row < side - 1};
    for (int dir = 0; dir < kNeighbours; ++dir) {
      const int32_t next = neighbours[dir];
      if (!in_grid[dir] || state.sealed[next] == kCellWall || state.room_ids[next] != kNoRoom) {
        continue;
      }
      state.room_ids[next] = kInFlood;
      state.queue[tail++] = next;
    }
  }
  return tail;
}

struct RoomPair {
  int32_t low, high;
};

/* The two different rooms a cell sits between (left/right first, then up/down),
 * ordered low to high; low is kNoRoom when it straddles none. */
RoomPair straddled_rooms(const int32_t *room_ids, int32_t grid_side, GridCell cell) {
  auto const room_at = [&](int32_t col, int32_t row) {
    return (col < 0 || row < 0 || col >= grid_side || row >= grid_side)
               ? kNoRoom
               : room_ids[(row * grid_side) + col];
  };
  const int32_t left = room_at(cell.col - 1, cell.row);
  const int32_t right = room_at(cell.col + 1, cell.row);
  const int32_t above = room_at(cell.col, cell.row - 1);
  const int32_t below = room_at(cell.col, cell.row + 1);
  RoomPair pair = {kNoRoom, kNoRoom};
  if (left >= 0 && right >= 0 && left != right) {
    pair = {left, right};
  } else if (above >= 0 && below >= 0 && above != below) {
    pair = {above, below};
  }
  if (pair.low > pair.high) {
    std::swap(pair.low, pair.high);
  }
  return pair;
}

struct DoorList {
  CartyVecDoor *doors;
  int32_t count;
  int32_t cap;
};

constexpr double kCellCenter = 0.5;       // a cell spans [col, col+1)
constexpr double kMidpoint = 0.5;
constexpr double kDoorMergeDistSq = 2.25;  // 1.5 cells, squared

/* Fold a candidate into a door of the same room pair within 1.5 cells (moving it to
 * the running midpoint), else add it. */
void merge_or_add(DoorList &list, const CartyVecDoor &candidate) {
  for (int32_t door = 0; door < list.count; ++door) {
    CartyVecDoor &known = list.doors[door];
    const double dist_x = known.x - candidate.x;
    const double dist_y = known.y - candidate.y;
    if (known.room_a == candidate.room_a && known.room_b == candidate.room_b &&
        (dist_x * dist_x) + (dist_y * dist_y) <= kDoorMergeDistSq) {
      known.x = (known.x + candidate.x) * kMidpoint;
      known.y = (known.y + candidate.y) * kMidpoint;
      return;
    }
  }
  CARTY_ASSERT(list.count < list.cap && list.count < CARTY_VEC_MAX_DOORS, "doors: cap exceeded");
  list.doors[list.count++] = candidate;
}

/* Classify every ground column; false when the whole grid is free space. */
bool classify_grid(const CartyWorldGrid *grid, std::vector<uint8_t> &labels) {
  const int32_t grid_side = grid->n;
  const int32_t band_count = grid->h;
  CARTY_ASSERT(band_count > 0 && band_count <= CARTY_GRID_MAX_H,
               "carty_vectorize: band count out of range");
  bool any = false;
  for (int32_t row = 0; row < grid_side; ++row) {
    for (int32_t col = 0; col < grid_side; ++col) {
      int8_t column[CARTY_GRID_MAX_H];
      for (int32_t band = 0; band < band_count; ++band) {
        column[band] =
            grid->cells[(((static_cast<size_t>(band) * grid_side) + row) * grid_side) + col];
      }
      const CartyCellLabel label = carty_vec_classify_column(column, band_count);
      labels[(static_cast<size_t>(row) * grid_side) + col] = static_cast<uint8_t>(label);
      if (label != kCellFree) {
        any = true;
      }
    }
  }
  return any;
}

/* Bounded GeoJSON writer over the caller's buffer. */
struct GeoWriter {
  char *buf;
  int32_t size;
  int32_t used;
  int32_t features;
};

/* false when the text didn't fit (ENOSPACE) */
template <typename... Args>
bool emit(GeoWriter &out, const char *fmt, Args... args) {
  const int32_t left = out.size - out.used;
  const int wrote = std::snprintf(out.buf + out.used, static_cast<size_t>(left), fmt, args...);
  if (wrote < 0 || wrote >= left) {
    return false;
  }
  out.used += wrote;
  return true;
}

/* "," before every feature but the first */
const char *feature_separator(GeoWriter &out) { return out.features++ == 0 ? "" : ","; }

/* grid-cell units -> world metres */
struct CellToWorld {
  double origin_x_m, origin_y_m, res_m;
};

double world_x_m(const CellToWorld &frame, double cell_x) {
  return frame.origin_x_m + (cell_x * frame.res_m);
}
double world_y_m(const CellToWorld &frame, double cell_y) {
  return frame.origin_y_m + (cell_y * frame.res_m);
}

bool emit_room(GeoWriter &out, const CellToWorld &frame, const int32_t *room_ids,
               int32_t grid_side, int32_t room) {
  constexpr int32_t kRingCapVerts = 256;
  double ring_xy[kRingCapVerts * 2];
  const int32_t vert_count =
      carty_vec_trace_boundary(room_ids, grid_side, room, ring_xy, kRingCapVerts);
  CARTY_ASSERT(vert_count > 0 && vert_count <= kRingCapVerts,
               "vectorize: a valid room must yield >= 1 boundary vertex");
  if (!emit(out, R"(%s{"type":"Feature","geometry":{"type":"Polygon","coordinates":[[)",
            feature_separator(out))) {
    return false;
  }
  int32_t slot = 0;
  for (int32_t vert = 0; vert < vert_count; ++vert) {
    if (!emit(out, "%s[%.6g,%.6g]", (vert != 0) ? "," : "", world_x_m(frame, ring_xy[slot]),
              world_y_m(frame, ring_xy[slot + 1]))) {
      return false;
    }
    slot += 2;
  }
  // close the ring (repeat the first vertex) per GeoJSON
  if (!emit(out, ",[%.6g,%.6g]]]}", world_x_m(frame, ring_xy[0]), world_y_m(frame, ring_xy[1]))) {
    return false;
  }
  return emit(out,
              R"(,"properties":{"id":%d,"type":"room","description":"","confidence":1,"connections":[]}})",
              room);
}

bool emit_door(GeoWriter &out, const CellToWorld &frame, const CartyVecDoor &door,
               int32_t feature_id) {
  return emit(out,
              R"(%s{"type":"Feature","geometry":{"type":"Point","coordinates":[%.6g,%.6g]},)"
              R"("properties":{"id":%d,"type":"door","description":"","confidence":1,"connections":[%d,%d]}})",
              feature_separator(out), world_x_m(frame, door.x), world_y_m(frame, door.y),
              feature_id, door.room_a, door.room_b);
}

}  // namespace

CartyCellLabel carty_vec_classify_column(const int8_t *band_profile, int32_t band_count) {
  CARTY_ASSERT(band_profile != nullptr, "classify: NULL profile");
  CARTY_ASSERT(band_count > 0 && band_count <= CARTY_GRID_MAX_H,
               "classify: band count out of range");
  const int32_t top_start = band_count / 2;  // top half: [top_start, band_count)
  bool low = false;
  bool top = false;
  bool mid = false;
  for (int32_t band = 0; band < band_count; ++band) {
    if (band_profile[band] <= 0) {
      continue;
    }
    if (band >= top_start) {
      top = true;
    } else if (band == 0) {
      low = true;
    } else {
      mid = true;
    }
  }
  if (top) {
    return kCellWall;
  }
  if (mid) {
    return kCellFurniture;
  }
  if (low) {
    return kCellFloor;
  }
  return kCellFree;
}

int32_t carty_vec_segment_rooms(const uint8_t *labels, int32_t grid_side, int32_t *room_ids) {
  CARTY_ASSERT(labels != nullptr && room_ids != nullptr, "segment: NULL buffer");
  CARTY_ASSERT(grid_side > 0 && grid_side <= CARTY_GRID_MAX_N, "segment: grid side out of range");
  const int32_t total = grid_side * grid_side;
  // Scratch is heap-sized to the ACTUAL total, not the CARTY_GRID_MAX_N worst case: a
  // max-sized static thread_local would reserve ~20 MB of TLS per thread regardless of
  // the grid, a real OOM hazard on Android. This is a once-per-session millisecond op
  //, not the per-frame fusion hot path, so one bounded allocation
  // (grid_side asserted above) is within Tiger Style's "bounded, checked allocations".
  FloodState state = {std::vector<uint8_t>(total), std::vector<int32_t>(total), room_ids,
                      grid_side,};
  seal_doorways(labels, grid_side, state.sealed);
  std::fill(room_ids, room_ids + total, kNoRoom);

  int32_t count = 0;
  for (int32_t seed = 0; seed < total; ++seed) {
    if (state.sealed[seed] == kCellWall || room_ids[seed] != kNoRoom) {
      continue;
    }
    bool exterior = false;
    const int32_t members = flood_component(state, seed, &exterior);
    const int32_t room_id = exterior ? kNoRoom : count;
    if (!exterior) {
      CARTY_ASSERT(count < CARTY_VEC_MAX_ROOMS, "segment: too many rooms");
      ++count;
    }
    // Renumber the component's members. Interior rooms get id>=0, so the seed scan
    // already skips them on revisit. The exterior gets kNoRoom, the same as the
    // unvisited sentinel, so it must be marked visited another way or the scan
    // re-floods the whole exterior once per exterior cell: O(grid_side^4), the >40s
    // hang at 1024. Marking each exterior cell as a flood barrier (sealed=wall) keeps
    // room_ids==kNoRoom for callers; it can never wall off a real room, which is
    // separated from the exterior by actual walls.
    for (int32_t member = 0; member < members; ++member) {
      const int32_t cell = state.queue[member];
      room_ids[cell] = room_id;
      if (exterior) {
        state.sealed[cell] = kCellWall;
      }
    }
  }
  return count;
}

// Traces the axis-aligned bounding rectangle of a room as a 4-vertex CCW closed ring.
// This is the robust-core simplification: correct for any convex or rectilinear room
// whose bounding box is a tight approximation (all test-gate scenes). Marching
// squares would generalize to arbitrary cell-union outlines.
// Cells occupy [col,col+1)×[row,row+1); the lattice corners of the bbox become the verts.
int32_t carty_vec_trace_boundary(const int32_t *room_ids, int32_t grid_side, int32_t room,
                                 double *out_xy, int32_t cap) {
  constexpr int32_t kRingVerts = 4;
  CARTY_ASSERT(room_ids != nullptr && out_xy != nullptr, "trace: NULL buffer");
  CARTY_ASSERT(grid_side > 0 && grid_side <= CARTY_GRID_MAX_N && cap >= kRingVerts,
               "trace: cap must hold 4 verts");
  int32_t min_col = grid_side;
  int32_t max_col = -1;
  int32_t min_row = grid_side;
  int32_t max_row = -1;
  for (int32_t row = 0; row < grid_side; ++row) {
    for (int32_t col = 0; col < grid_side; ++col) {
      if (room_ids[(row * grid_side) + col] == room) {
        min_col = std::min(col, min_col);
        max_col = std::max(col, max_col);
        min_row = std::min(row, min_row);
        max_row = std::max(row, max_row);
      }
    }
  }
  CARTY_ASSERT(max_col >= 0, "trace: room has no cells");
  // CCW in lattice (cell-corner) coords: bottom-left, bottom-right, top-right, top-left
  const double left = min_col;
  const double bottom = min_row;
  const double right = max_col + 1.0;
  const double top = max_row + 1.0;
  const double ring[kRingVerts][2] = {{left, bottom}, {right, bottom}, {right, top}, {left, top}};
  int32_t slot = 0;
  for (const auto &corner : ring) {
    out_xy[slot++] = corner[0];
    out_xy[slot++] = corner[1];
  }
  return kRingVerts;
}

// Detects door candidates (openings in walls connecting two distinct rooms).
// Deliberately consumes BOTH the ORIGINAL labels (so it sees floor at thin gap
// cells) AND the sealed room_ids from carty_vec_segment_rooms (which sealed those
// same cells to -1, making their opposite neighbours belong to two different rooms).
// This dual-mask design is intentional: segmentation seals doorways to split rooms;
// door-detect reads original labels to see the opening and room_ids to identify
// which rooms it joins. Coalesces contiguous candidates of the same room pair
// (within sqrt(2.25) cells) into one door at the running midpoint.
int32_t carty_vec_detect_doors(const uint8_t *labels, const int32_t *room_ids,
                               int32_t grid_side, CartyVecDoor *out, int32_t cap) {
  CARTY_ASSERT(labels != nullptr && room_ids != nullptr && out != nullptr, "doors: NULL");
  CARTY_ASSERT(grid_side > 0 && grid_side <= CARTY_GRID_MAX_N && cap > 0, "doors: bad args");
  DoorList list = {out, 0, cap};
  for (int32_t row = 0; row < grid_side; ++row) {
    for (int32_t col = 0; col < grid_side; ++col) {
      if (labels[(row * grid_side) + col] == kCellWall) {
        continue;
      }
      const RoomPair pair = straddled_rooms(room_ids, grid_side, {col, row});
      if (pair.low < 0) {
        continue;
      }
      merge_or_add(list, {pair.low, pair.high, col + kCellCenter, row + kCellCenter});
    }
  }
  return list.count;
}

extern "C" int32_t carty_vectorize(const CartyWorldGrid *grid, char *out_buf,
                                   int32_t out_buf_size) {
  CARTY_ASSERT(grid != nullptr, "carty_vectorize: NULL grid");
  CARTY_ASSERT(out_buf != nullptr, "carty_vectorize: NULL out_buf");
  CARTY_ASSERT(out_buf_size > 0, "carty_vectorize: non-positive out_buf_size");
  if (grid->anchored == 0) {
    return CARTY_VEC_ENOGRID;
  }
  const int32_t grid_side = grid->n;
  CARTY_ASSERT(grid_side > 0 && grid_side <= CARTY_GRID_MAX_N,
               "carty_vectorize: grid side out of range");
  // heap-sized to the actual grid, see carty_vec_segment_rooms
  const size_t cell_count = static_cast<size_t>(grid_side) * static_cast<size_t>(grid_side);
  std::vector<uint8_t> labels(cell_count);
  std::vector<int32_t> room_ids(cell_count);
  if (!classify_grid(grid, labels)) {
    return CARTY_VEC_ENOGRID;
  }
  const int32_t room_count = carty_vec_segment_rooms(labels.data(), grid_side, room_ids.data());
  CartyVecDoor doors[CARTY_VEC_MAX_DOORS];
  const int32_t door_count = carty_vec_detect_doors(labels.data(), room_ids.data(), grid_side,
                                                    doors, CARTY_VEC_MAX_DOORS);

  GeoWriter out = {out_buf, out_buf_size, 0, 0};
  const CellToWorld frame = {grid->origin_x, grid->origin_y, grid->res_m};
  // "%s": clang's -Wformat-security rejects an arg-less non-literal fmt
  if (!emit(out, "%s", R"({"type":"FeatureCollection","features":[)")) {
    return CARTY_VEC_ENOSPACE;
  }
  for (int32_t room = 0; room < room_count; ++room) {
    if (!emit_room(out, frame, room_ids.data(), grid_side, room)) {
      return CARTY_VEC_ENOSPACE;
    }
  }
  for (int32_t door = 0; door < door_count; ++door) {
    if (!emit_door(out, frame, doors[door], room_count + door)) {
      return CARTY_VEC_ENOSPACE;
    }
  }
  if (!emit(out, "%s", "]}")) {
    return CARTY_VEC_ENOSPACE;
  }
  return out.used + 1;  // include NUL (snprintf already NUL-terminated)
}
