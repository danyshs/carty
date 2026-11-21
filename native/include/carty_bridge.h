/*
 * carty_bridge.h — C ABI for the Carty native bridge.
 *
 * This is the ONLY surface Dart (dart:ffi) is allowed to call.
 * It is intentionally small: it passes opaque handles + raw byte buffers, never
 * rich objects. The bridge — and only the bridge — will later link LiteRT.
 *
 * Tiger Style:
 *   - Every function asserts its preconditions and postconditions.
 *   - The boundary crashes immediately on a null/invalid handle; it never
 *     degrades silently or passes a nullptr inward.
 *   - Buffers are bounded by construction (see CARTY_FRAME_MAX_*).
 *
 * Ownership contract (the memory strategy this task establishes):
 *   - A CartyFrame's pixel buffer is allocated and owned by the BRIDGE.
 *   - carty_frame_data() hands Dart a *borrowed* pointer into that buffer.
 *     Dart may wrap it with Pointer.asTypedList for ZERO-COPY access, but must
 *     not free it or use it after carty_frame_free().
 *   - Exactly one carty_frame_free() must run per carty_frame_alloc(). On the
 *     Dart side this is guaranteed by a NativeFinalizer bound to
 *     carty_frame_free, plus an explicit dispose() for deterministic release.
 */
#ifndef CARTY_BRIDGE_H_
#define CARTY_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Semantic version of the bridge ABI. Returns a pointer to a static,
 * NUL-terminated string the caller must NOT free. Never returns NULL. */
const char *carty_version(void);

/* ---- Frame buffers (bridge-owned, the multi-MB video frame surface) ---- */

/* Opaque handle to a heap-allocated, bridge-owned byte frame buffer. */
typedef struct CartyFrame CartyFrame;

/* Hard upper bounds — Tiger Style "bounded by construction". A 4K RGBA frame
 * (3840*2160*4 ≈ 33 MB) sits comfortably inside these limits. */
#define CARTY_FRAME_MAX_DIM 8192
#define CARTY_FRAME_MAX_CHANNELS 4

/* Allocate a zero-initialised frame buffer of width*height*channels bytes.
 * Aborts (crash-at-boundary) on non-positive or out-of-bounds dimensions.
 * Never returns NULL — on success the handle owns a valid buffer. */
CartyFrame *carty_frame_alloc(int32_t width, int32_t height, int32_t channels);

/* Borrowed, mutable pointer into the owned pixel buffer. Valid until
 * carty_frame_free(frame). Aborts if frame is NULL. Never returns NULL. */
uint8_t *carty_frame_data(CartyFrame  const*frame);

/* Size of the owned buffer, in bytes. Aborts if frame is NULL. */
size_t carty_frame_size(const CartyFrame *frame);

/* Release a frame returned by carty_frame_alloc(). Aborts if frame is NULL.
 * After this call the handle is dangling and must never be reused. */
void carty_frame_free(CartyFrame *frame);

/* ---- LiteRT Gemma 4 E2B Inference (loaded via LiteRT C++) ---- */

/* Opaque handle to a loaded Gemma 4 E2B engine (the resident LiteRtLmEngine). */
typedef struct CartyModel CartyModel;

/* Open a session-scoped model handle for the Gemma 4 E2B weights at the given
 * file path. When LiteRT is linked (CARTY_HAVE_LITERT), this loads the engine
 * ONCE and holds it RESIDENT for the whole session — decode then runs in-process
 * with no subprocess (Route 1). The load is
 * DELIBERATELY tolerant: it does NOT validate that the file exists or can be
 * loaded, and does NOT abort on a load failure — a failed/absent load leaves a
 * degraded handle whose decode safe-fails CARTY_INFER_ENOMODEL (never fabricates).
 * ABORTS only if path is NULL or empty (crash-at-boundary, Tiger Style). Never
 * returns NULL on success; free (and release the resident engine) with
 * carty_model_free(). */
CartyModel *carty_model_load(const char *model_path);

/* Release a model returned by carty_model_load(). Aborts if model is NULL.
 * After this call the handle is dangling and must never be reused. */
void carty_model_free(CartyModel *model);

