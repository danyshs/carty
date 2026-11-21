/*
 * carty_fusion.cpp — Fusion stage: the persistent world-frame voxel-column grid
 * (one of the carty_bridge translation units; the fourth natural seam named in
 * carty_bridge_internal.h and.
 *
 * This TU owns the CartyWorldGrid: the world accumulator the whole architecture
 * pivot rests on. carty_ortho_project alone produces a camera-LOCAL top-down grid
 * under a FIXED assumed pose, so nothing registers frame N to frame N+1 and a map
 * cannot accrete. carty_world_grid_accrete folds a pose-stamped
 * keyframe's already-orthorectified observation into ONE world-anchored, bounded
 * 2.5D grid across calls, with a clamped-additive int8 log-odds update that is
 * monotonic in evidence (distinct keyframes accumulate) and idempotent under a
 * repeated keyframe (a bounded set of incorporated ids makes a re-feed a no-op).
 *
 * HONEST SCOPE CAVEAT (a confident-but-wrong comment is the worst failure
 * mode here): this increment registers the observation using
 * ONLY the pose's horizontal translation + yaw (heading on the world X-Z plane),
 * folds every observation into a single FIXED band (the camera-height level h/2,
 * NOT the geometric floor — depth is deferred, so the H axis is allocated and
 * addressable but not populated from real depth), and
 * INHERITS the fixed-pose metric scale baked into carty_ortho_project (height
 * 1.6 m / pitch 60°). It does NOT use the pose's pitch/roll or any real metric
 * scale — so two segments captured at different camera heights will not perfectly
 * co-register even horizontally. Real pitch/roll, true height-banding, and real
 * scale arrive with a future raw-frame splat (carty_world_grid_accrete_from_frame),
 * which is also where intrinsics (K) re-enter; there is deliberately no K here
 * (the observation already consumed K, a 2nd K is dead surface).
 *
 * Coordinate convention is fixed in carty_bridge.h: ARCore world is right-handed
 * Y-UP; ground axes gx,gy map to world X,Z; band maps to world-up Y.
 */
#include "carty_bridge.h"
#include "carty_bridge_internal.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <utility>

/* Log-odds update knobs (not load-bearing for the bounded/monotonic/
 * idempotent properties the gate tests). Per-observation increment chosen so ~6
 * corroborating views saturate; clamp bounds every cell. */
#define CARTY_FUSE_L_OCC 20
#define CARTY_FUSE_L_MIN (-127)
#define CARTY_FUSE_L_MAX (127)

/* Near/far metric range gate (STOPGAP, explicitly NOT the depth path).
 * Until true depth height-banding lands (#6), the splat folds EVERY back-projected
 * ground hit at a single fixed band, so a grazing far ray or a too-close near ray
 * smears garbage into the floor layer. These bounds discard hits whose metric ray
 * distance falls outside a plausible hand-held capture range, cheaply suppressing the
 * worst smear without pretending to be real occlusion. Distance is the TRUE ray length
 * s*|d|, not the plane parameter s (s == metres only for the centre pixel). */
#define CARTY_FUSE_RANGE_NEAR_M 0.5
#define CARTY_FUSE_RANGE_FAR_M 4.0

/* Grazing-incidence gate (same STOPGAP family as the range gate, not the final design).
 * A ray that strikes the floor at a shallow angle spreads one pixel over a long ground
 * smear and is dominated by depth error — exactly the garbage the single fixed band
 * can't separate. Drop hits whose sine of incidence (|dwy| / |d|, the ray's verticality)
 * is below this floor (~14.5 deg). Retired with the range gate once depth banding lands. */
#define CARTY_FUSE_INCIDENCE_MIN 0.25

/* Range-weighted log-odds (STOPGAP, not the final design). A confidence refinement
 * that grades the fold magnitude by metric ray distance within the gate band [NEAR, FAR]:
 * hits at NEAR distance fold MORE evidence (higher SNR, less projection error); hits at
 * FAR distance fold a FLOORED minimum (they passed the gate, so they are still evidence,
 * just weighted down by distance uncertainty). The weight is linear across the band:
 *   w = (FAR - dist) / (FAR - NEAR),  clamped to [0,1]  -> 1.0 at NEAR, 0.0 at FAR
 *   inc = (int)lround(L_OCC * (W_MIN + (1 - W_MIN) * w))
 * This gives inc ≈ L_OCC at near, ≈ W_MIN*L_OCC at far (both > 0), always an integer >= 1.
 * Retired with the range gate once depth banding + per-hit confidence lands. */
#define CARTY_FUSE_RANGE_W_MIN 0.35

/* Confidence-weighted log-odds (additive half of the Inverse Sensor Model).
 * ARCore ships a per-pixel reliability signal (raw-depth confidence, uint8 0–255). confidence weighting
 * scales the fold magnitude by it so unreliable depth contributes less evidence; occlusion carving
 * occlusion carving will reuse the SAME weight on the negative free-space increment.
 * CONF_MIN is ARCore's documented "half confidence" hard cutoff — a ray below it is
 * dropped (tunable; lower toward ~77 = 0.3·255 if textureless walls drop out, safe on
 * a ToF device). CONF_W_MIN floors the weight so a gate-passed hit always folds > 0,
 * mirroring CARTY_FUSE_RANGE_W_MIN exactly so occlusion carving inherits one idiom, not two. */
#define CARTY_FUSE_CONF_MIN 128
#define CARTY_FUSE_CONF_W_MIN 0.35

/* Free-space carve knobs (negative ISM half). CARVE_SCALE grades the
 * carve magnitude relative to the occupied fold the same ray deposits: 1.0 = symmetric
 * (N clean pass-throughs undo N hits), tunable from replay data without touching logic.
 * CARVE_MAX_STEPS bounds the per-ray DDA (Tiger Style): the max voxel-face crossings
 * a segment can make inside an n*n*h grid is 2*n + h; the cap is an upper-bound guard,
 * not an expected exit (the march stops at the hit voxel first). */
