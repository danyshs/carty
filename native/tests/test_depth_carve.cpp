/*
 * test_depth_carve.cpp — unit tests for occlusion carving occlusion carving in
 * carty_world_grid_accrete_from_depth. Dependency-free
 * CHECK-macro harness, mirroring test_depth_confidence.cpp.
 *
 * Under test: a trusted depth
 * ray lowers log-odds on the in-grid voxels it passes through (sensor->hit), the hit
 * voxel itself is excluded, sub-threshold and NULL-conf rays carve nothing.
 *
 * Geometry: the fixture's hit pixel, identity pose and 8x8x8 grid. A near sample
 * (1 m) and a far sample (2 m) are COLLINEAR, so the far ray's free path crosses the
 * near hit's voxel. The far hit voxel is the fixture's kHitVoxel.
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_depth_fixture.h"

#include <cstddef>
#include <cstdint>

namespace {

using namespace depth_fixture;

constexpr size_t kNotFound = SIZE_MAX;

// Index of the single positive cell after folding the NEAR sample alone (full conf).
// This is the near hit voxel = the cell the far ray must carve.
size_t near_voxel_index() {
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, kNearRangeMm, UINT8_MAX});
  static_cast<void>(fold(grid, image.range_mm, image.conf, kIdentityPose, 1));
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t cell_count = carty_world_grid_size(grid);
  size_t found = kNotFound;
  for (size_t i = 0; i < cell_count; ++i) {
    if (cells[i] > 0) {
      found = i;
      break;
    }
  }
  carty_world_grid_free(grid);
  return found;
}

/* fold the near sample, then the far one, both with the given confidence (null: flat) */
CartyWorldGrid *fold_near_then_far(const uint8_t *far_confidence) {
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  const bool flat = far_confidence == nullptr;
  set_single_pixel(&image, {kHitPixel, kNearRangeMm, UINT8_MAX});
  static_cast<void>(fold(grid, image.range_mm, flat ? nullptr : image.conf, kIdentityPose, 1));
  set_single_pixel(&image, {kHitPixel, kHitRangeMm, flat ? uint8_t{0} : *far_confidence});
  static_cast<void>(fold(grid, image.range_mm, flat ? nullptr : image.conf, kIdentityPose, 2));
  return grid;
}

// Test 1: a trusted far ray carves the near voxel it passes through (erosion).
void test_carve_erodes_passthrough() {
  const size_t near = near_voxel_index();
  CHECK(near != kNotFound && near != kHitVoxel, "near voxel found and distinct from far");
  const uint8_t full = UINT8_MAX;
  CartyWorldGrid *grid = fold_near_then_far(&full);
  CHECK(carty_world_grid_cells(grid)[near] <= 0, "passed-through near voxel carved back to <= 0");
  carty_world_grid_free(grid);
}

// Test 2: the far ray's own hit voxel SURVIVES (excluded from carving, gets +20).
void test_hit_voxel_survives() {
  const uint8_t full = UINT8_MAX;
  CartyWorldGrid *grid = fold_near_then_far(&full);
  CHECK(carty_world_grid_cells(grid)[kHitVoxel] == kLogOddsOcc,
        "far hit voxel stays +20 (excluded from carve)");
  carty_world_grid_free(grid);
}

// Test 3: a sub-threshold far ray carves NOTHING (no free corridor on distrust).
void test_subthreshold_no_carve() {
  const size_t near = near_voxel_index();
  const uint8_t low = kConfBelowMin;
  CartyWorldGrid *grid = fold_near_then_far(&low);
  CHECK(carty_world_grid_cells(grid)[near] == kLogOddsOcc,
        "sub-threshold far ray leaves near voxel untouched (+20)");
  carty_world_grid_free(grid);
}

// Test 4: NULL conf carves nothing (parity with the no-confidence fold, carve needs a trust signal).
void test_null_conf_no_carve() {
  const size_t near = near_voxel_index();
  CartyWorldGrid *grid = fold_near_then_far(nullptr);
  const int8_t *cells = carty_world_grid_cells(grid);
  CHECK(cells[near] == kLogOddsOcc, "NULL conf: near voxel stays +20 (no carve, parity with the no-confidence fold)");
  CHECK(cells[kHitVoxel] == kLogOddsOcc, "NULL conf: far hit folds flat +20");
  carty_world_grid_free(grid);
}

}  // namespace

int main() {
  test_carve_erodes_passthrough();
  test_hit_voxel_survives();
  test_subthreshold_no_carve();
  test_null_conf_no_carve();
  return carty_finish("all depth-carve checks passed");
}