/* ---- Multimodal structured inference + output validation -------- */
/*
 * This contract turns the raw Gemma 4 E2B path into a *structured* one:
 * the model is steered to emit a strict "map-update" JSON document, and the
 * bridge gives the boundary two guarantees Tiger Style requires:
 *
 *   1. NULL handles/buffers ABORT immediately (crash-at-boundary).
 *   2. A malformed model OUTPUT is *data*, not a corrupt boundary — it must
 *      FAIL SAFELY (a negative status), never abort and never be applied.
 *
 * The authoritative schema-strict parse lives in Dart (lib/inference), since the
 * version-control engine that consumes it is pure Dart. The Dart
 * parser (MapUpdate.parse / _extractJsonObject) is the SOLE extraction semantics
 * — the bridge no longer ships a native structural pre-gate (it duplicated
 * the Dart parser and had to be kept in sync).
 */

/* Map-update output bounds (Tiger Style: bounded by construction). */
#define CARTY_MAP_UPDATE_MAX (64 * 1024) /* model output ceiling, bytes */
#define CARTY_MAP_UPDATE_MAX_DEPTH 32    /* JSON nesting ceiling */

/* Inference status (negative == safe failure; >= 0 == bytes written incl NUL). */
#define CARTY_INFER_ENOMODEL (-100) /* LiteRT not linked / weights unavailable */
#define CARTY_INFER_ENOSPACE (-101) /* output buffer too small for the result */

/* Run a multimodal, structured inference: feed an image segment (NHWC uint8
 * frame), a text instruction, and a normalized spatial region of interest
 * [bx0,by0]-[bx1,by1] to Gemma 4 E2B, and write a strict map-update JSON
 * document into output_buf. On success returns the byte count written
 * (including NUL); on a recoverable condition returns a negative CARTY_INFER_*
 * status (e.g. ENOMODEL when LiteRT is not yet linked). ABORTS only on a NULL
 * handle/buffer or non-positive buffer size (crash-at-boundary). Bounds must be
 * finite, in [0,1], and ordered (bx0<=bx1, by0<=by1) — a precondition. */
int32_t carty_infer_map_update(CartyModel  const*model, CartyFrame  const*image_segment,
                               const char *text_prompt, float bx0, float by0,
                               float bx1, float by1, char *output_buf,
                               int32_t output_buf_size);

/* ---- Geometric-Semantic pipeline: orthorectification ---- */
/*
 * The Geometric-Semantic pipeline inserts a deterministic GEOMETRY stage between
 * the raw RGBA video frames and the semantic (LiteRT) stage. A raw frame is an
 * oblique, perspective view of the floor; before any inference reasons about
 * spatial layout we orthorectify it into a TOP-DOWN occupancy grid — the
 * `CartyOrthoMap` — so that a pixel's grid coordinate is a stable metric position
 * on the ground plane, independent of where the camera was held.
 *
 *   raw RGBA frame ──carty_ortho_project──> CartyOrthoMap (top-down occupancy)
 *                                            └─> later fused into the node graph
 *
 * The transform is a planar (ground-plane Z=0) homography built from CALIBRATED
 * CAMERA INTRINSICS K (focal length + principal point) and a fixed extrinsic pose
 * (camera height + downward pitch). The ortho footprint is chosen as the
 * back-projection of the image corners onto the ground, so the whole visible
 * floor is captured. The math is closed-form and allocation-bounded; the same
 * homography drives cv::warpPerspective when OpenCV is linked (CARTY_HAVE_OPENCV)
 * and a hand-rolled inverse-map sampler otherwise — both are byte-deterministic.
 *
 * Tiger Style: NULL/oversized inputs ABORT at the boundary; the
 * grid is bounded by construction (CARTY_ORTHO_MAX_DIM); every CartyOrthoMap is
 * heap-owned and released exactly once by carty_ortho_map_free().
 */

/* Top-down occupancy grid edge ceiling (Tiger Style: bounded by construction). */
#define CARTY_ORTHO_DIM 256          /* fixed square ortho grid resolution */
#define CARTY_ORTHO_MAX_DIM 1024     /* hard upper bound on either grid edge  */

/* Opaque handle to a bridge-owned top-down occupancy grid. Each cell is one
 * uint8 occupancy/observation value: 0 == unobserved ground (outside the warped
 * footprint), >0 == observed ground intensity at that metric position. */
typedef struct CartyOrthoMap CartyOrthoMap;

