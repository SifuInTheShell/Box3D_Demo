// Heat-haze shell: an expanding sphere that refracts the scene behind it,
// strongest at the silhouette so it reads as a blast wave compressing the
// air. Fades out as `progress` runs 0 -> 1.
shader_type spatial;
render_mode blend_mix, unshaded, cull_back, depth_draw_never;

uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float strength = 0.045;
uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear_mipmap;

void fragment() {
	vec3 nrm = normalize(NORMAL);
	float fres = 1.0 - clamp(dot(nrm, normalize(VIEW)), 0.0, 1.0);
	vec2 offset = nrm.xy * strength * fres * (1.0 - progress);
	vec3 scene = texture(screen_tex, clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999))).rgb;
	ALBEDO = scene;
	ALPHA = clamp(fres * 1.6, 0.0, 1.0) * (1.0 - progress);
}
