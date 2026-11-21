/*
 * test_world_grid_fusion.cpp — unit tests for the Fusion stage: the persistent
 * world-frame voxel-column grid (CartyWorldGrid) and carty_world_grid_accrete
 * (test-first). This is the host done-signal for
 * backlog item #2: "multi-frame accretion stays within N×N×H and is idempotent
 * under a repeated keyframe."
 *
 * No external framework; the tiny CHECK macro + dependency-free harness mirror
 * test_ortho_project.cpp. The properties pinned here:
 *   1. create / bounds        2. idempotency (the done-signal)
 *   3. monotonic in evidence  4. bounded under repetition
 *   5. out-of-bounds safety   6. anchor
 *   7. yaw placement (#1 correctness risk — naive yaw extraction), incl. (d) the
 *      degenerate straight-down fallback branch
 *   8. memory (LSan)          9. boundary death (NULL handles abort)
 *  10. segment full (SEEN_MAX) degrades to a SEEN_FULL status, not a crash
 *
 * Coordinate conventions under test (must match carty_fusion.cpp exactly):
 *   - pose is 4x4 ROW-MAJOR cam->world (ARCore Y-up world): translation in the
 *     4th column — cam_x=pose[3], cam_y=pose[7], cam_z=pose[11].
 *   - camera forward = -(3rd column) = (-pose[2], -pose[6], -pose[10]); the grid
 *     yaw is its heading on the world horizontal X-Z plane: theta=atan2(fx,fz)
 *     with fx=-pose[2], fz=-pose[10]. (Projecting a basis axis onto the ground
 *     and taking its heading is the method pinned as load-bearing — a
 *     naive atan2 on the wrong elements is unstable under the ~60° down pitch.)
 *   - local ortho (lx,ly: +x right, +y forward) -> world horizontal:
 *       Xw = lx*cos(theta) + ly*sin(theta)        (theta=0 => +y forward -> +Z)
 *       Zw = -lx*sin(theta) + ly*cos(theta)       (theta=90° => +y forward -> +X)
 *   - ground cell gx=floor((Xw-origin_x)/res), gy=floor((Zw-origin_y)/res);
 *     observations fold into a single fixed band at the camera-height level h/2
 *     (NOT the geometric floor; depth is a separate path).
 *   - cell index is band-major: idx = (band*n + gy)*n + gx.
 */
#include "carty_bridge.h"
#include "carty_check.h"
#include "carty_frame_fixture.h"

#include <sys/wait.h>
#include <unistd.h>

#include <array>
#include <cmath>
#include <csignal>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace {

using frame_fixture::FrameDims;
using frame_fixture::Rgb;

// ---- fixture constants
constexpr int32_t kGridSide = 128;
constexpr int32_t kBands = 8;
constexpr double kCellM = 0.05;
constexpr double kBandM = 0.25;
constexpr int32_t kCentreCell = kGridSide / 2;  // the first camera's ground cell
constexpr int32_t kCentreBand = kBands / 2;     // the band stack centres on the camera
constexpr double kPitchRad = 1.0471975511965976;  // 60 deg, matches the ortho extrinsic
constexpr double kCamHeightM = 1.6;
constexpr int kLogOddsMax = 127;     // int8 log-odds clamp ceiling (L_MAX)
constexpr double kFarAwayM = 1000.0;  // a camera this far off sees nothing on the grid
constexpr double kOriginTolM = 1e-9;
constexpr double kMinShiftCells = 2.0;  // a footprint "lies forward": past this many cells
constexpr double kMaxDriftCells = 3.0;  // ... while drifting sideways by less than this
constexpr double kCentredTolCells = 4.0;

constexpr FrameDims kSceneDims{640, 480, 4};
constexpr FrameDims kSmallDims{64, 64, 4};  // cheap folds where only the count matters
constexpr Rgb kGray{200, 200, 200};
// pinhole for a 64x64 frame
constexpr CartyIntrinsics kFrameIntrinsics{500.0, 500.0, 32.0, 32.0};

// ---- poses
struct WorldPos {
  double x_m, y_m, z_m;
};
constexpr WorldPos kFirstCam{0.0, kCamHeightM, 0.0};

struct CamPlacement {
  double yaw_rad;
  double pitch_rad;
  WorldPos pos;
};

struct Vec3 {
  double x, y, z;
};
Vec3 cross(const Vec3 &lhs, const Vec3 &rhs) {
  return {(lhs.y * rhs.z) - (lhs.z * rhs.y), (lhs.z * rhs.x) - (lhs.x * rhs.z),
          (lhs.x * rhs.y) - (lhs.y * rhs.x),};
}
Vec3 normalized(const Vec3 &vec) {
  const double length = std::sqrt((vec.x * vec.x) + (vec.y * vec.y) + (vec.z * vec.z));
  return {vec.x / length, vec.y / length, vec.z / length};
}

using Pose = CartyPose;
constexpr size_t kPoseTxIdx = 3;  // translation is the 4th column of the row-major pose
constexpr size_t kPoseTyIdx = 7;
struct Basis {
  Vec3 right, up, back;
};
/* row-major cam->world: the basis vectors are columns, translation the 4th column */
Pose pose_from_basis(const Basis &basis, const WorldPos &pos) {
  const Vec3 &right = basis.right;
  const Vec3 &cam_up = basis.up;
  const Vec3 &back = basis.back;
  return Pose{{right.x, cam_up.x, back.x, pos.x_m,  right.y, cam_up.y, back.y, pos.y_m,
               right.z, cam_up.z, back.z, pos.z_m,  0.0, 0.0, 0.0, 1.0,},};
}

/* Build a 4x4 ROW-MAJOR cam->world pose for a camera at pos with the given
 * yaw (heading about world-up Y) and pitch (downward tilt). The camera forward in
 * world is f = (sin(yaw)cos(pitch), -sin(pitch), cos(yaw)cos(pitch)) — so the impl
 * reads -(3rd column) == f and recovers theta=atan2(f.x,f.z)=yaw regardless of
 * pitch. The remaining basis is a lookAt completion (it does not affect placement;
 * accrete uses only the heading + translation). */