/* Orthorectify one raw frame (NHWC uint8, `channels` of 3=RGB or 4=RGBA) of the
 * given pixel dimensions into a freshly-allocated top-down CartyOrthoMap using
 * calibrated camera intrinsics. Returns a caller-owned handle (free with
 * carty_ortho_map_free); never returns NULL on success.
 *
 * The frame's pixel dimensions are NOT carried by CartyFrame (it is a sized byte
 * buffer), so they are passed explicitly and MUST satisfy
 * width*height*channels == carty_frame_size(buffer) — a precondition. ABORTS on a
 * NULL/invalid buffer, non-positive or out-of-bounds dims, or a size mismatch
 * (crash-at-boundary, Tiger Style). */
CartyOrthoMap *carty_ortho_project(CartyFrame  const*buffer, int32_t width,
                                   int32_t height, int32_t channels);

/* Grid dimensions of an ortho map. Abort if map is NULL. */
int32_t carty_ortho_map_width(const CartyOrthoMap *map);
int32_t carty_ortho_map_height(const CartyOrthoMap *map);

/* Borrowed, read-only pointer to the row-major occupancy grid
 * (width*height bytes). Valid until carty_ortho_map_free(map). Abort if map is
 * NULL. Never returns NULL. */
const uint8_t *carty_ortho_map_cells(const CartyOrthoMap *map);

/* Size of the occupancy grid in bytes (== width*height). Abort if map is NULL. */
size_t carty_ortho_map_size(const CartyOrthoMap *map);

/* World-metric footprint of the ortho map's camera-LOCAL ground frame: the
 * bounding box of the four image corners back-projected onto the ground plane
 * (carty_ortho.cpp). carty_ortho_project computes this extent and would otherwise
 * discard it; fusion needs it to recover each observed cell's real-world position,
 * so it is exposed here (additive, no ABI break for existing callers).
 *
 * The local frame is +x right, +y forward; ortho row oy=0 is the FAR edge (ymax).
 * The x and y metres-per-cell DIFFER (the footprint is a trapezoid's bbox), so the
 * full extent is exposed rather than a single cell size. A caller recovers a cell's
 * local metric position as:
 *   lx = min_x + ox * (max_x - min_x)/(width  - 1)
 *   ly = max_y - oy * (max_y - min_y)/(height - 1)   (row 0 = far)
 * Aborts on a NULL map or any NULL out-pointer (crash-at-boundary). */
void carty_ortho_map_extent(const CartyOrthoMap *map, double *min_x, double *max_x,
                            double *min_y, double *max_y);

/* Release an ortho map returned by carty_ortho_project(). Aborts if map is NULL.
 * After this call the handle is dangling and must never be reused. */
void carty_ortho_map_free(CartyOrthoMap *map);

/* ---- World-frame voxel-column fusion ----------- */
/*
 * carty_ortho_project gives a camera-LOCAL top-down occupancy grid under a FIXED
 * assumed pose — nothing registers frame N to frame N+1, so a map cannot accrete.
 * The Fusion stage builds the missing world accumulator: a bounded 2.5D
 * voxel-column occupancy grid that folds a pose-stamped keyframe's observation
 * into ONE world-anchored grid across calls, with a bounded log-odds update that
 * is monotonic in evidence and idempotent under a repeated keyframe.
 *
 *   CartyOrthoMap + 4x4 cam->world pose ──carty_world_grid_accrete──▶ CartyWorldGrid
 *
 * ONE grid == ONE capture segment. Venue-scale (e.g. the Toronto PATH) is reached
 * by stitching many segments' vectorized MapGraphs via the VC engine, NOT by one
 * in-memory grid — so this grid only need expose its world origin
 * + resolution (the stitching precondition).
 *
 * Coordinate convention (ARCore world is right-handed, Y-UP):
 *   - the grid's two GROUND axes (cell gx, gy) map to world horizontal X and Z;
 *   - the grid's BAND axis maps to world-up Y;
 *   - origin_{x,y,z} are the WORLD coordinates at cell (gx=0, gy=0, band=0):
 *     origin_x<-world X, origin_y<-world Z, origin_z<-world Y (height).
 * Fixing this axis map here is load-bearing — the Y-up/Z-up confusion silently
 * breaks fusion.
 *
 * SCOPE OF THIS INCREMENT (honest caveat): accretion registers the
 * already-orthorectified observation using ONLY the pose's horizontal translation
 * + yaw (heading), folds into a single fixed band (the camera-height level, not
 * the geometric floor; depth deferred), and inherits the fixed-pose metric scale
 * of carty_ortho_project. Full pitch/roll,
 * true height-banding from depth, and real metric scale arrive with a future
 * raw-frame splat. There is deliberately NO intrinsics (K) argument: the
 * observation is a CartyOrthoMap that already consumed K; a second K
 * would be dead FFI surface with no precondition to assert.
 *
 * Tiger Style: dims are bounded by construction (CARTY_GRID_MAX_*);
 * NULL/non-finite inputs ABORT at the boundary; a far-off-grid observation is data
 * (a non-fatal status), not a corrupt boundary.
 */

