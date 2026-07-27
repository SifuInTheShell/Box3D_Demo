# Box3D GDExtension — the binding extensions

**What this documents:** exactly what was added to the box3d-godot
GDExtension to take it from a partial binding to *near-complete* coverage of
Erin Catto's Box3D C API — the difference between the base fork and the
wrapper vendored here in `extern/box3d-godot/godot/`.

## Where it came from, and the discipline

- **Base fork:** [`Stink-O/box3d-godot`](https://github.com/Stink-O/box3d-godot)
  at commit `a42bed6` (pinned in `extern/box3d-godot/UPSTREAM_COMMIT`). It
  exposed the core of Box3D — worlds, bodies, the shape types, the joint set,
  a character controller, basic queries and contact events — roughly a third
  of Box3D's ~420 public C functions.
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
  `get_awake_body_count()`, `get_bounds()`, `rebuild_static_tree()`.
- **Queries** — `overlap_aabb(aabb, collision_mask)` (box-region query
  alongside the pre-existing sphere/ray casts).
- **Deterministic recording → replay** — `start_recording(byte_capacity)`,
  `stop_recording()` → `PackedByteArray`, `is_recording()`, and the static
  `Box3DWorld.validate_replay(data, worker_count)`. (Replay *playback* into a
  live world is deliberately deferred — see below.)
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

## Deliberately deferred

A few self-contained pieces upstream exposes were left for later:

- **Replay playback** — recording and `validate_replay` ship; feeding a
  recording back into a live world does not.
- **Solver callbacks** (custom filter / pre-solve hooks).
- The **heightfield**, **baked-compound**, and **filter-joint** constructors.

## Verifying the binding

The GDExtension carries its own selftest harness. After a rebuild:

```sh
GODOT=<path to Godot 4.7.1>
"$GODOT" --headless --path extern/box3d-godot/godot/demo --import
"$GODOT" --headless --path extern/box3d-godot/godot/demo res://tests/test_features.tscn -- --selftest
"$GODOT" --headless --path extern/box3d-godot/godot/demo res://tests/test_samples.tscn  -- --selftest
```

Expect 47 `[test]` lines and 33 `[samples]` lines (each counting the final
`ALL -> PASS`). The full node/property/method reference is
`extern/box3d-godot/godot/README.md`; the build and upstream-sync procedure is
[`box3d-build-and-use.md`](box3d-build-and-use.md).
