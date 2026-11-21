/*
 * test_vectorize.cpp — unit tests for the Vectorize stage (carty_vectorize.cpp):
 * occupancy volume -> MapGraph GeoJSON via classical CV (test-first).
 * Per-stage property tests + the FFI boundary contract. No LiteRT, no model.
 * Dependency-free CHECK harness + fork death-tests mirror test_world_grid_fusion.cpp.
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_bridge_internal.h"   // concrete CartyWorldGrid layout (paint cells)
#include "carty_vectorize_internal.h"

#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <ratio>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr int8_t kOccupied = 9;        // any positive log-odds reads as occupied
constexpr int8_t kPaintedLogOdds = 100;
constexpr int32_t kBands = 4;          // height bands in the classify and boundary grids
constexpr int32_t kSmallSide = 8;      // a grid big enough to vectorize, never anchored
constexpr size_t kSmallBufBytes = 64;
constexpr int32_t kRoomSide = 6;       // the two-room fixture: ring + divider at col 2
constexpr int32_t kDividerCol = 2;
constexpr int32_t kDoorRow = 3;        // the divider's one-cell gap

// Runs body in a child; passes iff the child died by SIGABRT (crash-at-boundary).
bool aborts(void (*body)()) {
  const auto pid = fork();
  if (pid == 0) {
    body();
    _exit(0);
  }
  int status = 0;
  const bool reaped = waitpid(pid, &status, 0) == pid;
  return reaped && WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

void call_null_grid() {
  char buf[kSmallBufBytes];
  static_cast<void>(carty_vectorize(nullptr, buf, sizeof(buf)));
}
/* a grid of side x side cells, 1 m cells and bands */
CartyWorldGrid *make_unit_grid(int32_t side) {
  const CartyGridShape shape{side, kBands, 1.0, 1.0};
  return carty_world_grid_create(&shape);
}

void call_null_buf() {
  const CartyWorldGrid *grid = make_unit_grid(kSmallSide);
  static_cast<void>(carty_vectorize(grid, nullptr, kSmallBufBytes));
}
void call_zero_buf() {
  const CartyWorldGrid *grid = make_unit_grid(kSmallSide);
  char buf[kSmallBufBytes];
  static_cast<void>(carty_vectorize(grid, buf, 0));
}

void test_classify() {
  int8_t empty[kBands] = {0, 0, 0, 0};
  int8_t floor[kBands] = {kOccupied, 0, 0, 0};                             // low band only
  int8_t wall[kBands] = {kOccupied, kOccupied, kOccupied, kOccupied};      // through the top
  int8_t furniture[kBands] = {0, kOccupied, 0, 0};                         // mid-only island
  CHECK_QUIET(carty_vec_classify_column(empty, kBands) == kCellFree, "empty column -> free");
  CHECK_QUIET(carty_vec_classify_column(floor, kBands) == kCellFloor, "low-only column -> floor");
  CHECK_QUIET(carty_vec_classify_column(wall, kBands) == kCellWall, "through-top column -> wall");
  CHECK_QUIET(carty_vec_classify_column(furniture, kBands) == kCellFurniture,
              "mid island -> furniture");
  int8_t single[1] = {kOccupied};  // 1×1×1 degenerate, still classifies
  CHECK_QUIET(carty_vec_classify_column(single, 1) == kCellWall, "degenerate occupied col -> wall");
}

constexpr size_t cell_index(int32_t col, int32_t row, int32_t grid_side) {
  return (static_cast<size_t>(row) * static_cast<size_t>(grid_side)) + static_cast<size_t>(col);
}

/* outer ring plus a divider at kDividerCol for rows 1..4, open at kDoorRow */
bool two_room_wall(int32_t col, int32_t row) {
  const int32_t last = kRoomSide - 1;
  const bool ring = col == 0 || row == 0 || col == last || row == last;
  const bool divider = col == kDividerCol && row >= 1 && row <= last - 1 && row != kDoorRow;
  return ring || divider;
}

void label_two_rooms(uint8_t *labels) {
  for (int32_t row = 0; row < kRoomSide; ++row) {
    for (int32_t col = 0; col < kRoomSide; ++col) {
      labels[cell_index(col, row, kRoomSide)] = two_room_wall(col, row) ? kCellWall : kCellFloor;
    }
  }
}

void test_segment() {
  // The sealing pre-pass closes the doorway gap, so the two interiors separate:
  // room col 1 | room cols 3,4.
  uint8_t labels[kRoomSide * kRoomSide];
  label_two_rooms(labels);
  int32_t ids[kRoomSide * kRoomSide];
  const int32_t count = carty_vec_segment_rooms(labels, kRoomSide, ids);
  const size_t left_room = cell_index(1, 2, kRoomSide);
  const size_t right_room = cell_index(3, 2, kRoomSide);
  CHECK_QUIET(count == 2, "doorway sealed -> exactly 2 room components");
  CHECK_QUIET(ids[left_room] >= 0 && ids[right_room] >= 0, "interior cells are rooms");
  CHECK_QUIET(ids[left_room] != ids[right_room], "the divider separates the two rooms");
  CHECK_QUIET(ids[cell_index(0, 0, kRoomSide)] == -1, "border wall is not a room");
  CHECK_QUIET(ids[cell_index(kDividerCol, kDoorRow, kRoomSide)] == -1,
              "the sealed doorway cell is not a room");
}