#define CARTY_FUSE_CARVE_SCALE 1.0

namespace {

int8_t clamp_log_odds(int log_odds) {
  if (log_odds > CARTY_FUSE_L_MAX) {
    return static_cast<int8_t>(CARTY_FUSE_L_MAX);
  }
  if (log_odds < CARTY_FUSE_L_MIN) {
    return static_cast<int8_t>(CARTY_FUSE_L_MIN);
  }
  return static_cast<int8_t>(log_odds);
}

double clamp_unit(double weight) { return std::min(std::max(weight, 0.0), 1.0); }

/* Shared weighted-fold kernel (exists so EVERY graded log-odds fold routes through
 * ONE line of arithmetic — delete it and the range-weighted and confidence-weighted
 * folds drift apart on the next tweak). Maps a normalized weight w∈[0,1] and its
 * floor w_min∈[0,1] to a log-odds increment: inc = lround(L_OCC·(w_min+(1−w_min)·w)),
 * floored to ≥1 so any gate-passed evidence always folds strictly positive (a 0 fold
 * would be indistinguishable from "unobserved"). Bounded: pure scalar, no allocation. */
int weighted_increment(double w_clamped, double w_min) {
  const double inc_f =
      CARTY_FUSE_L_OCC * (w_min + ((1.0 - w_min) * w_clamped));
  const int inc = static_cast<int>(std::lround(inc_f));
  return (inc < 1) ? 1 : inc;
}

/* Confidence (uint8 0–255) -> positive log-odds increment, the single source of
 * truth for confidence weighting's additive fold AND occlusion carving's free-space carve (occlusion carving negates THIS value, so
 * the two ISM halves cannot numerically diverge — the whole reason this is a function
 * and not inline). Sub-CONF_MIN rays return CARTY_FUSE_CONF_DROP and the caller skips
 * the cell. The returned magnitude is always ≥1 (weighted_increment floors it), so the
 * 0 sentinel can never collide with a real increment. */
#define CARTY_FUSE_CONF_DROP 0 /* sentinel: ray too unreliable to fold (skip cell) */
int conf_to_increment(int confidence) {
  if (confidence < CARTY_FUSE_CONF_MIN) {
    return CARTY_FUSE_CONF_DROP;
  }
  const double weight = (static_cast<double>(confidence) - CARTY_FUSE_CONF_MIN) /
                        (static_cast<double>(UINT8_MAX) - CARTY_FUSE_CONF_MIN);
  return weighted_increment(clamp_unit(weight), CARTY_FUSE_CONF_W_MIN);
}

/* Range-weighted fold (STOPGAP, not the final design): grade the log-odds increment
 * by metric ray distance. Linear weight across [NEAR, FAR]:
 *   w = (FAR - dist) / (FAR - NEAR)  -> 1.0 at NEAR, 0.0 at FAR
 *   inc = lround(L_OCC * (W_MIN + (1 - W_MIN) * w))
 * Near hits fold ≈ L_OCC (full confidence), far hits ≈ W_MIN*L_OCC (still > 0). */
int range_increment(double dist_m) {
  const double weight = (CARTY_FUSE_RANGE_FAR_M - dist_m) /
                        (CARTY_FUSE_RANGE_FAR_M - CARTY_FUSE_RANGE_NEAR_M);
  return weighted_increment(clamp_unit(weight), CARTY_FUSE_RANGE_W_MIN);
}

/* ---- carve: 3D DDA in voxel space ---------------------------------------- */

constexpr int kAxes = 3;               // voxel axes: ground col (world X), ground row (world Z), band (world Y)
constexpr double kParallelEps = 1e-12;  // |delta| below this: the ray runs parallel to a slab

/* continuous voxel coords: X/Z in ground cells, Y in bands */
struct VoxelPoint {
  double col, row, band;
};
struct VoxelIndex {
  int64_t col, row, band;
};

/* p(t) = start + t*delta for t in [0,1], inside the box [0, upper] per axis */
struct CarveRay {
  double start[kAxes];
  double delta[kAxes];
  double upper[kAxes];
};

/* Slab clip of the ray to the grid box; false when it never enters. The hit endpoint
 * is in-bounds, so an overlap exists; the guard covers parallel-and-outside anyway. */
bool clip_to_grid(const CarveRay &ray, double *t_enter) {
  double t_min = 0.0;
  double t_max = 1.0;
  for (int axis = 0; axis < kAxes; ++axis) {
    if (std::fabs(ray.delta[axis]) < kParallelEps) {
      if (ray.start[axis] < 0.0 || ray.start[axis] > ray.upper[axis]) {
        return false; /* parallel & outside this slab */
      }
      continue;
    }
    double t_low = (0.0 - ray.start[axis]) / ray.delta[axis];
    double t_high = (ray.upper[axis] - ray.start[axis]) / ray.delta[axis];
    if (t_low > t_high) {
      std::swap(t_low, t_high);
    }
    t_min = std::max(t_low, t_min);
    t_max = std::min(t_high, t_max);
    if (t_min > t_max) {
      return false; /* no overlap (should not happen with in-bounds hit) */
    }
  }
  *t_enter = t_min;
  return true;
}

int step_sign(double delta) {
  if (delta > 0) {
    return 1;
  }
  if (delta < 0) {
    return -1;
  }
  return 0;
}

/* absolute t (in the start+t*delta parameterization) to the axis's next voxel boundary */
double t_to_boundary(double start, double delta, int64_t voxel) {
  if (delta > 0) {
    return (static_cast<double>(voxel + 1) - start) / delta;
  }
  if (delta < 0) {
    return (static_cast<double>(voxel) - start) / delta;
  }
  return std::numeric_limits<double>::infinity();
}

/* the axis whose boundary comes first; ties go to the lower axis */
int next_axis(const double (&t_next)[kAxes]) {
  if (t_next[0] <= t_next[1] && t_next[0] <= t_next[2]) {
    return 0;
  }
  return t_next[1] <= t_next[2] ? 1 : 2;
}

/* Free-space carve (the negative ISM half). Exists so a surface seen
 * from a NEW angle can ERODE a wrongly-occupied cell (the floor-behind-wall smear)
 * instead of merely being out-voted — delete it and the depth grid can only ever add
 * occupancy, never retract it. Lowers log-odds on every in-grid voxel the sensor->hit
 * ray crosses, via an anisotropic Amanatides-Woo DDA in voxel space (X/Z cells are
 * res_m, the height/band axis is band_m). The segment is AABB-clipped first, so the
 * loop is bounded by 2*n+h face crossings (Tiger Style) and only touches in-bounds
 * cells. The HIT voxel (hit) is excluded — the caller folds the
 * positive surface there in the same iteration. Inputs are already in voxel coords. */
void carve_ray_3d(const CartyWorldGrid *grid, const VoxelPoint &sensor,
                  const VoxelPoint &surface, const VoxelIndex &hit, int carve) {
  const int64_t side = grid->n;
  const int64_t bands = grid->h;
  const CarveRay ray = {
      {sensor.col, sensor.row, sensor.band},
      {surface.col - sensor.col, surface.row - sensor.row, surface.band - sensor.band},
      {static_cast<double>(side), static_cast<double>(side), static_cast<double>(bands)},
  };
  double t_enter = 0.0;
  if (!clip_to_grid(ray, &t_enter)) {
    return;
  }
  int64_t voxel[kAxes] = {};
  int step[kAxes] = {};
  double t_next[kAxes] = {};
  double t_delta[kAxes] = {};
  for (int axis = 0; axis < kAxes; ++axis) {
    const double delta = ray.delta[axis];
    /* the voxel the clipped entry point sits in */
    voxel[axis] = static_cast<int64_t>(std::floor(ray.start[axis] + (t_enter * delta)));
    step[axis] = step_sign(delta);
    t_next[axis] = t_to_boundary(ray.start[axis], delta, voxel[axis]);
    t_delta[axis] =
        (delta != 0.0) ? std::fabs(1.0 / delta) : std::numeric_limits<double>::infinity();
  }

  const int64_t max_steps = (2 * side) + bands;
  for (int64_t iter = 0; iter < max_steps; ++iter) {
    if (voxel[0] == hit.col && voxel[1] == hit.row && voxel[2] == hit.band) {
      return; /* reached hit: exclude */
    }
    if (voxel[0] >= 0 && voxel[0] < side && voxel[1] >= 0 && voxel[1] < side && voxel[2] >= 0 &&
        voxel[2] < bands) {
      const size_t idx = (((static_cast<size_t>(voxel[2]) * side) + static_cast<size_t>(voxel[1])) *
                          side) +
                         static_cast<size_t>(voxel[0]);
      CARTY_ASSERT(idx < grid->size, "carve cell index out of bounds");
      grid->cells[idx] = clamp_log_odds(grid->cells[idx] - carve);
    }
    /* advance to the nearest voxel boundary; stop once we would step past the hit */
    const int axis = next_axis(t_next);
    if (t_next[axis] > 1.0) {
      return;
    }
    voxel[axis] += step[axis];
    t_next[axis] += t_delta[axis];
  }
}

/* ---- shared keyframe skeleton -------------------------------------------- */

constexpr int kPoseCols = 4;  // row-major 4x4

double pose_at(const double *pose, int row, int col) { return pose[(row * kPoseCols) + col]; }

/* cam->world pose. Rotation columns are the camera basis in world (right = col 0,
 * up = col 1, back = col 2, so forward = -back); translation is col 3. World is
 * ARCore's right-handed Y-up frame. */
struct CamPose {
  double right_x, right_y, right_z;
  double up_x, up_y, up_z;
  double back_x, back_y, back_z;
  double pos_x_m, pos_y_m, pos_z_m;
};

CamPose read_pose(const CartyPose *pose) {
  CARTY_ASSERT(pose != nullptr, "null pose at boundary");
  const double *matrix = pose->cam_to_world;
  for (int i = 0; i < CARTY_POSE_LEN; ++i) {
    CARTY_ASSERT(std::isfinite(matrix[i]), "non-finite pose entry at boundary");
  }
  return {
      pose_at(matrix, 0, 0), pose_at(matrix, 1, 0), pose_at(matrix, 2, 0),
      pose_at(matrix, 0, 1), pose_at(matrix, 1, 1), pose_at(matrix, 2, 1),
      pose_at(matrix, 0, 2), pose_at(matrix, 1, 2), pose_at(matrix, 2, 2),
      pose_at(matrix, 0, 3), pose_at(matrix, 1, 3), pose_at(matrix, 2, 3),
  };
}

/* pinhole intrinsics K, read once at the boundary */
struct Intrinsics {
  double focal_x_px, focal_y_px, center_x_px, center_y_px;
};

Intrinsics read_intrinsics(const CartyIntrinsics *intrinsics) {
  CARTY_ASSERT(intrinsics != nullptr, "null intrinsics K at boundary");
  const Intrinsics lens = {intrinsics->fx_px, intrinsics->fy_px, intrinsics->cx_px,
                           intrinsics->cy_px,};
  CARTY_ASSERT(std::isfinite(lens.focal_x_px) && std::isfinite(lens.focal_y_px) &&
                   std::isfinite(lens.center_x_px) && std::isfinite(lens.center_y_px),
               "non-finite intrinsics entry at boundary");
  CARTY_ASSERT(lens.focal_x_px > 0.0 && lens.focal_y_px > 0.0,
               "intrinsics fx/fy must be positive");
  return lens;
}

/* CARTY_FUSE_OK when the keyframe may fold, else the non-fatal status to return with
 * the grid untouched. An exact re-feed is a literal no-op (idempotency). */
int32_t refuse_keyframe(const CartyWorldGrid *grid, int64_t keyframe_id) {
  for (int32_t i = 0; i < grid->seen_count; ++i) {
    if (grid->seen_ids[i] == keyframe_id) {
      return CARTY_FUSE_DUPLICATE;
    }
  }
  /* Segment full: a new keyframe cannot be recorded, and folding it WITHOUT
   * recording would re-fold on the next feed and break idempotency. So this is a
   * benign, expected condition — the signal to start a new segment —
   * reported as data, NOT a boundary crash. Grid untouched. (A duplicate is still
   * answered above, since it is a true no-op even when full.) */
  if (grid->seen_count == CARTY_GRID_SEEN_MAX) {
    return CARTY_FUSE_SEEN_FULL;
  }
  return CARTY_FUSE_OK;
}

/* world point of grid cell (0,0,band 0); the grid stores it as origin_x/_y/_z with
 * its ground y along world Z and its band axis along world Y */
struct GridOrigin {
  double world_x_m, world_z_m, world_y_m;
  bool will_anchor;
};

/* Anchor on the FIRST CONTRIBUTING keyframe: center the grid's ground plane (and band
 * stack) on the camera, so the first keyframe is always in-bounds and the grid is a
 * pure function of the pose stream (deterministic replay). This origin is only
 * prospective: commit_fold stores it once the keyframe actually lands on the grid
 * (placed > 0), so an empty first keyframe never burns the anchor on a camera that
 * contributed nothing (it returns OUT_OF_BOUNDS and stays unanchored). */
GridOrigin prospective_origin(const CartyWorldGrid *grid, const CamPose &cam) {
  if (grid->anchored != 0) {
    return {grid->origin_x, grid->origin_y, grid->origin_z, false};
  }
  // whole-cell centre on purpose: an odd-sized grid anchors on its lower middle cell
  const int32_t centre_cell = grid->n / 2;
  const int32_t centre_band = grid->h / 2;
  const double half_side_cells = static_cast<double>(centre_cell);
  const double half_bands = static_cast<double>(centre_band);
  return {cam.pos_x_m - (half_side_cells * grid->res_m),
          cam.pos_z_m - (half_side_cells * grid->res_m),
          cam.pos_y_m - (half_bands * grid->band_m), true,};
}

/* Finish a fold: a keyframe that placed nothing landed entirely off the bounded grid,
 * so it is reported as data with the grid untouched and the anchor NOT committed.
 * Otherwise commit the anchor and record the keyframe in the dedup table. */
int32_t commit_fold(CartyWorldGrid *grid, int64_t placed, const GridOrigin &origin,
                    int64_t keyframe_id) {
  if (placed == 0) {
    return CARTY_FUSE_OUT_OF_BOUNDS;
  }
  if (origin.will_anchor) {
    grid->origin_x = origin.world_x_m;
    grid->origin_y = origin.world_z_m;
    grid->origin_z = origin.world_y_m;
    grid->anchored = 1;
  }
  CARTY_ASSERT(grid->seen_count < CARTY_GRID_SEEN_MAX, "world grid seen-id table overflow");
  grid->seen_ids[grid->seen_count] = keyframe_id;
  ++grid->seen_count;

  /* postconditions */
  CARTY_ASSERT(grid->size == static_cast<size_t>(grid->n) * static_cast<size_t>(grid->n) *
                                 static_cast<size_t>(grid->h),
               "world grid size invariant violated after fold");
  CARTY_ASSERT(grid->anchored == 1, "world grid must be anchored after a fold");
  return CARTY_FUSE_OK;
}

/* a point on the world ground plane */
struct WorldXZ {
  double x_m, z_m;
};
/* a ground cell: col along world X, row along world Z */
struct GroundCell {
  int64_t col, row;
};

/* false when the point falls off the bounded grid (clipped, never clamped) */
bool ground_cell_of(const CartyWorldGrid *grid, const GridOrigin &origin, WorldXZ point,
                    GroundCell *cell) {
  cell->col = static_cast<int64_t>(std::floor((point.x_m - origin.world_x_m) / grid->res_m));
  cell->row = static_cast<int64_t>(std::floor((point.z_m - origin.world_z_m) / grid->res_m));
  return cell->col >= 0 && cell->col < grid->n && cell->row >= 0 && cell->row < grid->n;
}

/* Start of the single fixed band, the camera-height level (h/2), NOT the geometric
 * floor: the ortho and raw-frame paths have no depth, so every hit folds into it. */
size_t fixed_band_base(const CartyWorldGrid *grid) {
  const int32_t band = grid->h / 2;
  CARTY_ASSERT(band >= 0 && band < grid->h, "fixed band out of range");
  return static_cast<size_t>(band) * static_cast<size_t>(grid->n) * static_cast<size_t>(grid->n);
}

size_t ground_index(const CartyWorldGrid *grid, size_t band_base, GroundCell cell) {
  const size_t idx = band_base + ((static_cast<size_t>(cell.row) * grid->n) +
                                  static_cast<size_t>(cell.col));
  CARTY_ASSERT(idx < grid->size, "computed cell index out of bounds");
  return idx;
}

/* Grid yaw (heading on the world X-Z plane) from a cam->world pose. THE #1
 * correctness risk: the camera is pitched ~60° down, so its forward
 * axis projects to a SHORT horizontal vector and a naive atan2 on the wrong matrix
 * elements is unstable. Method: project the camera FORWARD axis (= -(3rd column))
 * onto the world horizontal plane and take its heading; when forward is near
 * vertical (degenerate), fall back to the camera RIGHT axis (1st column), whose
 * heading is offset by +90°. Both yield the same theta for a non-degenerate pose. */
double pose_yaw(const CamPose &cam) {
  constexpr double kDegenerateHoriz = 1e-9;
  constexpr double kQuarterTurnRad = 1.5707963267948966;  // pi/2
  const double forward_x = -cam.back_x;
  const double forward_z = -cam.back_z;
  const double horiz = std::sqrt((forward_x * forward_x) + (forward_z * forward_z));
  if (horiz >= kDegenerateHoriz) {
    return std::atan2(forward_x, forward_z);
  }
  /* degenerate: forward ~ straight up/down, so use the right axis */
  return std::atan2(cam.right_x, cam.right_z) + kQuarterTurnRad;
}

/* ---- the ortho path ------------------------------------------------------- */

/* Rotate each observed ortho cell's camera-local ground position by the pose yaw,
 * translate by the camera horizontal position, map to a ground cell, and fold it at
 * the fixed band. Returns the number of cells placed. */
int64_t fold_observation(const CartyWorldGrid *grid, const CartyOrthoMap *observation,
                         const CamPose &cam, const GridOrigin &origin) {
  const double yaw_rad = pose_yaw(cam);
  const double cos_yaw = std::cos(yaw_rad);
  const double sin_yaw = std::sin(yaw_rad);
  const int32_t obs_width = observation->width;
  const int32_t obs_height = observation->height;
  CARTY_ASSERT(obs_width > 1 && obs_height > 1, "observation too small to span an extent");
  const double step_x_m =
      (observation->max_x - observation->min_x) / static_cast<double>(obs_width - 1);
  const double step_y_m =
      (observation->max_y - observation->min_y) / static_cast<double>(obs_height - 1);
  const size_t band_base = fixed_band_base(grid);

  int64_t placed = 0;
  for (int32_t obs_row = 0; obs_row < obs_height; ++obs_row) {
    /* row 0 is the FAR edge (max_y); rows increase toward the camera */
    const double local_y_m = observation->max_y - (obs_row * step_y_m);
    for (int32_t obs_col = 0; obs_col < obs_width; ++obs_col) {
      if (observation->cells[(static_cast<size_t>(obs_row) * obs_width) + obs_col] == 0) {
        continue; /* unobserved */
      }
      const double local_x_m = observation->min_x + (obs_col * step_x_m);
      /* camera-local (+x right, +y forward) -> world horizontal (X, Z) by yaw */
      const WorldXZ point = {cam.pos_x_m + ((local_x_m * cos_yaw) + (local_y_m * sin_yaw)),
                             cam.pos_z_m + ((-local_x_m * sin_yaw) + (local_y_m * cos_yaw)),};
      GroundCell cell = {0, 0};
      if (!ground_cell_of(grid, origin, point, &cell)) {
        continue;
      }
      const size_t idx = ground_index(grid, band_base, cell);
      /* clamped-additive log-odds: monotonic in evidence, bounded */
      grid->cells[idx] = clamp_log_odds(grid->cells[idx] + CARTY_FUSE_L_OCC);
      ++placed;
    }
  }
  return placed;
}

/* ---- the raw-frame path --------------------------------------------------- */

struct FrameView {
  const CartyFrame *frame;
  int32_t width, height, channels;
};
/* an image pixel: u_px right, v_px down */
struct PixelPos {
  int32_t u_px, v_px;
};
struct FloorHit {
  WorldXZ point;
  double dist_m;  // TRUE ray length to the hit, not the plane parameter
};

constexpr double kRayDownEps = 1e-9;  // |ray_y| below this hits the floor at infinity

/* Back-project one pixel and intersect the ARCore floor plane (world Y = 0). False
 * when the ray misses the floor or a STOPGAP gate drops it (see the knob comments). */
bool floor_hit(const Intrinsics &lens, const CamPose &cam, PixelPos pixel, FloorHit *hit) {
  const double cam_dx = (static_cast<double>(pixel.u_px) - lens.center_x_px) / lens.focal_x_px;
  const double cam_dy = -((static_cast<double>(pixel.v_px) - lens.center_y_px) / lens.focal_y_px);
  const double cam_dz = -1.0;
  /* camera-space ray -> world: d = dx*right + dy*up + dz*back */
  const double ray_x = (cam_dx * cam.right_x) + (cam_dy * cam.up_x) + (cam_dz * cam.back_x);
  const double ray_y = (cam_dx * cam.right_y) + (cam_dy * cam.up_y) + (cam_dz * cam.back_y);
  const double ray_z = (cam_dx * cam.right_z) + (cam_dy * cam.up_z) + (cam_dz * cam.back_z);
  /* only rays pointing DOWN hit the floor at a finite, forward point */
  if (ray_y >= -kRayDownEps) {
    return false;
  }
  const double plane_t = -cam.pos_y_m / ray_y;
  if (plane_t <= 0.0) {
    return false; /* behind the camera */
  }
  /* range gate on the TRUE ray length: |d| > 1 off-axis, so plane_t alone would gate
   * inconsistently across the frame */
  const double ray_len = std::sqrt((cam_dx * cam_dx) + (cam_dy * cam_dy) + 1.0);
  const double dist_m = plane_t * ray_len;
  if (dist_m < CARTY_FUSE_RANGE_NEAR_M || dist_m > CARTY_FUSE_RANGE_FAR_M) {
    return false;
  }
  /* grazing gate: sin(incidence) = |ray_y|/len, and ray_y < 0 here */
  if (-ray_y < CARTY_FUSE_INCIDENCE_MIN * ray_len) {
    return false;
  }
  hit->point = {cam.pos_x_m + (plane_t * ray_x), cam.pos_z_m + (plane_t * ray_z)};
  hit->dist_m = dist_m;
  return true;
}

/* Photo-map: paint the ground cell with the source pixel's real RGB, the top-down
 * evidence layer (NOT geometry; walls come from VECTORIZE). src[0..2] is RGB for both
 * 3- and 4-channel frames. A first touch sets the color; a re-observed cell EMA-blends
 * toward the sample ((old*3 + sample)/4), so coverage converges without unbounded state. */
void paint_ground_color(const CartyWorldGrid *grid, GroundCell cell, const uint8_t *src,
                        bool first_touch) {
  constexpr int kRgb = 3;
  uint8_t *dst = grid->color + (((static_cast<size_t>(cell.row) * grid->n) +
                                 static_cast<size_t>(cell.col)) *
                                kRgb);
  for (int chan = 0; chan < kRgb; ++chan) {
    dst[chan] = first_touch ? src[chan]
                            : static_cast<uint8_t>(((static_cast<int>(dst[chan]) * 3) +
                                                    static_cast<int>(src[chan])) /
                                                   4);
  }
}

int64_t splat_frame(const CartyWorldGrid *grid, const FrameView &view, const Intrinsics &lens,
                    const CamPose &cam, const GridOrigin &origin) {
  const size_t band_base = fixed_band_base(grid);
  int64_t placed = 0;
  for (int32_t v_px = 0; v_px < view.height; ++v_px) {
    for (int32_t u_px = 0; u_px < view.width; ++u_px) {
      FloorHit hit = {};
      GroundCell cell = {0, 0};
      if (!floor_hit(lens, cam, {u_px, v_px}, &hit) ||
          !ground_cell_of(grid, origin, hit.point, &cell)) {
        continue;
      }
      const size_t idx = ground_index(grid, band_base, cell);
      const int8_t prev = grid->cells[idx];
      grid->cells[idx] = clamp_log_odds(prev + range_increment(hit.dist_m));
      const uint8_t *src = view.frame->data + (((static_cast<size_t>(v_px) * view.width) +
                                                static_cast<size_t>(u_px)) *
                                               view.channels);
      paint_ground_color(grid, cell, src, prev <= 0);
      ++placed;
    }
  }
  return placed;
}

/* ---- the depth path ------------------------------------------------------- */

struct DepthView {
  const uint16_t *depth_mm;
  const uint8_t *conf;  // optional, same size
  int32_t width, height;
};
/* a world point, Y up */
struct WorldPoint {
  double x_m, y_m, z_m;
};

constexpr double kMmPerM = 1000.0;

/* Reproject one depth pixel and fold it at the band of its real world-Y. False when it
 * is a hole, off the grid, or dropped for low confidence. */
bool fold_depth_pixel(const CartyWorldGrid *grid, const DepthView &view, const Intrinsics &lens,
                      const CamPose &cam, const GridOrigin &origin, PixelPos pixel) {
  const size_t pixel_idx =
      (static_cast<size_t>(pixel.v_px) * view.width) + static_cast<size_t>(pixel.u_px);
  const uint16_t z_mm = view.depth_mm[pixel_idx];
  if (z_mm == 0) {
    return false; /* hole — never a 0 mm hit (depth recording invariant) */
  }
  const double depth_m = z_mm / kMmPerM;
  /* camera-space ray endpoint with the CV->OpenGL handedness flip */
  const double cam_x_m = (static_cast<double>(pixel.u_px) - lens.center_x_px) * depth_m / lens.focal_x_px;
  const double cam_y_m = -((static_cast<double>(pixel.v_px) - lens.center_y_px) * depth_m / lens.focal_y_px);
  const double cam_z_m = -depth_m;
  /* camera -> world: P = R*[x,y,z] + t (columns = camera basis in world) */
  const WorldPoint point = {
      cam.pos_x_m + (cam_x_m * cam.right_x) + (cam_y_m * cam.up_x) + (cam_z_m * cam.back_x),
      cam.pos_y_m + (cam_x_m * cam.right_y) + (cam_y_m * cam.up_y) + (cam_z_m * cam.back_y),
      cam.pos_z_m + (cam_x_m * cam.right_z) + (cam_y_m * cam.up_z) + (cam_z_m * cam.back_z),
  };
  GroundCell cell = {0, 0};
  if (!ground_cell_of(grid, origin, {point.x_m, point.z_m}, &cell)) {
    return false;
  }
  const int64_t band =
      static_cast<int64_t>(std::floor((point.y_m - origin.world_y_m) / grid->band_m));
  if (band < 0 || band >= grid->h) {
    return false; /* clip (bounded) */
  }
  const size_t idx = (((static_cast<size_t>(band) * grid->n) + static_cast<size_t>(cell.row)) *
                      grid->n) +
                     static_cast<size_t>(cell.col);
  CARTY_ASSERT(idx < grid->size, "computed cell index out of bounds");
  /* Fold: confidence-weighted clamped-additive log-odds (additive ISM half) PLUS
   * free-space carve along the ray (negative ISM half). No conf -> flat L_OCC and
   * NO carve (carve needs the per-pixel trust signal, parity with the no-confidence fold). Else
   * conf_to_increment gates the ray once: a DROP skips BOTH carve and hit. */
  int inc = CARTY_FUSE_L_OCC;
  if (view.conf != nullptr) {
    inc = conf_to_increment(view.conf[pixel_idx]);
    if (inc == CARTY_FUSE_CONF_DROP) {
      return false;
    }
    /* occlusion carving: carve the free space before the surface with the SAME confidence increment
     * (negated), scaled by CARVE_SCALE; hit voxel excluded */
    const int carve = static_cast<int>(std::lround(CARTY_FUSE_CARVE_SCALE * inc));
    const double inv_res = 1.0 / grid->res_m;
    const double inv_band = 1.0 / grid->band_m;
    const VoxelPoint sensor = {(cam.pos_x_m - origin.world_x_m) * inv_res,
                               (cam.pos_z_m - origin.world_z_m) * inv_res,
                               (cam.pos_y_m - origin.world_y_m) * inv_band,};
    const VoxelPoint surface = {(point.x_m - origin.world_x_m) * inv_res,
                                (point.z_m - origin.world_z_m) * inv_res,
                                (point.y_m - origin.world_y_m) * inv_band,};
    carve_ray_3d(grid, sensor, surface, {cell.col, cell.row, band}, carve);
  }
  grid->cells[idx] = clamp_log_odds(grid->cells[idx] + inc);
  return true;
}

}  // namespace

