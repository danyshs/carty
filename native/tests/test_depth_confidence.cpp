/*
 * test_depth_confidence.cpp — unit tests for the confidence weighting confidence-weighted fold in
 * carty_world_grid_accrete_from_depth. Dependency-free
 * CHECK-macro harness, mirroring test_depth_reproject.cpp.
 *
 * Under test:
 *   - conf == NULL  -> flat CARTY_FUSE_L_OCC (=20), exact parity with the no-confidence fold.
 *   - conf[p] < CARTY_FUSE_CONF_MIN (128) -> ray dropped (no fold).
 *   - else inc = lround(20*(0.35 + 0.65*w)), w=(c-128)/127 clamped, inc>=1;
 *     monotonic non-decreasing in c (lround plateaus between adjacent c).
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_depth_fixture.h"

#include <cstddef>
#include <cstdint>
#include <initializer_list>

namespace {

using namespace depth_fixture;

constexpr uint8_t kConfMid = 150;
// 150 -> w=(150-128)/127=0.173, inc=lround(20*(0.35+0.65*0.173))=9
constexpr int8_t kConfMidIncrement = 9;

// Fold the hit pixel at the given confidence (null: flat) into a fresh grid; return its cell.
int8_t fold_one(const uint8_t *confidence) {
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, kHitRangeMm, 0});
  const uint8_t *conf = nullptr;
  if (confidence != nullptr) {
    image.conf[pixel_index(kHitPixel)] = *confidence;
    conf = image.conf;
  }
  // the status is pinned by the other suites; here only the cell value matters
  static_cast<void>(fold(grid, image.range_mm, conf, kIdentityPose, 1));
  const int8_t value = carty_world_grid_cells(grid)[kHitVoxel];
  carty_world_grid_free(grid);
  return value;
}

// Test 1: NULL conf reproduces the plain reprojection's flat L_OCC = 20 exactly.
void test_null_conf_parity() {
  CHECK(fold_one(nullptr) == kLogOddsOcc, "null conf: flat L_OCC=20 (parity with the no-confidence fold)");
}

// Test 2: full-confidence (255) folds the full L_OCC = 20.
void test_full_conf_full_fold() {
  const uint8_t full = UINT8_MAX;
  CHECK(fold_one(&full) == kLogOddsOcc, "conf=255: folds full L_OCC=20");
}

// Test 3: monotonic — higher confidence folds strictly more (both >= threshold).
void test_monotonic() {
  const uint8_t full = UINT8_MAX;
  const uint8_t mid = kConfMid;
  CHECK(fold_one(&full) > fold_one(&mid), "conf 255 folds strictly > conf 150");
  CHECK(fold_one(&mid) == kConfMidIncrement, "conf=150 folds inc=9 (spec arithmetic)");
}

// Test 4: hard threshold — conf below CARTY_FUSE_CONF_MIN (128) folds nothing.
void test_hard_threshold() {
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, kHitRangeMm, kConfBelowMin});
  CartyWorldGrid *grid = make_grid();
  const int32_t status = fold(grid, image.range_mm, image.conf, kIdentityPose, 1);
  CHECK(status == CARTY_FUSE_OUT_OF_BOUNDS, "sub-threshold sole hit -> OUT_OF_BOUNDS");
  CHECK(carty_world_grid_cells(grid)[kHitVoxel] == 0, "sub-threshold: cell untouched");
  carty_world_grid_free(grid);
}

// Test 5: flying-pixel smear measurement. A high-conf hit accrues
// across keyframes and crosses an occupancy threshold; a low-conf "flying" hit at the
// same cell-class never folds, so it stays at 0 (below any positive threshold).
void test_flying_pixel_suppressed() {
  const PixelPos fly_pixel{1, 2};
  const size_t fly_voxel = voxel_index({3, 0, 3});  // fly_pixel at 2 m
  DepthImage real{};
  DepthImage fly{};
  set_single_pixel(&real, {kHitPixel, kHitRangeMm, UINT8_MAX});
  set_single_pixel(&fly, {fly_pixel, kHitRangeMm, kConfBelowMin});
  CartyWorldGrid *grid = make_grid();
  // Fold the trustworthy hit twice and the flying pixel twice (distinct keyframes).
  int64_t keyframe_id = 1;
  for (const DepthImage *image : {&real, &real, &fly, &fly}) {
    static_cast<void>(fold(grid, image->range_mm, image->conf, kIdentityPose, keyframe_id));
    ++keyframe_id;
  }
  const int8_t *cells = carty_world_grid_cells(grid);
  CHECK(cells[kHitVoxel] >= 2 * kLogOddsOcc,
        "flying-pixel: trustworthy cell crosses threshold (>=40)");
  CHECK(cells[fly_voxel] == 0, "flying-pixel: low-conf hit suppressed (stays 0)");
  carty_world_grid_free(grid);
}

}  // namespace

int main() {
  test_null_conf_parity();
  test_full_conf_full_fold();
  test_monotonic();
  test_hard_threshold();
  test_flying_pixel_suppressed();
  return carty_finish("all confidence tests passed");
}