Pose build_pose(const CamPlacement &cam) {
  const Vec3 forward{std::sin(cam.yaw_rad) * std::cos(cam.pitch_rad), -std::sin(cam.pitch_rad),
                     std::cos(cam.yaw_rad) * std::cos(cam.pitch_rad),};
  const Vec3 back{-forward.x, -forward.y, -forward.z};
  const Vec3 world_up{0.0, 1.0, 0.0};
  const Vec3 right = normalized(cross(world_up, back));
  const Vec3 cam_up = cross(back, right);
  return pose_from_basis({right, cam_up, back}, cam.pos);
}

/* the usual camera: heading +Z, pitched 60 deg down, at pos */
Pose pitched_pose(const WorldPos &pos) { return build_pose({0.0, kPitchRad, pos}); }

/* A cam->world pose looking STRAIGHT DOWN (camera forward = world -Y), with a
 * valid orthonormal basis. Camera forward is vertical, so its horizontal
 * projection is zero — this is the degenerate case pose_yaw must survive by
 * falling back to the right axis. build_pose cannot express this
 * (its lookAt completion divides by a zero cross product), so it is hand-built:
 * back=(0,1,0), right=(1,0,0), up=(0,0,-1), a proper rotation (det=+1). */
Pose build_topdown_pose(const WorldPos &pos) {
  return pose_from_basis({{1.0, 0.0, 0.0}, {0.0, 0.0, -1.0}, {0.0, 1.0, 0.0}}, pos);
}

// ---- grids and observations
CartyWorldGrid *make_grid() {
  const CartyGridShape shape{kGridSide, kBands, kCellM, kBandM};
  return carty_world_grid_create(&shape);
}

/* an ortho observation of the painted scene; caller frees the map */
CartyOrthoMap *make_observation(FrameDims dims) {
  CartyFrame *frame = frame_fixture::make_scene_frame(dims);
  CartyOrthoMap *map =
      carty_ortho_project(frame, dims.width_px, dims.height_px, dims.channels);
  carty_frame_free(frame);
  return map;
}

int32_t fold_obs(CartyWorldGrid *grid, const CartyOrthoMap *obs, const Pose &pose,
                 int64_t keyframe_id) {
  return carty_world_grid_accrete(grid, obs, &pose, keyframe_id);
}

/* one camera frame as accrete_from_frame takes it */
struct FrameShot {
  const CartyFrame *frame;
  FrameDims dims;
  const CartyIntrinsics *intrinsics;
};
int32_t fold_frame(CartyWorldGrid *grid, const FrameShot &shot, const Pose &pose,
                   int64_t keyframe_id) {
  return carty_world_grid_accrete_from_frame(grid, shot.frame, shot.dims.width_px,
                                             shot.dims.height_px, shot.dims.channels,
                                             shot.intrinsics, &pose, keyframe_id);
}

using Snapshot = std::vector<int8_t>;
Snapshot snapshot(const CartyWorldGrid *grid) {
  const int8_t *cells = carty_world_grid_cells(grid);
  return {cells, cells + carty_world_grid_size(grid)};
}
bool unchanged_since(const CartyWorldGrid *grid, const Snapshot &snap) {
  return snap.size() == carty_world_grid_size(grid) &&
         std::memcmp(snap.data(), carty_world_grid_cells(grid), snap.size()) == 0;
}
bool same_cells(const CartyWorldGrid *lhs, const CartyWorldGrid *rhs) {
  return carty_world_grid_size(lhs) == carty_world_grid_size(rhs) &&
         std::memcmp(carty_world_grid_cells(lhs), carty_world_grid_cells(rhs),
                     carty_world_grid_size(lhs)) == 0;
}

/* Count observed (non-zero log-odds) cells in a world grid. */
size_t observed_cells(const CartyWorldGrid *grid) {
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t cell_count = carty_world_grid_size(grid);
  size_t observed = 0;
  for (size_t i = 0; i < cell_count; ++i) {
    if (cells[i] != 0) {
      ++observed;
    }
  }
  return observed;
}

/* Centroid (in cell coords) of the observed cells, and how many there were. */
struct Centroid {
  double col, row;
  size_t count;
};
Centroid observed_centroid(const CartyWorldGrid *grid) {
  const auto grid_side = static_cast<size_t>(carty_world_grid_n(grid));
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t cell_count = carty_world_grid_size(grid);
  double col_sum = 0;
  double row_sum = 0;
  Centroid centroid{0.0, 0.0, 0};
  for (size_t i = 0; i < cell_count; ++i) {
    if (cells[i] == 0) {
      continue;
    }
    col_sum += static_cast<double>(i % grid_side);
    row_sum += static_cast<double>((i / grid_side) % grid_side);
    ++centroid.count;
  }
  if (centroid.count != 0) {
    centroid.col = col_sum / static_cast<double>(centroid.count);
    centroid.row = row_sum / static_cast<double>(centroid.count);
  }
  return centroid;
}

struct GridOrigin {
  double x_m, y_m, z_m;
  int anchored;
};
GridOrigin origin_of(const CartyWorldGrid *grid) {
  GridOrigin origin{0.0, 0.0, 0.0, -1};
  carty_world_grid_origin(grid, &origin.x_m, &origin.y_m, &origin.z_m, &origin.anchored);
  return origin;
}

// ---- death tests
/* Run body in a forked child; return true iff the child terminated via SIGABRT
 * (the crash-at-boundary contract, Tiger Style). */