extern "C" CartyWorldGrid *carty_world_grid_create(const CartyGridShape *shape) {
  /* Boundary: bounded by construction; reject anything out of caps or non-finite
   * (crash-at-boundary, Tiger Style). */
  CARTY_ASSERT(shape != nullptr, "null grid shape at boundary");
  const int32_t cells_per_side = shape->cells_per_side;
  const int32_t height_bands = shape->height_bands;
  const double res_m = shape->res_m;
  const double band_m = shape->band_m;
  CARTY_ASSERT(cells_per_side > 0 && cells_per_side <= CARTY_GRID_MAX_N, "grid N out of range");
  CARTY_ASSERT(height_bands > 0 && height_bands <= CARTY_GRID_MAX_H, "grid H out of range");
  CARTY_ASSERT(std::isfinite(res_m) && res_m > 0.0, "res_m must be finite > 0");
  CARTY_ASSERT(std::isfinite(band_m) && band_m > 0.0, "band_m must be finite > 0");

  CartyWorldGrid *grid =
      static_cast<CartyWorldGrid *>(std::malloc(sizeof(CartyWorldGrid)));
  CARTY_ASSERT(grid != nullptr, "world grid handle allocation failed");

  const size_t cell_count = static_cast<size_t>(cells_per_side) * static_cast<size_t>(cells_per_side) *
                            static_cast<size_t>(height_bands);
  grid->cells = static_cast<int8_t *>(std::calloc(cell_count, 1));
  CARTY_ASSERT(grid->cells != nullptr, "world grid cell allocation failed");

  /* One RGB triple per GROUND cell (floor band only) — the top-down photo-map.
   * Zeroed: unobserved cells read as black until the splat paints real color. */
  const size_t color_count = static_cast<size_t>(cells_per_side) * static_cast<size_t>(cells_per_side) * 3;
  grid->color = static_cast<uint8_t *>(std::calloc(color_count, 1));
  CARTY_ASSERT(grid->color != nullptr, "world grid color allocation failed");

  grid->n = cells_per_side;
  grid->h = height_bands;
  grid->res_m = res_m;
  grid->band_m = band_m;
  grid->origin_x = 0.0;
  grid->origin_y = 0.0;
  grid->origin_z = 0.0;
  grid->anchored = 0;
  grid->size = cell_count;
  grid->seen_count = 0;
  /* seen_ids left uninitialised on purpose: only [0, seen_count) is ever read. */

  CARTY_ASSERT(grid->size == cell_count && grid->anchored == 0,
               "world grid invariant violated at create");
  return grid;
}

