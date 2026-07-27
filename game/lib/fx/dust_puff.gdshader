// Dust / smoke puff for GPU particles: a billboarded quad whose radial mask
// is broken up by 2-octave value noise, so puffs read as roiling dust clouds
// instead of smooth blobs. Per-particle variation comes from the particle's
// world position (each puff samples a different noise patch); fade and tint
// come from the particle color ramp (COLOR).
shader_type spatial;
render_mode blend_mix, unshaded, depth_draw_never, cull_disabled;

// Optional puff silhouette (e.g. Kenney's CC0 smoke sprites). Defaults to
// white, so the shader degrades to the pure procedural mask without it.
uniform sampler2D puff_tex : source_color, hint_default_white, filter_linear_mipmap, repeat_disable;

varying vec2 v_seed;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(
			mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
			mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x),
			u.y);
}

float fbm2(vec2 p) {
	return vnoise2(p) * 0.65 + vnoise2(p * 2.3 + vec2(11.7)) * 0.35;
}

void vertex() {
	v_seed = MODEL_MATRIX[3].xz * 0.7;
	// Spherical billboard that keeps the particle's scale (standard snippet).
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
}

void fragment() {
	vec2 c = UV - vec2(0.5);
	// Per-particle random rotation, so identical sprites read as varied puffs.
	float ang = hash12(v_seed) * 6.2831853;
	float cs = cos(ang);
	float sn = sin(ang);
	vec2 ruv = vec2(c.x * cs - c.y * sn, c.x * sn + c.y * cs) + vec2(0.5);
	float sprite = texture(puff_tex, ruv).a;
	float r = length(c) * 2.0;
	float n = fbm2(UV * 3.2 + v_seed + vec2(TIME * 0.12, -TIME * 0.07));
	// Noise pushes the cloud edge in and out; alpha erodes as the ramp fades,
	// so dying puffs tear apart into wisps instead of dimming uniformly.
	float mask = smoothstep(1.05, 0.3, r + n * 0.7) * sprite;
	float erode = smoothstep(0.0, 0.55, COLOR.a - (1.0 - n) * 0.35);
	ALBEDO = COLOR.rgb * (0.85 + 0.3 * n);
	ALPHA = clamp(mask * erode, 0.0, 1.0) * min(COLOR.a * 1.6, 1.0);
}