bool aborts(void (*body)()) {
  if (std::fflush(nullptr) != 0) {
    return false;  // unflushed output would print twice, once from each process
  }
  const auto pid = fork();
  if (pid == 0) {
    body();    /* should abort */
    _exit(0);  /* reached only if it did NOT abort */
  }
  int status = 0;
  const bool reaped = waitpid(pid, &status, 0) == pid;
  return reaped && WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

/* Built in the parent before forking: OpenCV's thread pool doesn't survive fork on
 * macOS, so a child that runs the warp dies the wrong way (or hangs) before it ever
 * reaches the boundary assert under test. */
CartyOrthoMap *g_death_observation = nullptr;

void death_null_grid() {
  static_cast<void>(fold_obs(nullptr, g_death_observation, pitched_pose(kFirstCam), 1));
}
void death_null_obs() {
  static_cast<void>(fold_obs(make_grid(), nullptr, pitched_pose(kFirstCam), 1));
}
void death_null_pose() {
  static_cast<void>(carty_world_grid_accrete(make_grid(), g_death_observation, nullptr, 1));
}
void death_nonfinite_pose() {
  Pose pose = pitched_pose(kFirstCam);
  pose.cam_to_world[kPoseTxIdx] = NAN;
  static_cast<void>(fold_obs(make_grid(), g_death_observation, pose, 1));
}

/* ---- raw-frame splat (carty_world_grid_accrete_from_frame) death bodies ---- */
FrameShot small_gray_shot(FrameDims claimed, const CartyIntrinsics *intrinsics) {
  return {frame_fixture::make_filled_frame(kSmallDims, kGray), claimed, intrinsics};
}

void death_frame_null_grid() {
  static_cast<void>(fold_frame(nullptr, small_gray_shot(kSmallDims, &kFrameIntrinsics),
                               pitched_pose(kFirstCam), 1));
}
void death_frame_null_frame() {
  const FrameShot shot{nullptr, kSmallDims, &kFrameIntrinsics};
  static_cast<void>(fold_frame(make_grid(), shot, pitched_pose(kFirstCam), 1));
}
void death_frame_null_pose() {
  const FrameShot shot = small_gray_shot(kSmallDims, &kFrameIntrinsics);
  static_cast<void>(carty_world_grid_accrete_from_frame(
      make_grid(), shot.frame, kSmallDims.width_px, kSmallDims.height_px, kSmallDims.channels,
      &kFrameIntrinsics, nullptr, 1));
}
void death_frame_null_k() {
  static_cast<void>(fold_frame(make_grid(), small_gray_shot(kSmallDims, nullptr),
                               pitched_pose(kFirstCam), 1));
}
void death_frame_nonfinite_pose() {
  Pose pose = pitched_pose(kFirstCam);
  pose.cam_to_world[kPoseTyIdx] = INFINITY;
  static_cast<void>(fold_frame(make_grid(), small_gray_shot(kSmallDims, &kFrameIntrinsics), pose, 1));
}
void death_frame_nonfinite_k() {
  const CartyIntrinsics bad_intrinsics{500.0, NAN, 32.0, 32.0};
  static_cast<void>(fold_frame(make_grid(), small_gray_shot(kSmallDims, &bad_intrinsics),
                               pitched_pose(kFirstCam), 1));
}
void death_frame_size_mismatch() {
  /* claim 32x32 against a 64x64x4 buffer: width*height*channels != frame size */
  const FrameDims claimed{kSmallDims.width_px / 2, kSmallDims.height_px / 2, kSmallDims.channels};
  static_cast<void>(fold_frame(make_grid(), small_gray_shot(claimed, &kFrameIntrinsics),
                               pitched_pose(kFirstCam), 1));
}

// ---- 1. create / bounds
void test_create(const CartyWorldGrid *grid) {
  CHECK(grid != nullptr, "carty_world_grid_create returns non-null grid");
  CHECK(carty_world_grid_n(grid) == kGridSide && carty_world_grid_h(grid) == kBands,
        "grid reports the requested N and H");
  CHECK(carty_world_grid_size(grid) ==
            static_cast<size_t>(kGridSide) * static_cast<size_t>(kGridSide) *
                static_cast<size_t>(kBands),
        "grid size == n*n*h bytes");
  CHECK(observed_cells(grid) == 0, "fresh grid is all-unobserved (every cell 0)");
  double cell_m = 0;
  double band_m = 0;
  carty_world_grid_resolution(grid, &cell_m, &band_m);
  CHECK(cell_m == kCellM && band_m == kBandM, "carty_world_grid_resolution echoes res/band");
  CHECK(origin_of(grid).anchored == 0, "grid is UNANCHORED before the first accrete");
}

/* The ortho extent accessor (enabling change for accretion). */
void test_ortho_extent(const CartyOrthoMap *obs) {
  double min_x_m = 0;
  double max_x_m = 0;
  double min_y_m = 0;
  double max_y_m = 0;
  carty_ortho_map_extent(obs, &min_x_m, &max_x_m, &min_y_m, &max_y_m);
  CHECK(max_x_m > min_x_m && max_y_m > min_y_m,
        "carty_ortho_map_extent reports a non-degenerate metric footprint");
}

// ---- 6. anchor (done before folding more, to read the fresh origin)
void test_anchor(CartyWorldGrid *grid, const CartyOrthoMap *obs, const Pose &first_pose) {
  CHECK(fold_obs(grid, obs, first_pose, 1) == CARTY_FUSE_OK,
        "first accrete folds the observation (OK)");
  const GridOrigin origin = origin_of(grid);
  CHECK(origin.anchored == 1, "grid is ANCHORED after the first accrete");
  const double expected_ground_m = 0.0 - (kCentreCell * kCellM);
  CHECK(std::fabs(origin.x_m - expected_ground_m) < kOriginTolM &&
            std::fabs(origin.y_m - expected_ground_m) < kOriginTolM,
        "origin centers the grid's ground plane on the first camera");
  CHECK(std::fabs(origin.z_m - (kCamHeightM - (kCentreBand * kBandM))) < kOriginTolM,
        "origin centers the height band stack on the first camera");
  const Centroid centroid = observed_centroid(grid);
  CHECK(centroid.count > 0, "anchored accrete observes ground cells");
  /* camera sits at cell N/2; the floor footprint is forward (+gy) and centered
   * left-right (+/-gx ~ camera column). */
  CHECK(std::fabs(centroid.col - kCentreCell) < kCentredTolCells,
        "yaw=0 footprint centroid is left-right centered on the camera column");
  CHECK(centroid.row > kCentreCell + kMinShiftCells,
        "yaw=0 footprint centroid lies forward of the camera (+gy)");
}

// ---- 2. idempotency — THE DONE-SIGNAL, then 3. monotonic in evidence
void test_idempotent_and_monotone(CartyWorldGrid *grid, const CartyOrthoMap *obs,
                                  const Pose &first_pose) {
  const Snapshot snap = snapshot(grid);
  CHECK(fold_obs(grid, obs, first_pose, 1) == CARTY_FUSE_DUPLICATE,
        "re-accreting the same keyframe id returns DUPLICATE");
  CHECK(unchanged_since(grid, snap),
        "duplicate keyframe leaves the grid BYTE-IDENTICAL (idempotent)");

  /* A DISTINCT id over the same cells must only raise log-odds, never lower, and
   * stay <= L_MAX. */
  CHECK(fold_obs(grid, obs, first_pose, 2) == CARTY_FUSE_OK, "distinct keyframe folds again (OK)");
  const int8_t *now = carty_world_grid_cells(grid);
  bool monotone = true;
  bool bounded = true;
  for (size_t i = 0; i < snap.size(); ++i) {
    monotone = monotone && now[i] >= snap[i];
    bounded = bounded && now[i] <= kLogOddsMax;
  }
  CHECK(monotone, "a distinct keyframe never lowers any cell's evidence");
  CHECK(bounded, "evidence stays <= L_MAX after a second view");
}

// ---- 4. bounded under repetition
void test_bounded_repetition(CartyWorldGrid *grid, const CartyOrthoMap *obs,
                             const Pose &first_pose) {
  const size_t size_before = carty_world_grid_size(grid);
  const int64_t last_id = 60;
  for (int64_t keyframe_id = 3; keyframe_id < last_id; ++keyframe_id) {
    static_cast<void>(fold_obs(grid, obs, first_pose, keyframe_id));
  }
  const int8_t *now = carty_world_grid_cells(grid);
  bool bounded = true;
  for (size_t i = 0; i < size_before; ++i) {
    bounded = bounded && now[i] <= kLogOddsMax;
  }
  CHECK(bounded, "many distinct keyframes never push a cell past L_MAX");
  CHECK(carty_world_grid_size(grid) == size_before,
        "grid never grows beyond n*n*h under repetition");
}

void test_lifecycle() {
  CartyWorldGrid *grid = make_grid();
  test_create(grid);
  CartyOrthoMap *obs = make_observation(kSceneDims);
  test_ortho_extent(obs);
  const Pose first_pose = pitched_pose(kFirstCam);  // heading +Z, at world origin
  test_anchor(grid, obs, first_pose);
  test_idempotent_and_monotone(grid, obs, first_pose);
  test_bounded_repetition(grid, obs, first_pose);
  carty_world_grid_free(grid);
  carty_ortho_map_free(obs);
}

// ---- 5. out-of-bounds safety
void test_out_of_bounds() {
  CartyWorldGrid *grid = make_grid();
  CartyOrthoMap *obs = make_observation(kSceneDims);
  CHECK(fold_obs(grid, obs, pitched_pose(kFirstCam), 1) == CARTY_FUSE_OK,
        "OOB setup: first keyframe anchors in-bounds");
  const Snapshot before = snapshot(grid);
  const Pose far_pose = pitched_pose({kFarAwayM, kCamHeightM, 0.0});
  CHECK(fold_obs(grid, obs, far_pose, 2) == CARTY_FUSE_OUT_OF_BOUNDS,
        "a far keyframe returns OUT_OF_BOUNDS");
  CHECK(unchanged_since(grid, before), "OUT_OF_BOUNDS leaves the grid untouched (zero OOB writes)");
  carty_world_grid_free(grid);
  carty_ortho_map_free(obs);
}

// ---- 7. yaw placement (the #1 correctness risk)
/* (a) Yaw isolation: a pose with heavy pitch and one with NO pitch but the same
 *     heading must place observations IDENTICALLY. A naive yaw extractor polluted
 *     by pitch would diverge here — this is the guard that matters. */
void test_yaw_isolated_from_pitch() {
  const double yaw_30_rad = 0.5235987756;
  CartyOrthoMap *obs = make_observation(kSceneDims);
  CartyWorldGrid *pitched = make_grid();
  CartyWorldGrid *level = make_grid();
  static_cast<void>(fold_obs(pitched, obs, build_pose({yaw_30_rad, kPitchRad, kFirstCam}), 1));
  static_cast<void>(fold_obs(level, obs, build_pose({yaw_30_rad, 0.0, kFirstCam}), 1));
  CHECK(same_cells(pitched, level),
        "yaw extraction is isolated from pitch (heavy-pitch == no-pitch placement)");
  carty_world_grid_free(pitched);
  carty_world_grid_free(level);
  carty_ortho_map_free(obs);
}

/* (b) Known-yaw geometry: yaw=0 places the floor in +gy of the camera; yaw=90°
 *     rotates it into +gx, with equal displacement magnitude. */
void test_known_yaw_geometry() {
  const double yaw_90_rad = 1.5707963268;
  CartyOrthoMap *obs = make_observation(kSceneDims);
  CartyWorldGrid *heading_z = make_grid();
  CartyWorldGrid *heading_x = make_grid();
  static_cast<void>(fold_obs(heading_z, obs, pitched_pose(kFirstCam), 1));
  static_cast<void>(fold_obs(heading_x, obs, build_pose({yaw_90_rad, kPitchRad, kFirstCam}), 1));
  const Centroid along_z = observed_centroid(heading_z);
  const Centroid along_x = observed_centroid(heading_x);
  const double z_shift_cols = along_z.col - kCentreCell;
  const double z_shift_rows = along_z.row - kCentreCell;
  const double x_shift_cols = along_x.col - kCentreCell;
  const double x_shift_rows = along_x.row - kCentreCell;
  CHECK(z_shift_rows > kMinShiftCells && std::fabs(z_shift_cols) < kMaxDriftCells,
        "yaw=0 displaces the footprint along +gy (forward = +Z)");
  CHECK(x_shift_cols > kMinShiftCells && std::fabs(x_shift_rows) < kMaxDriftCells,
        "yaw=90 displaces the footprint along +gx (forward = +X)");
  CHECK(std::fabs(z_shift_rows - x_shift_cols) < kMaxDriftCells,
        "yaw rotates the footprint without changing its displacement magnitude");
  carty_world_grid_free(heading_z);
  carty_world_grid_free(heading_x);
  carty_ortho_map_free(obs);
}

/* (c) Pure translation places observations un-rotated: same heading, different
 *     camera position -> the grid re-anchors on the camera, so the map relative
 *     to the (re-centered) grid is BYTE-IDENTICAL (translation-equivariant, no
 *     spurious rotation). */
void test_pure_translation() {
  const WorldPos moved{5.0, kCamHeightM, -3.0};
  CartyOrthoMap *obs = make_observation(kSceneDims);
  CartyWorldGrid *at_origin = make_grid();
  CartyWorldGrid *translated = make_grid();
  static_cast<void>(fold_obs(at_origin, obs, pitched_pose(kFirstCam), 1));
  static_cast<void>(fold_obs(translated, obs, pitched_pose(moved), 1));
  CHECK(same_cells(at_origin, translated),
        "pure translation yields a byte-identical map (un-rotated)");
  carty_world_grid_free(at_origin);
  carty_world_grid_free(translated);
  carty_ortho_map_free(obs);
}

/* (d) Degenerate yaw: a camera looking straight down has a vertical forward axis,
 *     so pose_yaw must fall back to the right axis instead of an unstable atan2 on
 *     a ~zero vector. The contract here is robustness: accrete must NOT crash and
 *     must fold cleanly (the exact heading is unimportant). */
void test_degenerate_yaw() {
  CartyOrthoMap *obs = make_observation(kSceneDims);
  CartyWorldGrid *grid = make_grid();
  CHECK(fold_obs(grid, obs, build_topdown_pose(kFirstCam), 1) == CARTY_FUSE_OK,
        "straight-down (degenerate-yaw) pose folds without crashing");
  CHECK(observed_cells(grid) > 0, "degenerate-yaw accrete still observes cells");
  carty_world_grid_free(grid);
  carty_ortho_map_free(obs);
}

// ---- 10. segment full — SEEN_MAX keyframes degrade, not crash
/* The seen-id table is bounded (CARTY_GRID_SEEN_MAX). Reaching it is the expected
 * signal to start a new segment, NOT a corrupt boundary — so the
 * (MAX+1)th DISTINCT keyframe must return SEEN_FULL with the grid untouched,
 * while a DUPLICATE is still answered as a no-op even when full. */
void test_segment_full() {
  CartyOrthoMap *obs = make_observation(kSmallDims);
  CartyWorldGrid *grid = make_grid();
  const Pose pose = pitched_pose(kFirstCam);
  bool all_ok = true;
  for (int64_t keyframe_id = 1; keyframe_id <= CARTY_GRID_SEEN_MAX; ++keyframe_id) {
    all_ok = all_ok && fold_obs(grid, obs, pose, keyframe_id) == CARTY_FUSE_OK;
  }
  CHECK(all_ok, "SEEN_MAX distinct keyframes all fold (table fills exactly)");
  const Snapshot full = snapshot(grid);
  CHECK(fold_obs(grid, obs, pose, CARTY_GRID_SEEN_MAX + 1) == CARTY_FUSE_SEEN_FULL,
        "the (SEEN_MAX+1)th distinct keyframe returns SEEN_FULL (no crash)");
  CHECK(unchanged_since(grid, full), "SEEN_FULL leaves the grid byte-identical (no-op)");
  CHECK(fold_obs(grid, obs, pose, 1) == CARTY_FUSE_DUPLICATE,
        "a known keyframe is still a DUPLICATE no-op even when the segment is full");
  carty_world_grid_free(grid);
  carty_ortho_map_free(obs);
}

// ---- 11. raw-frame splat (carty_world_grid_accrete_from_frame)
/* The metric path: back-project pixels through K and the FULL 4x4 pose
 * (pitch/roll + real translation), intersect the ground plane (world Y=0), and
 * fold like accrete. These properties pin the behaviours accrete cannot have:
 * metric translation, pitch invariance of ground placement, plus the shared
 * idempotency / OOB-safety / boundary-death contract. */

int max_observed_col(const CartyWorldGrid *grid) {
  const auto grid_side = static_cast<size_t>(carty_world_grid_n(grid));
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t cell_count = carty_world_grid_size(grid);
  int max_col = -1;
  for (size_t i = 0; i < cell_count; ++i) {
    const int col = static_cast<int>(i % grid_side);
    if (cells[i] != 0 && col > max_col) {
      max_col = col;
    }
  }
  return max_col;
}

/* (a) Metric placement: a camera translated +0.5 m in world X shifts the observed
 *     footprint by exactly lround(0.5/res) cells. Both grids anchor identically on
 *     the origin pose (same keyframe id 100 → same origin), then one folds the
 *     origin pose again (id 2) and the other the +X pose (id 2). Comparing their max
 *     gx isolates the pure translation shift. */
void test_frame_metric_placement() {
  const double shift_m = 0.5;
  const int64_t anchor_id = 100;
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, kGray);
  const FrameShot shot{frame, kSmallDims, &kFrameIntrinsics};
  const Pose origin_pose = pitched_pose(kFirstCam);
  const Pose shifted_pose = pitched_pose({shift_m, kCamHeightM, 0.0});
  CartyWorldGrid *stay = make_grid();
  CartyWorldGrid *moved = make_grid();
  static_cast<void>(fold_frame(stay, shot, origin_pose, anchor_id));
  static_cast<void>(fold_frame(moved, shot, origin_pose, anchor_id));
  const GridOrigin stay_origin = origin_of(stay);
  const GridOrigin moved_origin = origin_of(moved);
  CHECK(stay_origin.x_m == moved_origin.x_m && stay_origin.y_m == moved_origin.y_m,
        "frame splat: anchoring on the same camera yields identical grid origins");
  static_cast<void>(fold_frame(moved, shot, shifted_pose, 2));
  static_cast<void>(fold_frame(stay, shot, origin_pose, 2));
  CHECK(max_observed_col(moved) - max_observed_col(stay) ==
            static_cast<int>(std::lround(shift_m / kCellM)),
        "frame splat: +0.5 m world-X advances the footprint by exactly 0.5/res cells");
  carty_world_grid_free(stay);
  carty_world_grid_free(moved);
  carty_frame_free(frame);
}