extern "C" void carty_world_grid_free(CartyWorldGrid *grid) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(grid->cells != nullptr, "double free or corrupt world grid");
  CARTY_ASSERT(grid->color != nullptr, "double free or corrupt world grid color");
  std::free(grid->cells);
  std::free(grid->color);
  /* Poison the handle so a use-after-free trips an assert instead of UB. */
  grid->cells = nullptr;
  grid->color = nullptr;
  grid->size = 0;
  grid->n = 0;
  grid->h = 0;
  grid->seen_count = 0;
  grid->anchored = 0;
  std::free(grid);
}

extern "C" int32_t carty_world_grid_n(const CartyWorldGrid *grid) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(grid->n > 0, "world grid has non-positive N");
  return grid->n;
}

extern "C" int32_t carty_world_grid_h(const CartyWorldGrid *grid) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(grid->h > 0, "world grid has non-positive H");
  return grid->h;
}

extern "C" size_t carty_world_grid_size(const CartyWorldGrid *grid) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(grid->size > 0, "world grid has zero size");
  return grid->size;
}

extern "C" const int8_t *carty_world_grid_cells(const CartyWorldGrid *grid) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(grid->cells != nullptr, "world grid has null cells");
  return grid->cells;
}

extern "C" const uint8_t *carty_world_grid_color(const CartyWorldGrid *grid) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(grid->color != nullptr, "world grid has null color");
  return grid->color;
}

