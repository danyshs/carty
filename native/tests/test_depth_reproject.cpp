/*
 * test_depth_reproject.cpp — unit tests for carty_world_grid_accrete_from_depth
 * (Fusion stage, depth reprojection). Dependency-free
 * CHECK-macro harness, mirroring test_world_grid_fusion.cpp.
 *
 * Conventions under test (must match carty_fusion.cpp exactly):
 *   - pose is 4x4 ROW-MAJOR cam->world; translation in the 4th column.
 *   - CV->OpenGL handedness: Xc=(u-cx)Z/fx, Yc=-(v-cy)Z/fy, Zc=-Z.
 *   - origin_x=cam_x-(n/2)res, origin_y=cam_z-(n/2)res, origin_z=cam_y-(h/2)band.
 *   - gx=floor((Xw-origin_x)/res), gy=floor((Zw-origin_y)/res),
 *     band=floor((Yw-origin_z)/band); idx=(band*n+gy)*n+gx.
 *   - depth value 0 = hole (skipped).
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_depth_fixture.h"

#include <sys/wait.h>
#include <unistd.h>

#include <cstddef>
#include <cstdint>

namespace {

using namespace depth_fixture;

/* a grid with the hit pixel folded once at kHitRangeMm (flat weight) under pose */
CartyWorldGrid *fold_hit(const CartyPose &pose, int32_t *status) {
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, kHitRangeMm, 0});
  *status = fold(grid, image.range_mm, nullptr, pose, 1);
  return grid;
}

// Test 1: primary asymmetric fixture — one pixel lands in the hand-computed cell.
void test_primary_reprojection() {
  int32_t status = -1;
  CartyWorldGrid *grid = fold_hit(kIdentityPose, &status);
  CHECK(status == CARTY_FUSE_OK, "primary: status OK");
  CHECK(carty_world_grid_cells(grid)[kHitVoxel] == kLogOddsOcc,
        "primary: hit folded at idx 323 with L_OCC=20");
  CHECK(count_nonzero(grid) == 1, "primary: exactly one cell folded");
  carty_world_grid_free(grid);
}

// Test 2: holes skipped — all-zero depth folds nothing -> OUT_OF_BOUNDS.
void test_holes_skipped() {
  CartyWorldGrid *grid = make_grid();
  const DepthImage holes{};
  const int32_t status = fold(grid, holes.range_mm, nullptr, kIdentityPose, 1);
  CHECK(status == CARTY_FUSE_OUT_OF_BOUNDS, "holes: all-zero -> OUT_OF_BOUNDS");
  CHECK(count_nonzero(grid) == 0, "holes: grid untouched");
  carty_world_grid_free(grid);
}

// Test 3: real height-banding — same (gx,gy), different Z -> different band.
// u=1 fixed; v=1,Z=2.0 -> Yw=+0.5 -> band 5; v=2,Z=2.0 -> Yw=-0.5 -> band 3.
// Both: Xw=-0.5 -> gx=3, Zw=-2.0 -> gy=0.
void test_height_banding() {
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, kHitRangeMm, 0});
  image.range_mm[pixel_index({1, 2})] = kHitRangeMm;
  static_cast<void>(fold(grid, image.range_mm, nullptr, kIdentityPose, 1));
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t lower_voxel = voxel_index({3, 0, 3});
  CHECK(cells[kHitVoxel] == kLogOddsOcc && cells[lower_voxel] == kLogOddsOcc,
        "banding: two pixels land in different bands (real height)");
  CHECK(count_nonzero(grid) == 2, "banding: exactly two cells");
  carty_world_grid_free(grid);
}

// Test 4: rotation — 90deg yaw R=[[0,0,1],[0,1,0],[-1,0,0]] applied to (-0.5,0.5,-2.0)
// gives world (-2.0, 0.5, 0.5). Anchor unchanged (cam at origin). Expect
// gx=floor((-2.0+2.0)/.5)=0, gy=floor((0.5+2.0)/.5)=5, band=floor((0.5+2.0)/.5)=5.
void test_rotation_applies_R() {
  const CartyPose yaw_quarter_pose{{
      0, 0, 1, 0,  0, 1, 0, 0,  -1, 0, 0, 0,  0, 0, 0, 1,
  },};
  int32_t status = -1;
  CartyWorldGrid *grid = fold_hit(yaw_quarter_pose, &status);
  CHECK(status == CARTY_FUSE_OK, "rotation: status OK");
  const size_t rotated_voxel = voxel_index({5, 5, 0});
  CHECK(carty_world_grid_cells(grid)[rotated_voxel] == kLogOddsOcc,
        "rotation: R correctly applied to world point");
  CHECK(count_nonzero(grid) == 1, "rotation: exactly one cell");
  carty_world_grid_free(grid);
}

// Test 5: idempotency + monotonicity (shared contract).
void test_dedup_and_monotonic() {
  const int64_t first_id = 7;
  const int64_t second_id = 8;
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, kHitRangeMm, 0});
  static_cast<void>(fold(grid, image.range_mm, nullptr, kIdentityPose, first_id));
  const int32_t dup_status = fold(grid, image.range_mm, nullptr, kIdentityPose, first_id);
  CHECK(dup_status == CARTY_FUSE_DUPLICATE, "dedup: re-feed same id is a no-op");
  const int8_t *cells = carty_world_grid_cells(grid);
  CHECK(cells[kHitVoxel] == kLogOddsOcc, "dedup: cell unchanged after duplicate");
  static_cast<void>(fold(grid, image.range_mm, nullptr, kIdentityPose, second_id));
  CHECK(cells[kHitVoxel] == 2 * kLogOddsOcc, "monotonic: distinct id accumulates (20 -> 40)");
  carty_world_grid_free(grid);
}

// Test 6: out-of-volume clip — a far-Z pixel lands off the grid, no crash, no write.
void test_out_of_volume_clip() {
  const uint16_t far_range_mm = 60000;  // far outside the 4 m grid extent
  CartyWorldGrid *grid = make_grid();
  DepthImage image{};
  set_single_pixel(&image, {kHitPixel, far_range_mm, 0});
  const int32_t status = fold(grid, image.range_mm, nullptr, kIdentityPose, 1);
  CHECK(status == CARTY_FUSE_OUT_OF_BOUNDS, "clip: far hit -> OUT_OF_BOUNDS");
  CHECK(count_nonzero(grid) == 0, "clip: grid untouched (clip, not clamp)");
  carty_world_grid_free(grid);
}

// Test 7: boundary death — a NULL depth pointer must abort (crash-at-boundary).
void test_null_depth_aborts() {
  const auto pid = fork();
  if (pid == 0) {
    CartyWorldGrid *grid = make_grid();
    static_cast<void>(fold(grid, nullptr, nullptr, kIdentityPose, 1));
    _exit(0);  // should never reach here
  }
  int status = 0;
  const bool reaped = waitpid(pid, &status, 0) == pid;
  CHECK(reaped && (!WIFEXITED(status) || WEXITSTATUS(status) != 0),
        "boundary: NULL depth aborts the process");
}

}  // namespace

int main() {
  test_primary_reprojection();
  test_holes_skipped();
  test_height_banding();
  test_rotation_applies_R();
  test_dedup_and_monotonic();
  test_out_of_volume_clip();
  test_null_depth_aborts();
  return carty_finish("ALL PASS");
}