/* which ground columns hold any observed cell; returns the observed cell count */
using ColumnSet = std::array<bool, kGridSide>;
size_t observed_columns(const CartyWorldGrid *grid, ColumnSet *columns) {
  const int8_t *cells = carty_world_grid_cells(grid);
  const size_t cell_count = carty_world_grid_size(grid);
  columns->fill(false);
  size_t observed = 0;
  for (size_t i = 0; i < cell_count; ++i) {
    if (cells[i] != 0) {
      (*columns)[i % kGridSide] = true;
      ++observed;
    }
  }
  return observed;
}

/* (b) Pitch invariance of LATERAL ground placement (yaw=0): the same camera at two
 *     different pitch angles (60° and 70°) must project to the SAME SET of gx
 *     (world-X) columns. Pitch changes the DEPTH (gy) of the ground patch, but with
 *     yaw=0 the camera right axis is exactly world +X, so the lateral (gx) spread is
 *     set ONLY by the pixel u coordinates, never by pitch.
 *
 *       BUG IT CATCHES: if pitch leaked into the world-X ray component — e.g. by
 *       using cam_dy instead of cam_dx for the horizontal projection, by swapping
 *       the camera RIGHT column (rx,ry,rz) with the BACK column (bx,by,bz), or
 *       by a sign error that rotates the ray direction as pitch changes — the two
 *       footprints' gx columns would differ. The assertion is EXACT (not a
 *       centroid tolerance) so any lateral shift of even one cell fails it.
 *
 *     Both grids anchor on the same camera, so gx cell indices compare directly. */