extern "C" void carty_world_grid_origin(const CartyWorldGrid *grid,
                                        double *origin_x, double *origin_y,
                                        double *origin_z, int *anchored) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(origin_x != nullptr && origin_y != nullptr &&
                   origin_z != nullptr && anchored != nullptr,
               "null origin out-pointer at boundary");
  *origin_x = grid->origin_x;
  *origin_y = grid->origin_y;
  *origin_z = grid->origin_z;
  *anchored = grid->anchored;
}

extern "C" void carty_world_grid_resolution(const CartyWorldGrid *grid,
                                            double *res_m, double *band_m) {
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(res_m != nullptr && band_m != nullptr,
               "null resolution out-pointer at boundary");
  *res_m = grid->res_m;
  *band_m = grid->band_m;
}

extern "C" int32_t carty_world_grid_accrete(CartyWorldGrid *grid,
                                            const CartyOrthoMap *observation,
                                            const CartyPose *pose, int64_t keyframe_id) {
  /* 1. Boundary asserts (crash-at-boundary, Tiger Style). */
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(observation != nullptr, "null observation handle at boundary");
  CARTY_ASSERT(grid->cells != nullptr, "corrupt world grid (null cells)");
  CARTY_ASSERT(observation->cells != nullptr, "corrupt observation (null cells)");
  CARTY_ASSERT(grid->seen_count >= 0 && grid->seen_count <= CARTY_GRID_SEEN_MAX,
               "world grid seen-id count out of range (corrupt)");
  const CamPose cam = read_pose(pose);

  /* 2. Dedup and segment-full: both leave the grid untouched. */
  const int32_t refused = refuse_keyframe(grid, keyframe_id);
  if (refused != CARTY_FUSE_OK) {
    return refused;
  }
  /* 3. Prospective anchor, 4-5. register + fold, 6-7. commit. */
  const GridOrigin origin = prospective_origin(grid, cam);
  const int64_t placed = fold_observation(grid, observation, cam, origin);
  return commit_fold(grid, placed, origin, keyframe_id);
}

