/*
 * carty_vectorize_internal.h — per-stage helpers behind carty_vectorize, exposed
 * to the ctest so each CV stage is unit-tested in isolation (TDD).
 * Not part of the public FFI surface.
 */
#ifndef CARTY_VECTORIZE_INTERNAL_H_
#define CARTY_VECTORIZE_INTERNAL_H_

#include <cstdint>

enum CartyCellLabel { kCellFree = 0, kCellFloor = 1, kCellWall = 2, kCellFurniture = 3 };

struct CartyVecDoor { int32_t room_a, room_b; double x, y; };

// Stage 0: classify ONE ground column from its band_count contiguous band values.
CartyCellLabel carty_vec_classify_column(const int8_t *band_profile, int32_t band_count);

// Stage 1: flood-fill non-wall interior cells into room components. Writes
// room_ids[grid_side*grid_side]: -1 for wall AND for border-connected exterior free
// space, else 0..(count-1). Returns the room count. Bounded: count <= CARTY_VEC_MAX_ROOMS.
int32_t carty_vec_segment_rooms(const uint8_t *labels, int32_t grid_side, int32_t *room_ids);

// Stage 2: trace the outline of the cells whose room_ids==room into a closed
// polygon ring (>=3 verts), writing x,y pairs into out_xy (cap pairs). Returns
// the vertex count (Douglas–Peucker-simplified). Coordinates are grid-cell units.
int32_t carty_vec_trace_boundary(const int32_t *room_ids, int32_t grid_side, int32_t room,
                                 double *out_xy, int32_t cap);

// Stage 3: (regularize — reserved, added in a later task)

// Stage 4: detect wall openings joining two distinct room components. Writes up
// to cap doors into out; returns the door count. Each door's (x,y) is the gap
// midpoint in grid-cell units.
int32_t carty_vec_detect_doors(const uint8_t *labels, const int32_t *room_ids,
                               int32_t grid_side, CartyVecDoor *out, int32_t cap);

#endif  // CARTY_VECTORIZE_INTERNAL_H_