void test_frame_pitch_invariance() {
  const double pitch_60_rad = 1.0471975512;
  const double pitch_70_rad = 1.2217304764;
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, kGray);
  const FrameShot shot{frame, kSmallDims, &kFrameIntrinsics};
  CartyWorldGrid *at_60 = make_grid();
  CartyWorldGrid *at_70 = make_grid();
  CHECK(fold_frame(at_60, shot, build_pose({0.0, pitch_60_rad, kFirstCam}), 1) == CARTY_FUSE_OK,
        "frame splat: 60-deg pitch frame folds (OK)");
  CHECK(fold_frame(at_70, shot, build_pose({0.0, pitch_70_rad, kFirstCam}), 1) == CARTY_FUSE_OK,
        "frame splat: 70-deg pitch frame folds (OK)");
  const GridOrigin origin_60 = origin_of(at_60);
  const GridOrigin origin_70 = origin_of(at_70);
  CHECK(origin_60.x_m == origin_70.x_m && origin_60.y_m == origin_70.y_m,
        "frame splat pitch-invariance: both pitches anchor to the same grid origin");
  ColumnSet columns_60{};
  ColumnSet columns_70{};
  const size_t observed_60 = observed_columns(at_60, &columns_60);
  const size_t observed_70 = observed_columns(at_70, &columns_70);
  CHECK(observed_60 > 0 && observed_70 > 0,
        "frame splat pitch-invariance: both pitches observe ground cells");
  CHECK(columns_60 == columns_70,
        "frame splat: pitch invariance — yaw=0 footprints share IDENTICAL gx columns "
        "(pitch changes depth/gy, not lateral/gx — column-swap bug fails this)");
  carty_world_grid_free(at_60);
  carty_world_grid_free(at_70);
  carty_frame_free(frame);
}