/* THE METRIC PATH (full extrinsic back-projection).
 * carty_world_grid_accrete above registers an ALREADY-orthorectified observation
 * using yaw + horizontal translation only, one fixed band, and the fixed-pose
 * scale baked into carty_ortho_project — so during a live walk it visibly smears.
 * This entry point is the fix: it back-projects the RAW frame's pixels through the
 * real intrinsics K and the FULL 4x4 cam->world pose (pitch AND roll included, plus
 * the real metric translation), intersects each ray with the ground plane, and
 * folds the hit cells with the SAME clamped-additive log-odds + dedup(keyframe_id)
 * + first-contributing-keyframe anchor + seen-table machinery as accrete. K
 * RE-ENTERS HERE — it was deliberately absent from accrete (the ortho map already
 * consumed it); a raw-frame splat is the one place a second K is real
 * geometry, not dead surface. Depth is still deferred, so every hit folds into the
 * same single fixed band (the camera-height level h/2); true height-banding arrives
 * with a depth source. As an interim guard against that single-band smear, hits are
 * dropped when their metric ray distance falls outside [CARTY_FUSE_RANGE_NEAR_M,
 * CARTY_FUSE_RANGE_FAR_M] or strike the floor below CARTY_FUSE_INCIDENCE_MIN grazing
 * angle — STOPGAP gates, explicitly NOT the depth path, retired once
 * depth banding lands. The ground plane is ARCore's world Y=0 floor plane.
 *
 * Camera model (matches build_pose / ARCore): the camera looks down its -Z axis,
 * +X right, +Y up. A pixel (u,v) (v DOWN in image space) back-projects to the
 * camera-space ray direction ((u-cx)/fx, -(v-cy)/fy, -1); the cam->world rotation
 * (the pose's upper-left 3x3, columns = camera basis in world) carries it to a
 * world ray from the camera world position (the pose's 4th column). */
