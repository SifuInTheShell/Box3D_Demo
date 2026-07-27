// Explosion fireball: a sphere whose surface boils outward with 3D value
// noise, colored white-hot -> orange -> sooty dark, then erodes away as
// `progress` runs 0 -> 1. Emission is well over 1.0 so the WorldEnvironment
// glow blooms it.
shader_type spatial;
render_mode blend_mix, unshaded, cull_back;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec3 hot_color : source_color = vec3(1.0, 0.97, 0.75);
uniform vec3 mid_color : source_color = vec3(1.0, 0.45, 0.1);
uniform vec3 dark_color : source_color = vec3(0.16, 0.07, 0.04);
uniform float emission_strength = 5.0;

varying vec3 v_pos;

float hash13(vec3 p3) {
	p3 = fract(p3 * 0.1031);
	p3 += dot(p3, p3.zyx + 31.32);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);
	return mix(
			mix(mix(hash13(i), hash13(i + vec3(1.0, 0.0, 0.0)), u.x),
				mix(hash13(i + vec3(0.0, 1.0, 0.0)), hash13(i + vec3(1.0, 1.0, 0.0)), u.x), u.y),
			mix(mix(hash13(i + vec3(0.0, 0.0, 1.0)), hash13(i + vec3(1.0, 0.0, 1.0)), u.x),
				mix(hash13(i + vec3(0.0, 1.0, 1.0)), hash13(i + vec3(1.0, 1.0, 1.0)), u.x), u.y),
			u.z);
}

float fbm(vec3 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * vnoise(p);
		p = p * 2.15 + vec3(7.7);
		a *= 0.5;
	}
	return v;
}

void vertex() {
	v_pos = VERTEX;
	float n = fbm(VERTEX * 1.9 + vec3(0.0, TIME * 0.7, 0.0));
	VERTEX += NORMAL * n * (0.25 + 0.55 * progress);
}

void fragment() {
	float n = fbm(v_pos * 2.3 + vec3(TIME * 0.9, -TIME * 0.5, 0.0));
	float heat = 1.0 - progress;
	float t = n * 0.75 + heat * 0.85;
	vec3 col = mix(dark_color, mid_color, smoothstep(0.15, 0.55, t));
	col = mix(col, hot_color, smoothstep(0.62, 0.95, t));
	// Rim goes sooty as the ball cools, for a volumetric read.
	float fres = pow(1.0 - clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 2.0);
	col = mix(col, dark_color, fres * (0.2 + 0.6 * progress));
	// Noise-keyed dissolve: patches burn through, then the whole shell dies.
	float alpha = smoothstep(0.0, 0.22, (n + 0.62) - progress * 1.35);
	// Burning erosion edge: a white-hot rim right where the shell dissolves.
	float edge = smoothstep(0.0, 0.1, alpha) * (1.0 - smoothstep(0.1, 0.45, alpha));
	col += hot_color * edge * 2.0;
	ALBEDO = col;
	EMISSION = col * emission_strength * (0.3 + 1.7 * heat * heat) + hot_color * edge * 6.0;
	ALPHA = alpha;
}