// Scaling guard: a real fused grid has a LARGE border-connected exterior of free
// cells around the scene. carty_vec_segment_rooms must visit each cell O(1) times
// — i.e. flood the exterior ONCE — so it stays O(n*n). A regression that lets the
// exterior be re-flooded per cell is O(n^4): n=160 alone takes tens of seconds.
// This asserts both correctness (exactly the enclosed rooms, exterior is non-room)
// AND a generous wall-clock budget that only an ~O(n*n) implementation can meet.
void test_segment_exterior_scaling() {
  const int32_t grid_side = 160;
  const size_t cell_count = static_cast<size_t>(grid_side) * grid_side;
  std::vector<uint8_t> labels(cell_count, kCellFloor);  // mostly free -> huge exterior
  std::vector<int32_t> ids(cell_count);
  // One small enclosed room near the centre: a 10x10 wall box (interior 8x8).
  const int32_t box_low = 70;
  const int32_t box_high = 80;
  const int32_t box_inside = 75;
  for (int32_t edge = box_low; edge <= box_high; ++edge) {
    labels[cell_index(edge, box_low, grid_side)] = kCellWall;
    labels[cell_index(edge, box_high, grid_side)] = kCellWall;
    labels[cell_index(box_low, edge, grid_side)] = kCellWall;
    labels[cell_index(box_high, edge, grid_side)] = kCellWall;
  }

  const auto started = std::chrono::steady_clock::now();
  const int32_t count = carty_vec_segment_rooms(labels.data(), grid_side, ids.data());
  const double elapsed_ms =
      std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
  const double budget_ms = 250.0;
  CHECK_QUIET(count == 1, "one enclosed box -> exactly one interior room");
  CHECK_QUIET(ids[cell_index(box_inside, box_inside, grid_side)] == 0,
              "the enclosed interior cell is room 0");
  CHECK_QUIET(ids[cell_index(0, 0, grid_side)] == -1,
              "border-connected exterior free space is not a room");
  CHECK_QUIET(elapsed_ms < budget_ms,
              "segment_rooms must be ~O(n*n): n=160 well under 250 ms (not O(n^4))");
}

/* even-odd ray test of a grid-unit point against an x,y-pair ring */
bool point_in_poly(double point_x, double point_y, const double *ring_xy, int32_t vert_count) {
  bool inside = false;
  for (int32_t cur = 0, prev = vert_count - 1; cur < vert_count; prev = cur++) {
    const double cur_x = ring_xy[2 * static_cast<ptrdiff_t>(cur)];
    const double cur_y = ring_xy[(2 * static_cast<ptrdiff_t>(cur)) + 1];
    const double prev_x = ring_xy[2 * static_cast<ptrdiff_t>(prev)];
    const double prev_y = ring_xy[(2 * static_cast<ptrdiff_t>(prev)) + 1];
    if (((cur_y > point_y) != (prev_y > point_y)) &&
        (point_x < ((prev_x - cur_x) * (point_y - cur_y) / (prev_y - cur_y)) + cur_x)) {
      inside = !inside;
    }
  }
  return inside;
}

void test_trace() {
  // A single rectangular room: cells col in [1,2], row in [1,4] are room 0.
  int32_t ids[kRoomSide * kRoomSide];
  for (int32_t &room_id : ids) {
    room_id = -1;
  }
  const int32_t last_row = 4;
  for (int32_t row = 1; row <= last_row; ++row) {
    for (int32_t col = 1; col <= 2; ++col) {
      ids[cell_index(col, row, kRoomSide)] = 0;
    }
  }

  const int32_t ring_cap_verts = 128;
  double ring_xy[2 * ring_cap_verts];
  const int32_t vert_count = carty_vec_trace_boundary(ids, kRoomSide, 0, ring_xy, ring_cap_verts);
  const int32_t rectangle_max_verts = 8;
  CHECK_QUIET(vert_count >= 3, "boundary trace yields >= 3 verts (ScoredRoom precondition)");
  CHECK_QUIET(vert_count <= rectangle_max_verts, "a rectangle simplifies to a small vert count");
  // The room's interior cell centers must be inside the traced polygon.
  const double inside_x = 1.5;
  const double outside_x = 4.5;
  const double centre_y = 2.5;
  CHECK_QUIET(point_in_poly(inside_x, centre_y, ring_xy, vert_count),
              "interior cell center is inside the ring");
  CHECK_QUIET(!point_in_poly(outside_x, centre_y, ring_xy, vert_count),
              "a far cell center is outside the ring");
}