/* (c) Idempotency: re-feeding the same keyframe id is a literal no-op. */
void test_frame_idempotent() {
  const int64_t keyframe_id = 7;
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, kGray);
  const FrameShot shot{frame, kSmallDims, &kFrameIntrinsics};
  const Pose pose = pitched_pose(kFirstCam);
  CartyWorldGrid *grid = make_grid();
  CHECK(fold_frame(grid, shot, pose, keyframe_id) == CARTY_FUSE_OK,
        "frame splat: first fold of keyframe 7 (OK)");
  const Snapshot snap = snapshot(grid);
  CHECK(fold_frame(grid, shot, pose, keyframe_id) == CARTY_FUSE_DUPLICATE,
        "frame splat: re-feeding keyframe 7 returns DUPLICATE");
  CHECK(unchanged_since(grid, snap),
        "frame splat: DUPLICATE leaves the grid BYTE-IDENTICAL (idempotent)");
  carty_world_grid_free(grid);
  carty_frame_free(frame);
}

/* (d) Bounded / OOB-safe: a far-off-grid pose returns OUT_OF_BOUNDS and writes
 *     nothing (must be clean under ASan). */
void test_frame_out_of_bounds() {
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, kGray);
  const FrameShot shot{frame, kSmallDims, &kFrameIntrinsics};
  CartyWorldGrid *grid = make_grid();
  CHECK(fold_frame(grid, shot, pitched_pose(kFirstCam), 1) == CARTY_FUSE_OK,
        "frame splat OOB setup: first frame anchors in-bounds");
  const Snapshot snap = snapshot(grid);
  CHECK(fold_frame(grid, shot, pitched_pose({kFarAwayM, kCamHeightM, 0.0}), 2) ==
            CARTY_FUSE_OUT_OF_BOUNDS,
        "frame splat: a far frame returns OUT_OF_BOUNDS");
  CHECK(unchanged_since(grid, snap),
        "frame splat: OUT_OF_BOUNDS leaves the grid untouched (zero OOB writes)");
  carty_world_grid_free(grid);
  carty_frame_free(frame);
}

