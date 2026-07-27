// Laundry sway for site_props.laundry_line: the quad hangs from its top
// edge (UV.y = 0 pinned on the line), the free hem swings in the wind.
// Phase comes from the node's world position so neighbouring sheets never
// sway in unison. Visual-only cloth — blasts don't need to simulate laundry,
// but the whole line goes down with its poles (they are the physics).
//
// wind_vec is the global weather (lib/wind/wind_system.gd publishes the
// same breathing vector the fire sim receives): the hem gets pushed along
// the real wind direction and flutters faster as it strengthens. With no
// wind system on site the global is zero and the gentle idle sway remains.
shader_type spatial;
render_mode cull_disabled;

global uniform vec3 wind_vec;

uniform vec3 tint: source_color = vec3(0.9, 0.9, 0.88);

void vertex() {
	float hang = UV.y;  // 0 at the line, 1 at the hem
	float wind_speed = length(wind_vec);
	// Real wind, brought into the quad's local frame: the hem is only free
	// to swing along its local Z (the quad's normal).
	vec3 wind_local = (inverse(MODEL_MATRIX) * vec4(wind_vec, 0.0)).xyz;
	float phase = NODE_POSITION_WORLD.x * 1.7 + NODE_POSITION_WORLD.z * 2.3;
	float rate = 1.0 + wind_speed * 0.3;  // stronger wind, faster flutter
	float sway = sin(TIME * 1.9 * rate + phase) * 0.5
			+ sin(TIME * 3.1 * rate + phase * 1.6) * 0.2;
	float hh = hang * hang;
	VERTEX.z += hh * (sway * (0.16 + wind_speed * 0.02) + wind_local.z * 0.045);
	VERTEX.y += hh * abs(sway) * 0.02;  // the hem lifts a little as it swings
}

void fragment() {
	ALBEDO = tint;
	ROUGHNESS = 1.0;
}