extern "C" int32_t carty_world_grid_accrete_from_frame(
    CartyWorldGrid *grid, const CartyFrame *frame, int32_t width, int32_t height,
    int32_t channels, const CartyIntrinsics *intrinsics, const CartyPose *pose,
    int64_t keyframe_id) {
  /* 1. Boundary asserts (crash-at-boundary, Tiger Style). */
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(frame != nullptr, "null frame handle at boundary");
  CARTY_ASSERT(frame->data != nullptr, "corrupt frame (null data)");
  CARTY_ASSERT(grid->cells != nullptr, "corrupt world grid (null cells)");
  CARTY_ASSERT(grid->seen_count >= 0 && grid->seen_count <= CARTY_GRID_SEEN_MAX,
               "world grid seen-id count out of range (corrupt)");
  CARTY_ASSERT(width > 0 && width <= CARTY_FRAME_MAX_DIM, "frame width out of range");
  CARTY_ASSERT(height > 0 && height <= CARTY_FRAME_MAX_DIM,
               "frame height out of range");
  CARTY_ASSERT(channels == 3 || channels == 4, "channels must be 3 (RGB) or 4 (RGBA)");
  const size_t expect = static_cast<size_t>(width) * static_cast<size_t>(height) *
                        static_cast<size_t>(channels);
  CARTY_ASSERT(frame->size == expect, "pixel dims do not match frame size");
  const CamPose cam = read_pose(pose);
  const Intrinsics lens = read_intrinsics(intrinsics);

  /* 2. Dedup and segment-full, shared contract. */
  const int32_t refused = refuse_keyframe(grid, keyframe_id);
  if (refused != CARTY_FUSE_OK) {
    return refused;
  }
  /* 3. Prospective anchor, 4. back-project + fold, 6-7. commit. */
  const GridOrigin origin = prospective_origin(grid, cam);
  const int64_t placed =
      splat_frame(grid, {frame, width, height, channels}, lens, cam, origin);
  return commit_fold(grid, placed, origin, keyframe_id);
}