/* Grid defaults + hard caps (Tiger Style: bounded by construction). The default
 * is sized to one capture segment (51.2 m span / 16 MiB at H=16); the device's
 * resident model already holds ~2.44 GiB, so a generous segment grid is noise. */
#define CARTY_GRID_N        1024  /* default ground cells per side */
#define CARTY_GRID_H        16    /* default height bands */
#define CARTY_GRID_MAX_N    2048  /* hard cap on N (102.4 m at 5 cm) */
#define CARTY_GRID_MAX_H    64    /* hard cap on H */
#define CARTY_GRID_SEEN_MAX 8192  /* hard cap on incorporated keyframes/segment */
#define CARTY_POSE_LEN       16   /* 4x4 row-major cam->world pose */

/* Typed geometry, so a swapped argument is a compile error rather than an
 * out-of-bounds read: a bare double* pose and K looked the same to the compiler. */

/* 4x4 ROW-MAJOR camera->world extrinsic, translation in the 4th column (ARCore) */
typedef struct CartyPose {
  double cam_to_world[CARTY_POSE_LEN];
} CartyPose;

/* pinhole K in pixels, at the resolution of the image it describes */
typedef struct CartyIntrinsics {
  double fx_px;
  double fy_px;
  double cx_px;
  double cy_px;
} CartyIntrinsics;

/* world-grid dimensions; caps are CARTY_GRID_MAX_N / CARTY_GRID_MAX_H */
typedef struct CartyGridShape {
  int32_t cells_per_side;
  int32_t height_bands;
  double res_m;  /* metres per ground cell */
  double band_m; /* metres per height band */
} CartyGridShape;

/* accrete status: >= 0 OK; otherwise a safe, non-fatal condition. */
#define CARTY_FUSE_OK            0  /* observation folded in */
#define CARTY_FUSE_DUPLICATE     1  /* keyframe_id already incorporated: no-op */
#define CARTY_FUSE_OUT_OF_BOUNDS 2  /* observation fell entirely off the grid */
#define CARTY_FUSE_SEEN_FULL     3  /* segment full (SEEN_MAX keyframes): no-op,
                                     * the signal to start a new segment */

/* Opaque handle to a persistent, world-anchored 2.5D voxel-column grid for ONE
 * capture segment. Each cell is one int8 log-odds of OBSERVATION / COVERAGE
 * evidence ("a keyframe saw this ground cell"), NOT wall-vs-floor occupancy —
 * that classification is a later vectorize/depth concern. 0 == unobserved. */
typedef struct CartyWorldGrid CartyWorldGrid;

/* Create a zeroed (all-unobserved) world grid for ONE capture segment, sized by
 * `shape`. ABORTS on a NULL shape, non-positive or out-of-cap dims
 * (cells_per_side>CARTY_GRID_MAX_N, height_bands>CARTY_GRID_MAX_H) or
 * non-finite/non-positive resolutions (crash-at-boundary).
 * Never returns NULL on success; free with carty_world_grid_free. The origin is
 * UNSET (anchored==0) until the first accrete anchors it on the first camera. */
CartyWorldGrid *carty_world_grid_create(const CartyGridShape *shape);

/* Release a grid returned by carty_world_grid_create(). Aborts if grid is NULL.
 * After this call the handle is dangling and must never be reused. */
void carty_world_grid_free(CartyWorldGrid *grid);

/* Grid dimensions. Abort if grid is NULL. */
int32_t carty_world_grid_n(const CartyWorldGrid *grid);
int32_t carty_world_grid_h(const CartyWorldGrid *grid);

/* Size of the log-odds volume in bytes (== n*n*h). Abort if grid is NULL. */
size_t carty_world_grid_size(const CartyWorldGrid *grid);

/* Borrowed, read-only pointer to the row-major (band-major: idx=(band*n+gy)*n+gx)
 * int8 log-odds volume (n*n*h bytes). Valid until carty_world_grid_free(grid).
 * Abort if grid is NULL. Never returns NULL. */
