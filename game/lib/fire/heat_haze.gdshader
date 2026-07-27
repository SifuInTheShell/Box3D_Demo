// Heat-haze: the air shimmer above a fire. A camera-facing billboard that
// samples the screen behind it and offsets the sample by rising, wind-skewed
// noise, so hot air visibly distorts the view. Subtle and budget-gated — only
// the ground pyres (fire_fx.gd, capped) carry one, never every burning body.
//
// wind_vec (the global the fire sim / flames read) skews the shimmer downwind.
// Per-instance `intensity` fades it with the fire's remaining life.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
global uniform vec3 wind_vec;
uniform float strength : hint_range(0.0, 0.08) = 0.02;
instance uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x),
			mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void vertex() {
	// Billboard: face the camera, preserving the quad's scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			MODEL_MATRIX[3]);
}

void fragment() {
	vec2 uv = UV;
	float up = 1.0 - uv.y;
	// Shimmer noise scrolls UP and skews with the wind.
	vec2 flow = vec2(uv.x * 7.0 + wind_vec.x * 0.15,
			uv.y * 9.0 - TIME * 3.0 + wind_vec.z * 0.15);
	float nx = vnoise(flow) - 0.5;
	float ny = vnoise(flow * 1.9 + 11.0) - 0.5;
	vec2 off = vec2(nx + wind_vec.x * 0.02, ny) * strength * intensity;
	// Soft oval mask so the quad's rectangle never shows; grows toward the top.
	vec2 c = uv - 0.5;
	float mask = smoothstep(0.5, 0.12, length(vec2(c.x * 1.25, c.y)));
	off *= mask * (0.55 + up);
	ALBEDO = texture(screen_tex, SCREEN_UV + off).rgb;
	ALPHA = mask * 0.85 * intensity;
}