/* THE DEPTH PATH (depth reprojection). See header for the full contract.
 * Mirrors accrete_from_frame's skeleton (dedup + anchor + seen-table + bounds), but
 * the geometry core travels the MEASURED depth Z down each ray instead of
 * intersecting the ground plane, and folds at the band of the real world-Y. No
 * color write (depth has no pixels) and no near/far/incidence STOPGAP gates (those
 * exist only because the frame path lacks depth and folds one band; depth has real
 * bands, so their absence is correct). */
extern "C" int32_t carty_world_grid_accrete_from_depth(
    CartyWorldGrid *grid, const uint16_t *depth, int32_t depth_width, int32_t depth_height,
    const uint8_t *conf, const CartyIntrinsics *intrinsics, const CartyPose *pose,
    int64_t keyframe_id) {
  /* 1. Boundary asserts (crash-at-boundary, Tiger Style). */
  CARTY_ASSERT(grid != nullptr, "null world grid handle at boundary");
  CARTY_ASSERT(depth != nullptr, "null depth buffer at boundary");
  CARTY_ASSERT(grid->cells != nullptr, "corrupt world grid (null cells)");
  CARTY_ASSERT(grid->seen_count >= 0 && grid->seen_count <= CARTY_GRID_SEEN_MAX,
               "world grid seen-id count out of range (corrupt)");
  CARTY_ASSERT(depth_width > 0 && depth_width <= CARTY_FRAME_MAX_DIM,
               "depth width out of range");
  CARTY_ASSERT(depth_height > 0 && depth_height <= CARTY_FRAME_MAX_DIM,
               "depth height out of range");
  const CamPose cam = read_pose(pose);
  const Intrinsics lens = read_intrinsics(intrinsics);

  /* 2. Dedup and segment-full, shared contract. */
  const int32_t refused = refuse_keyframe(grid, keyframe_id);
  if (refused != CARTY_FUSE_OK) {
    return refused;
  }
  /* 3. Prospective anchor. */
  const GridOrigin origin = prospective_origin(grid, cam);

  /* 4. Reproject every non-hole pixel, fold at its real-Y band, clip to bounds. */
  const DepthView view = {depth, conf, depth_width, depth_height};
  int64_t placed = 0;
  for (int32_t v_px = 0; v_px < depth_height; ++v_px) {
    for (int32_t u_px = 0; u_px < depth_width; ++u_px) {
      if (fold_depth_pixel(grid, view, lens, cam, origin, {u_px, v_px})) {
        ++placed;
      }
    }
  }
  /* 6-7. commit */
  return commit_fold(grid, placed, origin, keyframe_id);
}