const int8_t *carty_world_grid_cells(const CartyWorldGrid *grid);

/* Borrowed, read-only pointer to the n*n*3 row-major RGB photo-map of the floor
 * band: the real camera color each GROUND cell was observed with (top-down
 * evidence layer, NOT the D&D map — walls/rooms come from VECTORIZE), 0 where
 * unobserved. Indexed (gy*n+gx)*3 + {0:R,1:G,2:B}. Populated ONLY by the
 * raw-frame splat (carty_world_grid_accrete_from_frame) — the one path with
 * pixels. Valid until carty_world_grid_free(grid). Abort if grid is NULL.
 * Never returns NULL. */
const uint8_t *carty_world_grid_color(const CartyWorldGrid *grid);

/* World placement of the grid — required to place fused cells in the segment's
 * world frame for vectorize + cross-segment stitching (cross-segment stitching). Writes the world
 * coordinates of cell (0,0,band0) and sets *anchored (0 until the first accrete
 * sets the origin). Aborts on a NULL grid or any NULL out-pointer. */
void carty_world_grid_origin(const CartyWorldGrid *grid, double *origin_x,
                             double *origin_y, double *origin_z, int *anchored);

/* Writes the grid's metric cell + band sizes. Aborts on NULL grid/out-pointer. */
void carty_world_grid_resolution(const CartyWorldGrid *grid, double *res_m,
                                 double *band_m);

/* Register ONE keyframe's top-down observation into the persistent world grid at
 * the given world pose. `observation` is a camera-local top-down occupancy grid
 * from carty_ortho_project; `pose` is the 4x4 ROW-MAJOR camera->world extrinsic
 * (ARCore, translation in the 4th column); `keyframe_id` is a stable per-keyframe
 * key (e.g. the pose-sidecar timestamp). See the convention + scope caveat above.
 *
 * Returns CARTY_FUSE_OK on a fold, CARTY_FUSE_DUPLICATE if keyframe_id was already
 * incorporated (grid byte-for-byte untouched — literal idempotency),
 * CARTY_FUSE_OUT_OF_BOUNDS if the observation lands entirely outside the bounded
 * grid (grid untouched, no out-of-bounds write), or CARTY_FUSE_SEEN_FULL if the
 * segment already holds CARTY_GRID_SEEN_MAX keyframes (grid untouched — this is the
 * expected, NON-fatal signal to start a new segment, NOT a crash).
 * ABORTS only on a NULL grid/observation/pose, a non-finite pose entry, or a
 * corrupt grid invariant (crash-at-boundary, Tiger Style). */
int32_t carty_world_grid_accrete(CartyWorldGrid *grid,
                                 const CartyOrthoMap *observation,
                                 const CartyPose *pose, int64_t keyframe_id);

/* THE METRIC PATH (the fusion stage). Splat a RAW frame's pixels
 * directly onto the world grid using FULL ARCore extrinsics (pitch AND roll + real
 * metric translation) and the calibrated `intrinsics` K = {fx,fy,cx,cy}, so the
 * placement is metrically correct — this resolves the fixed-pose scale, yaw-only,
 * single-band deferrals of carty_world_grid_accrete (which folds an ALREADY-K'd
 * ortho map and visibly smears during a live walk). K RE-ENTERS HERE: it was
 * deliberately absent from accrete (the ortho map already consumed it), but a
 * raw-frame back-projection is the one place a second K is real geometry.
 *
 * `frame` is an NHWC uint8 buffer of `width`x`height`x`channels` (3=RGB or 4=RGBA);
 * `intrinsics` is the pinhole K; `pose` is the 4x4 ROW-MAJOR camera->world extrinsic
 * (translation in the 4th column); `keyframe_id` is the stable dedup key. Each pixel
 * is back-projected through K and the full pose to a world ray and intersected with
 * the ARCore ground plane (world Y=0); the hit folds with the SAME clamped-additive
 * log-odds + dedup + anchor + seen-table contract as carty_world_grid_accrete.
 *
 * Depth is still deferred, so every hit folds into a single fixed band (the
 * camera-height level); true height-banding arrives with a depth source.
 *
 * Returns CARTY_FUSE_OK / _DUPLICATE / _OUT_OF_BOUNDS / _SEEN_FULL exactly as
 * carty_world_grid_accrete. ABORTS on a NULL grid/frame/K/pose, a non-finite pose
 * or K entry, non-positive/out-of-bounds dims, or width*height*channels !=
 * frame size (crash-at-boundary, Tiger Style). */
