# Box3D GDExtension — the binding extensions

**What this documents:** exactly what was added to the box3d-godot
GDExtension to take it from a partial binding to *near-complete* coverage of
Erin Catto's Box3D C API — the difference between the base fork and the
wrapper vendored here in `extern/box3d-godot/godot/`.

## Where it came from, and the discipline

- **Base fork:** [`Stink-O/box3d-godot`](https://github.com/Stink-O/box3d-godot)
  at commit `a42bed6`; the engine sources have since been synced directly from
  `erincatto/box3d` (current pin in `extern/box3d-godot/UPSTREAM_COMMIT`). It
  exposed the core of Box3D — worlds, bodies, the shape types, the joint set,
  a character controller, basic queries and contact events — roughly a third
  of Box3D's public C functions.
- **What we did:** extended the C++ wrapper *additively* to surface nearly the
  whole remaining C API to GDScript, so existing scripts keep working
  unchanged. Every addition sits under a
  `// --- Extended core access ---` banner in the wrapper source
  (`src/box3d_world.cpp`, `src/box3d_body.cpp`, `src/box3d_joint.cpp` and their
  headers). Grepping that marker enumerates the delta precisely.
- **Why additive:** the fork never touches upstream-owned files (`src/`,
  `include/`, tests, samples, build files) — all custom code lives in `godot/`.
  That keeps `git merge upstream/main` conflict-free, so pulling a newer Box3D
  core can't lose the binding. Rebuild path and sync rules:
  [`box3d-build-and-use.md`](box3d-build-and-use.md).
- **The Box3D engine itself is unmodified.** These are binding (GDScript
  reachability) changes only — no solver, collision or determinism code was
  altered. The scalar/SSE2/NEON paths stay bit-exact.

## `Box3DWorld` — diagnostics, queries, determinism, solver knobs

- **Live diagnostics** — `get_counters()`, `get_profile()`,
  `get_awake_body_count()`, `get_bounds()`, `rebuild_static_tree()` (upstream
  made `b3World_RebuildStaticTree` internal in `79fc559`; the wrapper
  forward-declares it, since the engine is linked into the same library).
- **Queries** — `overlap_aabb(aabb, collision_mask)` (box-region query
  alongside the pre-existing sphere/ray casts).
- **Deterministic recording → replay** — `start_recording(byte_capacity)`,
  `stop_recording()` → `PackedByteArray`, `is_recording()`, and the static
  `Box3DWorld.validate_replay(data, worker_count)`. Playback:
  `Box3DReplayPlayer` (see "Extended core access III" below).
- **Solver tuning** — speculative-contact toggle (`enable_speculative`),
  `restitution_threshold`, `hit_event_threshold`, and
  `contact_recycle_distance` (Catto's stack stabilizer), each exposed as a
  property with an "engine default until set" sentinel.

## `Box3DBody` — forces at a point, mass, lifecycle, introspection, live shapes

**Forces & velocity**
- `apply_force(force, world_point)`, `apply_impulse(impulse, world_point)`,
  `apply_angular_impulse(impulse)`, `get_point_velocity(world_point)`.

**Mass data**
- `get_center_of_mass()`, `get_inverse_mass()`, `get_mass_data()`,
  `set_mass_data(mass, local_center)`, `reset_mass()`.

**Sleep & lifecycle**
- `set_sleep_threshold()/get_sleep_threshold()`, `set_enabled()/is_enabled()`,
  `wake()`, `is_awake()`.

**Introspection & body-space transforms**
- `get_closest_point(target)`, `get_contact_data()` (live manifolds),
  `get_aabb()`, `get_shape_count()`, `get_joint_count()`, `get_local_center()`.
- Point/vector conversions: `to_local_point`, `to_world_point`,
  `to_local_vector`, `to_world_vector`, `get_local_point_velocity`.

**Live per-shape materials (change on a running body, no rebuild)**
- Friction / restitution / density / collision filter / surface material:
  `set_shape_friction`, `set_shape_restitution`, `set_shape_density`,
  `set_shape_filter(category, mask, group)`, `set_shape_surface_material`
  (each with a matching `get_shape_*(shape_index)`).
- Per-shape geometry queries: `get_shape_aabb`, `get_shape_closest_point`,
  `shape_raycast`, `get_shape_core_type`, `is_shape_sensor`.
- Per-shape event toggles: contact / hit / sensor / presolve
  (`enable_shape_*_events` + `are_shape_*_events_enabled`).

**Signals**
- `body_hit(body, point, normal, approach_speed)` — a real impact event with
  contact geometry, on top of the existing `body_entered` / `body_exited`;
  plus `area_entered` / `area_exited` for sensors.

## Joints — solver readouts, break thresholds, and full per-type tuning

**On every joint (`Box3DJoint` base):**
- Readouts: `get_constraint_force()`, `get_constraint_torque()`,
  `get_linear_separation()`, `get_angular_separation()`, `is_joint_valid()`,
  `get_joint_type()`.
- Break thresholds: `set_force_threshold()` / `set_torque_threshold()` (drive
  the snapping cables/ropes).
- Frames & wiring: `get/set_local_frame_a`, `get/set_local_frame_b`,
  `get/set_constraint_tuning(hertz, damping)`, `get/set_body_a`,
  `get/set_body_b`, `set_collide_connected`.

**Full tuning on all eight subclasses** (previously constructible but largely
unconfigurable from GDScript):
- **Hinge** — limits, motor (speed / max torque), spring (hertz / damping).
- **Slider** — limits, motor (speed / max force).
- **Distance** — rest length, spring, min/max length limits.
- **Ball** — cone limit, twist limits, spring, friction torque.
- **Fixed** — linear / angular hertz.
- **Wheel** — suspension (hertz / damping / limits), spin motor, steering
  (target angle, hertz/damping, limits, max torque), `get_spin_speed()`,
  `get_steering_angle()`.
- **Parallel** — spring hertz / damping, max torque.
- **Motor** — linear/angular target velocity, max force/torque, spring
  hertz/damping, max spring force/torque.

## Extended core access III — the full public C API

After syncing the engine to upstream `be8c731` the binding was taken to
**618 of the 624 `B3_API` functions** in `include/box3d/*.h` (every one in
`box3d.h`, `collision.h`, `constants.h` and `math_functions.h` that has a
GDScript-meaningful form). New code sits under
`// --- Extended core access III ---` banners. Runtime coverage lives in
`godot/demo/tests/test_extended_api.tscn`.

- **`Box3DWorld`** — upstream's static-only queries (`cast_ray_static`,
  `overlap_aabb_static`, `overlap_shape_static`, `cast_shape_static`), general
  `overlap_shape` / `cast_shape` with `{type: sphere|capsule|box|points}`
  dictionaries, `cast_mover`, `get_body_move_events()`, a `joint_event(joint,
  joint_id)` signal (fires past a joint's force/torque threshold),
  `get_debug_draw_data()` (runs `b3World_Draw` and returns the primitives),
  live engine reads (`get_live_gravity`, `is_sleeping_enabled`, …),
  `restitution_iterations`, `enable_restitution_propagation`,
  `isotropic_inertia_tolerance`, `enable_sse2_fallback`, live `worker_count`,
  `dump_memory_stats()`, `get_world_count()`.
- **Solver callbacks, made thread-safe.** Box3D calls pre-solve / friction /
  restitution / custom-filter callbacks from solver worker threads, so they
  never call GDScript. They are data-driven instead: `friction_mix` /
  `restitution_mix` (`MixRule`: default, average, min, max, multiply,
  geometric), body-pair and layer-pair collision rules
  (`set_body_pair_collision_enabled`, `set_layer_pair_collision_enabled`;
  bodies opt in with `Box3DBody.custom_filtering = true`), and one-way
  platforms (`set_one_way_platform(body, normal, min_dot)`).
- **`Box3DBody`** — live `gravity_scale` / damping / `body_type` /
  fast rotation (no rebuild), `sleep_enabled`, `safety_factor`, `body_name`,
  extents, rotational inertia, motion locks, `get_joints()` (with the joint
  node), per-body `cast_ray` / `cast_shape` / `overlap_shape` /
  `collide_mover` / `time_of_impact_mover`, and per-shape geometry get/set
  (sphere, capsule, hull, mesh, height field, compound), mass data, contact
  manifolds, sensor overlaps, wind, names, mesh materials, `destroy_shape`,
  `is_contact_valid` / `get_contact`. New `HEIGHTFIELD` shape type
  (`heightfield_*` properties) and `bake_compound` for static compound bodies
  (`b3CreateBakedCompoundShape`).
- **Joints** — `get_current_*` live readouts on every type (angle,
  translation, length, speed, motor force/torque, twist/cone angle),
  `get_live_settings()`, `is_awake()`, `get_body_a_node()` /
  `get_body_b_node()`, plus the previously missing features: hinge
  `target_angle`, slider spring + `target_translation`, distance motor and
  spring force range, ball motor + `target_rotation`, fixed-joint damping.
  New nodes: **`Box3DMoverJoint`**, **`Box3DPogoJoint`** (upstream's dynamic
  character mover) and **`Box3DFilterJoint`** (disable collision between two
  bodies). Live setters now update a running joint instead of recreating it.
- **`Box3DReplayPlayer`** (RefCounted) — replay *playback*: open a recording
  from `Box3DWorld.stop_recording()` or a file, step / sub-step / seek /
  restart, divergence detection, per-body transforms and velocities, frame
  queries, keyframe policy, debug-draw data, and `save_recording` /
  `load_recording`.
- **`Box3DGeometry`** (static methods) — the world-independent API:
  hull / mesh / height-field / compound construction and readback, mass and
  AABB computation, ray / shape casts, `shape_distance`, `time_of_impact`,
  every `b3Collide*` manifold via `collide()`, 2D hulls, `solve_planes` /
  `clip_vector`, math validators, version / timer / hash utilities,
  length units, Box3D log routing (`set_log_mode`), default filter, graph
  colours. **`Box3DDynamicTree`** (RefCounted) wraps the standalone
  `b3DynamicTree` BVH.

### Intentionally unbound (6)

- `b3Body_SetUserData`, `b3World_SetUserData` — the wrapper owns user data
  (it points at the Godot node; events and queries depend on that mapping).
- `b3Shape_GetWorld` — a shape's world is its body's (`get_box3d_world()`).
- `b3SetAssertFcn` (and the allocator hook) — called from engine threads
  mid-failure / on every allocation; not safe to route into script.
- `b3SaveRecordingToFile` — needs a live `b3Recording*`; recordings are plain
  byte buffers, so `Box3DReplayPlayer.save_recording` writes the same bytes.
- `b3World_DumpShapeBounds` — declared upstream but not implemented (linking
  it would leave an undefined symbol).

## Verifying the binding

The GDExtension carries its own selftest harness. After a rebuild:

```sh
GODOT=<path to Godot 4.7.1>
"$GODOT" --headless --path extern/box3d-godot/godot/demo --import
"$GODOT" --headless --path extern/box3d-godot/godot/demo res://tests/test_features.tscn -- --selftest
"$GODOT" --headless --path extern/box3d-godot/godot/demo res://tests/test_samples.tscn  -- --selftest
"$GODOT" --headless --path extern/box3d-godot/godot/demo res://tests/test_extended_api.tscn -- --selftest
```

Expect 47 `[test]` lines and 33 `[samples]` lines (each counting the final
`ALL -> PASS`), plus an all-PASS `[ext]` run. The full node/property/method reference is
`extern/box3d-godot/godot/README.md`; the build and upstream-sync procedure is
[`box3d-build-and-use.md`](box3d-build-and-use.md).