/* (e) Boundary deaths (fork): NULL grid/frame/pose/K, non-finite pose/K, and a
 *     width*height*channels size mismatch all abort. */
void test_frame_deaths() {
  CHECK(aborts(death_frame_null_grid), "frame splat aborts on a NULL grid handle");
  CHECK(aborts(death_frame_null_frame), "frame splat aborts on a NULL frame");
  CHECK(aborts(death_frame_null_pose), "frame splat aborts on a NULL pose");
  CHECK(aborts(death_frame_null_k), "frame splat aborts on a NULL K");
  CHECK(aborts(death_frame_nonfinite_pose), "frame splat aborts on a non-finite pose entry");
  CHECK(aborts(death_frame_nonfinite_k), "frame splat aborts on a non-finite K entry");
  CHECK(aborts(death_frame_size_mismatch),
        "frame splat aborts on a width*height*channels size mismatch");
}

/* offset of the fixed ground band (h/2) in the band-major cell array */
size_t ground_band_base(const CartyWorldGrid *grid) {
  const auto grid_side = static_cast<size_t>(carty_world_grid_n(grid));
  const auto ground_band = static_cast<size_t>(carty_world_grid_h(grid) / 2);
  return ground_band * grid_side * grid_side;
}

/* (f) Color photo-map: feeding a frame painted a distinct RGB triple makes every
 *     OBSERVED ground cell carry that exact source color in the n*n*3 color buffer
 *     (top-down evidence layer). A gray frame can't catch a channel swap; this
 *     distinct-RGB frame does. Unobserved cells stay 0 (calloc). */
void test_frame_color() {
  const Rgb source{200, 120, 40};  // distinct R!=G!=B
  constexpr size_t kColorChannels = 3;
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, source);
  CartyWorldGrid *grid = make_grid();
  CHECK(fold_frame(grid, {frame, kSmallDims, &kFrameIntrinsics}, pitched_pose(kFirstCam), 1) ==
            CARTY_FUSE_OK,
        "frame splat color: a distinct-RGB frame folds (OK)");
  const size_t ground_cells = static_cast<size_t>(kGridSide) * kGridSide;
  const int8_t *band = carty_world_grid_cells(grid) + ground_band_base(grid);
  const uint8_t *color = carty_world_grid_color(grid);
  bool found = false;
  bool color_matches = true;
  for (size_t cell = 0; cell < ground_cells; ++cell) {
    if (band[cell] == 0) {
      continue;
    }
    found = true;
    const uint8_t *rgb = color + (cell * kColorChannels);
    color_matches = color_matches && rgb[0] == source.red && rgb[1] == source.green &&
                    rgb[2] == source.blue;
  }
  CHECK(found, "frame splat color: at least one ground cell was observed");
  CHECK(found && color_matches,
        "frame splat: every observed ground cell carries the source RGB "
        "(top-down photo-map; first-touch sets exact color)");
  carty_world_grid_free(grid);
  carty_frame_free(frame);
}

/* (g) Far metric-range clip (STOPGAP, explicitly not the final design): a
 *     frame whose every ground hit is beyond CARTY_FUSE_RANGE_FAR_M folds NOTHING
 *     and returns OUT_OF_BOUNDS. Camera high up (5 m) and pitched 60 deg puts the
 *     whole footprint ~5.6-5.8 m out — past the 4 m far gate. The grid is sized
 *     (N=256, res=0.1 -> 25.6 m span) so that WITHOUT the gate the footprint lands
 *     ON-grid (returns OK): the clip is the only thing that makes this OOB. */
void test_frame_far_clip() {
  const int32_t wide_side = 256;
  const double wide_cell_m = 0.1;
  const double high_cam_m = 5.0;
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, kGray);
  const CartyGridShape wide_shape{wide_side, kBands, wide_cell_m, kBandM};
  CartyWorldGrid *grid = carty_world_grid_create(&wide_shape);
  CHECK(fold_frame(grid, {frame, kSmallDims, &kFrameIntrinsics},
                   pitched_pose({0.0, high_cam_m, 0.0}), 1) == CARTY_FUSE_OUT_OF_BOUNDS,
        "frame splat: every hit beyond the far range gate folds nothing (OOB)");
  carty_world_grid_free(grid);
  carty_frame_free(frame);
}

/* (h) Near metric-range clip (STOPGAP, not the final design): a frame whose every
 *     ground hit is closer than CARTY_FUSE_RANGE_NEAR_M folds NOTHING and returns
 *     OUT_OF_BOUNDS. A straight-down camera at 0.3 m puts the whole footprint
 *     ~0.30 m out — inside the 0.5 m near gate. The footprint is tiny and centered,
 *     so WITHOUT the gate it lands on-grid (OK); the clip alone makes it OOB. */
void test_frame_near_clip() {
  const double low_cam_m = 0.3;
  CartyFrame *frame = frame_fixture::make_filled_frame(kSmallDims, kGray);
  CartyWorldGrid *grid = make_grid();
  CHECK(fold_frame(grid, {frame, kSmallDims, &kFrameIntrinsics},
                   build_topdown_pose({0.0, low_cam_m, 0.0}), 1) == CARTY_FUSE_OUT_OF_BOUNDS,
        "frame splat: every hit inside the near range gate folds nothing (OOB)");
  carty_world_grid_free(grid);
  carty_frame_free(frame);
}