int32_t carty_world_grid_accrete_from_frame(CartyWorldGrid *grid,
                                            const CartyFrame *frame, int32_t width,
                                            int32_t height, int32_t channels,
                                            const CartyIntrinsics *intrinsics,
                                            const CartyPose *pose, int64_t keyframe_id);

/* THE DEPTH PATH (depth reprojection). The depth-aware sibling of
 * carty_world_grid_accrete_from_frame: instead of intersecting each pixel ray
 * with the ground plane (which forces every pixel onto the floor band and smears
 * the floor behind a wall), it travels the MEASURED depth Z down the ray and
 * folds the hit at the band of its real world-Y. This is the geometry core of the
 * depth keystone; it does NOT yet carve occlusion. confidence weighting weights the fold by `conf`.
 *
 * `depth` is a row-major uint16 buffer of `depth_width`x`depth_height` raw millimetres (little-endian
 * on read; 0 = hole, skipped — never a 0 mm hit). `conf` is an OPTIONAL uint8 0–255
 * confidence plane of the SAME size (ARCore guarantees matched sizes; 0 = hole in
 * both). When NULL, the fold is flat CARTY_FUSE_L_OCC (the no-confidence behaviour). When present, a
 * pixel below CARTY_FUSE_CONF_MIN is dropped and the rest fold a confidence-scaled
 * log-odds increment. `intrinsics` is the depth-camera pinhole K ALREADY
 * SCALED to the depth size. `pose` is the 4x4 ROW-MAJOR cam->world extrinsic of the PHYSICAL
 * SENSOR (s*), NOT the display-oriented pose — sensor-native depth through a display
 * pose shears. `keyframe_id` is the stable dedup key. Each non-hole pixel (u,v,Z)
 * back-projects camera-space with the CV->OpenGL handedness flip Xc=(u-cx)Z/fx,
 * Yc=-(v-cy)Z/fy, Zc=-Z, maps to world via the full pose, and folds with the SAME
 * clamped-additive log-odds + dedup + first-contributing-keyframe anchor + seen-table
 * contract as the sibling paths. Hits whose world X/Z/Y fall outside the bounded grid
 * are CLIPPED (dropped), not clamped. Writes occupancy (cells) only — no color/photo-map
 * (depth has no color).
 *
 * Returns CARTY_FUSE_OK / _DUPLICATE / _OUT_OF_BOUNDS / _SEEN_FULL exactly as
 * carty_world_grid_accrete_from_frame. ABORTS on a NULL grid/depth/K/pose, a
 * non-finite pose or K entry, fx/fy <= 0, or out-of-range dims (crash-at-boundary,
 * Tiger Style). */
int32_t carty_world_grid_accrete_from_depth(CartyWorldGrid *grid,
                                            const uint16_t *depth, int32_t depth_width,
                                            int32_t depth_height, const uint8_t *conf,
                                            const CartyIntrinsics *intrinsics,
                                            const CartyPose *pose, int64_t keyframe_id);

/* ---- Geometric→Semantic fusion -------------------------------- */
/*
 * These two symbols are ADDITIVE: they wire the top-down CartyOrthoMap into the
 * semantic (LiteRT) stage WITHOUT changing the frozen carty_infer_map_update
 * signature (FFI stability — the Dart bindings + callers are unaffected).
 *
 * The host LiteRT-LM runtime is text-only today, so the
 * occupancy grid conditions the decode as TEXT: the caller-supplied cartographic
 * instruction (the "Spatial Context" preamble) plus a bounded, deterministic
 * coarse summary of the grid. When a true multimodal image path lands, the grid
 * can be fed as pixels instead — but the fusion API above it stays the same.
 *
 * SINGLE SOURCE OF THE OUTPUT CONTRACT: the strict
 * {"ops":[...]} schema text is OWNED BY DART (kMapUpdateSchemaContract in
 * lib/inference/prompt.dart) and passed DOWN through these two symbols as the
 * `instruction` argument. The bridge keeps NO copy of the contract — that is why
 * `instruction`/`instruction_len` exist here. The bridge only appends the bounded
 * grid summary after the instruction.
 */