void test_boundary() {
  CHECK_QUIET(aborts(call_null_grid), "NULL grid must abort at the boundary");
  CHECK_QUIET(aborts(call_null_buf), "NULL out_buf must abort at the boundary");
  CHECK_QUIET(aborts(call_zero_buf), "non-positive out_buf_size must abort at the boundary");

  // Unanchored (freshly created, never accreted) grid -> ENOGRID, no write.
  CartyWorldGrid *grid = make_unit_grid(kSmallSide);
  char buf[4 * kSmallBufBytes];
  const int32_t status = carty_vectorize(grid, buf, sizeof(buf));
  CHECK_QUIET(status == CARTY_VEC_ENOGRID, "unanchored grid -> CARTY_VEC_ENOGRID");
  carty_world_grid_free(grid);
}

void test_doors() {
  uint8_t labels[kRoomSide * kRoomSide];
  int32_t ids[kRoomSide * kRoomSide];
  label_two_rooms(labels);
  const int32_t count = carty_vec_segment_rooms(labels, kRoomSide, ids);
  CHECK_QUIET(count == 2, "divider with a sealed doorway segments into 2 rooms");
  const int32_t door_cap = 8;
  CartyVecDoor doors[door_cap];
  const int32_t door_count = carty_vec_detect_doors(labels, ids, kRoomSide, doors, door_cap);
  CHECK_QUIET(door_count == 1, "one opening -> exactly one door");
  CHECK_QUIET(doors[0].room_a != doors[0].room_b, "door joins two distinct rooms");
  // door centre within about a cell of the gap (grid-cell units)
  const double col_low = 1.9;
  const double col_high = 3.1;
  const double row_low = 3.0;
  const double row_high = 4.5;
  CHECK_QUIET(doors[0].x > col_low && doors[0].x < col_high, "door x at the divider column");
  CHECK_QUIET(doors[0].y > row_low && doors[0].y < row_high, "door y at the opening row (cell y=3)");
}

void paint_box_two_room(CartyWorldGrid *grid) {
  // Walls -> all bands occupied; room floor -> band 0 only.
  const int32_t grid_side = grid->n;
  const int32_t band_count = grid->h;
  CARTY_ASSERT(grid_side >= kRoomSide, "paint: grid too small");
  const auto voxel = [&](int32_t band, int32_t row, int32_t col) {
    return (((static_cast<size_t>(band) * grid_side) + row) * grid_side) + col;
  };
  for (int32_t row = 0; row < kRoomSide; ++row) {
    for (int32_t col = 0; col < kRoomSide; ++col) {
      if (two_room_wall(col, row)) {
        for (int32_t band = 0; band < band_count; ++band) {
          grid->cells[voxel(band, row, col)] = kPaintedLogOdds;
        }
      } else {
        grid->cells[voxel(0, row, col)] = kPaintedLogOdds;
      }
    }
  }
  grid->anchored = 1;  // res_m=1 from create
  grid->origin_x = 0.0;
  grid->origin_y = 0.0;
}

void test_integration() {
  CartyWorldGrid *grid = make_unit_grid(kRoomSide);
  paint_box_two_room(grid);
  char buf[CARTY_VEC_OUT_MAX];
  const int32_t written = carty_vectorize(grid, buf, sizeof(buf));
  CHECK_QUIET(written > 0, "vectorize a painted grid -> bytes written");
  const std::string got(buf);
  CHECK_QUIET(got.find("\"Polygon\"") != std::string::npos, "emits room Polygon features");
  CHECK_QUIET(got.find("\"door\"") != std::string::npos, "emits a door feature");
  CHECK_QUIET(got.find("\"connections\":[0,1]") != std::string::npos ||
                  got.find("\"connections\": [0,1]") != std::string::npos,
              "door connects room 0 and 1");

  // Regenerate-and-assert the committed Dart-gate fixture. First run writes it;
  // CI runs assert byte-identical (catches silent algorithm drift).
#ifdef CARTY_REPO_ROOT
  const std::string fixture_path =
      std::string(CARTY_REPO_ROOT) + "/test/fixtures/benchmark/box_two_room/vectorized.geojson";
  const char *path = fixture_path.c_str();
#else
  const char *path = "../../test/fixtures/benchmark/box_two_room/vectorized.geojson";
#endif
  const std::ifstream committed(path);
  if (committed.good()) {
    std::stringstream contents;
    contents << committed.rdbuf();
    CHECK_QUIET(contents.str() == got,
                "vectorized.geojson matches committed fixture (regen if intended)");
  } else {
    std::ofstream out(path);
    out << got;
    CARTY_ASSERT(out.good(),
                 "fixture write failed — ensure test/fixtures/benchmark/box_two_room/ exists");
    carty_sayf(stdout, "WROTE fixture %s (commit it; re-run asserts byte-identical)\n", path);
  }
  carty_world_grid_free(grid);
}

}  // namespace

int main() {
  // string, stream and vector allocation can throw; a throw is a failed run, not a crash
  try {
    test_classify();
    test_segment();
    test_segment_exterior_scaling();
    test_trace();
    test_doors();
    test_boundary();
    test_integration();
  } catch (...) {
    carty_sayf(stderr, "%s\n", "FAIL: a vectorize test threw");
    return 1;
  }
  return carty_finish("ALL VECTORIZE TESTS PASSED");
}
