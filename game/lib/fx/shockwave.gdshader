// Ground shockwave: an additive ring racing outward across a horizontal
// quad. `progress` 0 -> 1 drives the ring from center to the quad edge while
// it thins out and fades.
shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_never;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform vec3 ring_color : source_color = vec3(1.0, 0.75, 0.42);

void fragment() {
	vec2 c = UV - vec2(0.5);
	float r = length(c) * 2.0;
	float radius = 0.05 + progress * 0.95;
	float band = 0.10 + progress * 0.08;
	float ring = smoothstep(radius, radius - band * 0.5, r)
			* smoothstep(radius - band * 1.8, radius - band * 0.9, r);
	float fade = (1.0 - progress) * (1.0 - progress);
	ALBEDO = vec3(0.0);
	EMISSION = ring_color * ring * fade * 3.5;
	ALPHA = clamp(ring * fade, 0.0, 1.0);
}
