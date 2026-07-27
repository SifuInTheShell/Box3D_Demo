// River water, depth-aware (docs/water-research.md §1).
// Vertex: small sum-of-sines displacement (mirrored on the CPU by
// WaterFX.water_height() for buoyancy). Fragment: Beer-Lambert tint from
// the opaque depth buffer, screen refraction with an above-water guard,
// Schlick fresnel, dual scrolling procedural normal maps, and depth-delta
// shore foam -- which also rings any debris sitting in the river for free.
// The plane is assumed unrotated (axis-aligned strip), which every caller
// (Scenery.water) satisfies.
shader_type spatial;
render_mode cull_disabled, depth_draw_always;

uniform vec4 shallow : source_color = vec4(0.16, 0.38, 0.46, 1.0);
uniform vec4 deep : source_color = vec4(0.04, 0.13, 0.22, 1.0);
uniform vec4 foam_color : source_color = vec4(0.9, 0.96, 1.0, 1.0);
uniform float wave_height = 0.08;
uniform float beers_law = 0.55;         // absorption per metre of water column
uniform float refraction_strength = 0.35;
uniform float foam_distance = 1.1;      // metres of column where foam appears
uniform float foam_cutoff = 0.52;
uniform float edge_fade = 0.25;         // soft waterline, metres
uniform vec2 flow_dir = vec2(1.0, 0.0); // river runs along +X
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform sampler2D foam_tex : filter_linear_mipmap, repeat_enable;

// Interactive ripple heightfield (water_sim.gd). hint_default_black: with
// no simulation bound, height and gradient are zero and everything below
// is a no-op.
uniform sampler2D ripple_tex : hint_default_black, filter_linear, repeat_disable;
uniform vec2 ripple_origin = vec2(0.0);
uniform vec2 ripple_span = vec2(1.0, 1.0);
uniform float ripple_height = 0.35;   // world metres per sim unit
uniform float ripple_normal_k = 5.0;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap, repeat_disable;

varying vec3 v_world;
varying vec2 v_ruv;
varying float v_rin;  // 1 inside the ripple domain, else 0

// Wave trains: direction (xy), spatial frequency (z), speed (w). Mostly
// along the flow axis with slight divergence; amplitudes in WAVE_AMP sum
// to 1 so wave_height is the true peak amplitude. WaterFX.water_height()
// must stay in lockstep with this table.
const vec4 WAVES[3] = {
	vec4(0.995, 0.0995, 0.5, 1.2),
	vec4(0.9285, -0.3714, 0.85, 0.8),
	vec4(0.8, 0.6, 1.7, 1.6)
};
const vec3 WAVE_AMP = vec3(0.45, 0.35, 0.2);

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = 0.0;
	vec2 grad = vec2(0.0);
	for (int i = 0; i < 3; i++) {
		vec2 dir = WAVES[i].xy;
		float k = WAVES[i].z;
		float phase = dot(dir, v_world.xz) * k + TIME * WAVES[i].w;
		h += WAVE_AMP[i] * sin(phase);
		grad += WAVE_AMP[i] * k * cos(phase) * dir;
	}
	VERTEX.y += h * wave_height;
	grad *= wave_height;
	NORMAL = normalize(vec3(-grad.x, 1.0, -grad.y));
	v_ruv = (v_world.xz - ripple_origin) / ripple_span;
	v_rin = step(0.0, v_ruv.x) * step(v_ruv.x, 1.0)
			* step(0.0, v_ruv.y) * step(v_ruv.y, 1.0);
	VERTEX.y += textureLod(ripple_tex, v_ruv, 0.0).r * ripple_height * v_rin;
}

// Scene depth (metres from camera) at a screen UV, from the opaque pass.
float scene_depth(vec2 uv, mat4 inv_proj) {
	float raw = texture(DEPTH_TEXTURE, uv).x;
	vec4 view = inv_proj * vec4(uv * 2.0 - 1.0, raw, 1.0);
	return -view.z / view.w;
}

void fragment() {
	float surface_d = -VERTEX.z;
	// Two scrolling normal-map layers, both drifting downstream.
	vec2 uv1 = v_world.xz * 0.11 + flow_dir * TIME * 0.045;
	vec2 uv2 = v_world.xz * 0.031 + (flow_dir + vec2(-flow_dir.y, flow_dir.x) * 0.25) * TIME * 0.021;
	NORMAL_MAP = mix(texture(normal_tex, uv1).rgb, texture(normal_tex, uv2).rgb, 0.5);
	NORMAL_MAP_DEPTH = 0.55;

	// Bend the detail normal with the ripple heightfield's gradient.
	if (v_rin > 0.5) {
		vec2 rtexel = 1.0 / vec2(textureSize(ripple_tex, 0));
		float hl = textureLod(ripple_tex, v_ruv - vec2(rtexel.x, 0.0), 0.0).r;
		float hr = textureLod(ripple_tex, v_ruv + vec2(rtexel.x, 0.0), 0.0).r;
		float hd = textureLod(ripple_tex, v_ruv - vec2(0.0, rtexel.y), 0.0).r;
		float hu = textureLod(ripple_tex, v_ruv + vec2(0.0, rtexel.y), 0.0).r;
		vec3 rip = normalize(vec3((hl - hr) * ripple_normal_k,
				(hd - hu) * ripple_normal_k, 1.0));
		vec3 det = NORMAL_MAP * 2.0 - 1.0;
		NORMAL_MAP = normalize(vec3(det.xy + rip.xy, det.z * rip.z)) * 0.5 + 0.5;
	}

	// Water column under this pixel (opaque scene minus surface).
	float water_col = max(scene_depth(SCREEN_UV, INV_PROJECTION_MATRIX) - surface_d, 0.0);

	// Refraction: offset by the detail normal, rejected if the offset
	// sample is nearer than the surface (an above-water object).
	vec3 nm = NORMAL_MAP * 2.0 - 1.0;
	vec2 ref_uv = SCREEN_UV + nm.xy * refraction_strength
			* clamp(water_col, 0.0, 1.0) / max(1.0, surface_d * 0.4);
	float ref_col = scene_depth(ref_uv, INV_PROJECTION_MATRIX) - surface_d;
	if (ref_col <= 0.0) {
		ref_uv = SCREEN_UV;
		ref_col = water_col;
	}
	vec3 refracted = textureLod(SCREEN_TEXTURE, ref_uv, 0.0).rgb;

	// Beer-Lambert: how much of the background survives the column.
	float transmit = exp(-beers_law * ref_col);
	vec3 tint = mix(deep.rgb, shallow.rgb, transmit);
	ALBEDO = mix(tint, refracted * mix(tint, vec3(1.0), 0.35), transmit);

	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 5.0);
	METALLIC = 0.0;
	SPECULAR = 0.5;
	ROUGHNESS = mix(0.09, 0.02, fresnel) + min(surface_d * 0.0012, 0.1);

	// Shore/debris foam where the column is shallow, lapping via noise.
	float foam_band = 1.0 - clamp(water_col / foam_distance, 0.0, 1.0);
	float fn = texture(foam_tex, v_world.xz * 0.17 + flow_dir * TIME * 0.03).r;
	float foam = foam_band * smoothstep(foam_cutoff - 0.18, foam_cutoff + 0.18,
			fn * 0.75 + foam_band * 0.5);
	ALBEDO = mix(ALBEDO, foam_color.rgb, foam);
	ROUGHNESS = mix(ROUGHNESS, 0.9, foam);

	ALPHA = clamp(water_col / edge_fade, 0.0, 1.0) * mix(0.96, 1.0, foam);
}