/* Upper bound on the serialized Spatial Context prompt (Tiger Style: bounded). */
#define CARTY_SPATIAL_PROMPT_MAX 4096

/* Serialize a CartyOrthoMap into the caller-supplied cartographic `instruction`
 * (the strict output contract, length `instruction_len`, NUL not required)
 * followed by a bounded, DETERMINISTIC coarse occupancy summary (grid dimensions,
 * observed fraction, and a fixed-resolution downsample of the occupancy grid).
 * Writes a NUL-terminated string into out_buf and returns the byte count written
 * (including NUL). Returns CARTY_INFER_ENOSPACE (leaving out_buf defined-empty)
 * if the buffer cannot hold the result. ABORTS on a NULL map/buffer/instruction,
 * non-positive size, or negative instruction_len (crash-at-boundary). The output
 * is byte-identical for a given grid + instruction across runs — stable spatial
 * conditioning. The instruction is Dart-owned (kMapUpdateSchemaContract), so the
 * bridge holds no copy of the {"ops":[...]} contract. */
int32_t carty_ortho_to_spatial_prompt(const CartyOrthoMap *map,
                                      const char *instruction,
                                      int32_t instruction_len, char *out_buf,
                                      int32_t out_buf_size);

/* Run a structured map-update inference CONDITIONED ON the top-down occupancy
 * grid: build the Spatial Context prompt from `map` + the caller-supplied
 * `instruction` (carty_ortho_to_spatial_prompt) and drive Gemma 4 E2B, writing a
 * strict map-update JSON document (the {"ops":[...]} contract Dart's lib/inference
 * parses) into output_buf. On success returns bytes written (incl NUL); on a
 * recoverable condition returns a negative CARTY_INFER_* status — ENOMODEL when
 * LiteRT is not linked / the runtime is not configured (honest safe-fail, never a
 * fabricated map). ABORTS only on a NULL handle/buffer/instruction, non-positive
 * size, or negative instruction_len. The instruction is Dart-owned
 * (kMapUpdateSchemaContract); the bridge keeps no copy of the contract. */
int32_t carty_infer_map_update_ortho(CartyModel  const*model, const CartyOrthoMap *map,
                                     const char *instruction,
                                     int32_t instruction_len, char *output_buf,
                                     int32_t output_buf_size);

/* ---- Vectorize: fused volume -> MapGraph GeoJSON ---- */
/*
 * Turn the fused CartyWorldGrid into a MapGraph of rooms/doors using CLASSICAL CV
 * only (NO neural net). Five staged passes (column classify ->
 * room segment -> boundary trace -> door detect -> assemble) emit a GeoJSON
 * FeatureCollection into a bounded caller buffer: each room a Polygon feature
 * (the node's `shape`), each door a Point feature with connections:[roomA,roomB].
 * Dart parses it as a standard GeoJSON FeatureCollection (no new marshalling
 * format); native need not be byte-canonical, only valid GeoJSON.
 *
 * Tiger Style: every stage bounded by construction (fixed
 * N×N×H, CARTY_VEC_MAX_ROOMS/CARTY_VEC_MAX_DOORS caps); ABORTS at the boundary on
 * a NULL grid/buffer or non-positive size; an empty/unanchored grid is DATA (a
 * non-fatal status), not a corrupt boundary.
 */
#define CARTY_VEC_OUT_MAX   (64 * 1024) /* GeoJSON output ceiling, bytes */
#define CARTY_VEC_MAX_ROOMS 256         /* hard cap on emitted room nodes */
#define CARTY_VEC_MAX_DOORS 256         /* hard cap on emitted door nodes */

#define CARTY_VEC_ENOSPACE (-110) /* out_buf too small for the FeatureCollection */
#define CARTY_VEC_ENOGRID  (-111) /* grid empty / unanchored: nothing to vectorize */

/* Vectorize `grid` into a GeoJSON FeatureCollection written (NUL-terminated) into
 * out_buf. On success returns the byte count written (including NUL); returns
 * CARTY_VEC_ENOSPACE if out_buf is too small, or CARTY_VEC_ENOGRID if the grid is
 * unanchored / holds no observed cells. ABORTS on a NULL grid/out_buf or
 * non-positive out_buf_size (crash-at-boundary, Tiger Style). */
int32_t carty_vectorize(const CartyWorldGrid *grid, char *out_buf,
                        int32_t out_buf_size);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CARTY_BRIDGE_H_ */
