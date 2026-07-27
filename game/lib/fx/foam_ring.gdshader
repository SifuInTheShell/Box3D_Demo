// Expanding splash foam ring / lingering foam patch on the water surface.
// One shared material serves every pooled quad: per-quad state arrives via
// instance uniforms (progress 0..1, strength, patch_mode).
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;

uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform vec2 water_origin = vec2(0.0);   // world XZ of the water rect's min corner
uniform vec2 water_span = vec2(0.0);     // water rect size; (0,0) disables the mask
instance uniform float progress = 0.0;   // 0 = just spawned, 1 = gone
instance uniform float strength = 1.0;
instance uniform float patch_mode = 0.0; // 1 = filled lingering patch

varying vec3 v_world;

void vertex() {
	// World XZ of the vertex, so the ring can be clipped to the water rect.
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 c = UV - 0.5;
	float d = length(c) * 2.0;
	float n = texture(noise_tex, UV * 2.6 + vec2(progress * 0.15, TIME * 0.02)).r;
	float a;
	if (patch_mode > 0.5) {
		// Filled noisy patch that erodes from the rim inward as it ages.
		float rim = 1.0 - smoothstep(0.55, 1.0, d + progress * 0.35);
		a = rim * smoothstep(progress - 0.25, progress + 0.35, n * 0.9 + 0.25)
				* (1.0 - progress) * 0.75;
	} else {
		// Ring expanding to the quad edge, thinning and breaking up.
		float w = mix(0.30, 0.12, progress);
		float band = smoothstep(progress - w, progress, d)
				* (1.0 - smoothstep(progress, progress + w * 0.6, d));
		a = band * (0.5 + 0.5 * n) * (1.0 - progress);
	}
	ALBEDO = vec3(0.92, 0.97, 1.0);
	float alpha = clamp(a * strength, 0.0, 1.0);
	// Clip the quad to the water rectangle: a splash ring routinely overhangs a
	// narrow canal, and the quad is otherwise unmasked, so without this the
	// white ring draws straight onto the grass banks. Soft ~0.15 m shoreline
	// fade. Skipped when the domain is unset (span 0), so an un-plumbed splash
	// behaves exactly as before.
	if (water_span.x > 0.0 && water_span.y > 0.0) {
		vec2 wuv = (v_world.xz - water_origin) / water_span;
		vec2 fade = vec2(0.15) / water_span;
		vec2 lo = smoothstep(vec2(0.0), fade, wuv);
		vec2 hi = smoothstep(vec2(0.0), fade, vec2(1.0) - wuv);
		alpha *= lo.x * lo.y * hi.x * hi.y;
	}
	ALPHA = alpha;
}