/* (i) Grazing-incidence clip (STOPGAP, not the final design): a frame whose rays
 *     all strike the ground at too shallow an angle folds NOTHING (OOB). A NARROW-
 *     FOV fixture (4x4 px, fx=fy=5000 -> ~0.0008 rad span) makes every pixel share
 *     one incidence, so the gate is tested in isolation from the range gate. Camera
 *     pitched only 10 deg down at 0.5 m: sin(incidence)=0.174 (< the cutoff) yet the
 *     hit distance ~2.88 m sits INSIDE [near,far] — so range alone would keep it and
 *     the incidence gate alone makes it OOB. */
void test_frame_grazing_clip() {
  const CartyIntrinsics narrow_intrinsics{5000.0, 5000.0, 2.0, 2.0};
  const double pitch_10_rad = 0.17453292519943295;
  const double cam_m = 0.5;
  const FrameDims tiny{4, 4, 4};
  CartyFrame *frame = frame_fixture::make_filled_frame(tiny, kGray);
  CartyWorldGrid *grid = make_grid();
  CHECK(fold_frame(grid, {frame, tiny, &narrow_intrinsics},
                   build_pose({0.0, pitch_10_rad, {0.0, cam_m, 0.0}}), 1) ==
            CARTY_FUSE_OUT_OF_BOUNDS,
        "frame splat: a grazing-incidence frame folds nothing (OOB)");
  carty_world_grid_free(grid);
  carty_frame_free(frame);
}

/* total log-odds and count of the observed cells in the ground band */
struct BandEvidence {
  int64_t sum, cells;
};
BandEvidence ground_band_evidence(const CartyWorldGrid *grid) {
  const size_t ground_cells = static_cast<size_t>(kGridSide) * kGridSide;
  const int8_t *band = carty_world_grid_cells(grid) + ground_band_base(grid);
  BandEvidence evidence{0, 0};
  for (size_t cell = 0; cell < ground_cells; ++cell) {
    if (band[cell] != 0) {
      evidence.sum += band[cell];
      ++evidence.cells;
    }
  }
  return evidence;
}

/* (j) Range-weighted log-odds (confidence refinement, NOT a reject gate). The splat
 *     fold is graded by metric ray distance. A 9x9 frame through fx=fy=10000 projects
 *     only its centre pixel on-grid (the rest clip), and a top-down camera makes that
 *     ray vertical, so its distance is the camera height. The near camera (0.55 m, just
 *     past the near gate) must fold more evidence than the far one (3.95 m, just
 *     before the far gate). */
void test_frame_range_weight() {
  const CartyIntrinsics narrow_intrinsics{10000.0, 10000.0, 4.0, 4.0};
  const FrameDims nine{9, 9, 4};
  const double near_cam_m = 0.55;
  const double far_cam_m = 3.95;
  CartyFrame *frame = frame_fixture::make_filled_frame(nine, kGray);
  const FrameShot shot{frame, nine, &narrow_intrinsics};
  CartyWorldGrid *near_grid = make_grid();
  CartyWorldGrid *far_grid = make_grid();
  CHECK(fold_frame(near_grid, shot, build_topdown_pose({0.0, near_cam_m, 0.0}), 1) ==
            CARTY_FUSE_OK,
        "range-weight test: topdown near-height frame folds (OK)");
  CHECK(fold_frame(far_grid, shot, build_topdown_pose({0.0, far_cam_m, 0.0}), 2) ==
            CARTY_FUSE_OK,
        "range-weight test: topdown far-height frame folds (OK)");
  const BandEvidence near = ground_band_evidence(near_grid);
  const BandEvidence far = ground_band_evidence(far_grid);
  CHECK(near.sum > far.sum,
        "range-weight test: near-height total cell evidence strictly exceeds far-height");
  CHECK(near.sum > 0 && far.sum > 0,
        "range-weight test: both near and far folds are positive (gate-passed "
        "evidence never drops to zero)");
  CHECK(near.cells > 0 && far.cells > 0, "range-weight test: both folds affect at least one cell");
  carty_world_grid_free(near_grid);
  carty_world_grid_free(far_grid);
  carty_frame_free(frame);
}

// ---- 8. memory (LSan) — create/free with no leak
void test_memory() {
  const int32_t small_side = 64;
  const double small_cell_m = 0.1;
  const double small_band_m = 0.5;
  const CartyGridShape small_shape{small_side, 4, small_cell_m, small_band_m};
  CartyWorldGrid *grid = carty_world_grid_create(&small_shape);
  CHECK(grid != nullptr, "small grid created");
  carty_world_grid_free(grid);
  CHECK(true, "grid freed without abort or leak (LSan asserts)");
}

// ---- 9. boundary death — NULL / non-finite inputs abort
void test_accrete_deaths() {
  g_death_observation = make_observation(kSceneDims);
  CHECK(aborts(death_null_grid), "accrete aborts on a NULL grid handle");
  CHECK(aborts(death_null_obs), "accrete aborts on a NULL observation");
  CHECK(aborts(death_null_pose), "accrete aborts on a NULL pose");
  CHECK(aborts(death_nonfinite_pose), "accrete aborts on a non-finite pose entry");
  carty_ortho_map_free(g_death_observation);
  g_death_observation = nullptr;
}

}  // namespace

int main() {
  // snapshot vectors allocate and can throw; a throw is a failed run, not a crash
  try {
    test_lifecycle();
    test_out_of_bounds();
    test_yaw_isolated_from_pitch();
    test_known_yaw_geometry();
    test_pure_translation();
    test_degenerate_yaw();
    test_segment_full();
    test_frame_metric_placement();
    test_frame_pitch_invariance();
    test_frame_idempotent();
    test_frame_out_of_bounds();
    test_frame_deaths();
    test_frame_color();
    test_frame_far_clip();
    test_frame_near_clip();
    test_frame_grazing_clip();
    test_frame_range_weight();
    test_memory();
    test_accrete_deaths();
  } catch (...) {
    carty_sayf(stderr, "%s\n", "FAIL: a world-grid test threw");
    return 1;
  }
  return carty_finish("ALL WORLD-GRID FUSION TESTS PASSED");
}
