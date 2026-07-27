// Facade triplanar shader with a per-instance anchor.
//
// Sampling coordinate = object-space vertex position + `anchor` (set per
// instance to the body's spawn position). While a wall panel stands where it
// was built, local + anchor equals its world position, so adjacent panels
// sample one continuous texture and the building has no visible seams --
// exactly like world triplanar. But the coordinate is fundamentally LOCAL:
// once a panel is dislodged or a shard tumbles away, the texture stays glued
// to the surface instead of rolling through it (the world-triplanar
// "swimming" artifact this replaces).
shader_type spatial;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 tint : source_color = vec4(1.0);
uniform float uv_scale = 0.35;
uniform float rough : hint_range(0.0, 1.0) = 0.9;

instance uniform vec3 anchor;

varying vec3 v_pos;
varying vec3 v_nrm;

void vertex() {
	v_pos = (VERTEX + anchor) * uv_scale;
	v_nrm = NORMAL;
}

void fragment() {
	vec3 w = pow(abs(normalize(v_nrm)), vec3(4.0));
	w /= (w.x + w.y + w.z);
	vec3 col = texture(albedo_tex, v_pos.zy).rgb * w.x
			+ texture(albedo_tex, v_pos.xz).rgb * w.y
			+ texture(albedo_tex, v_pos.xy).rgb * w.z;
	ALBEDO = col * tint.rgb;
	ROUGHNESS = rough;
}
