// Bird wing flap for bird_flock.gd's MultiMesh. Wing vertices are simply
// everything past the body's half-width (|z|... no: |x| — the dart flies
// along -Z, wings span X). INSTANCE_CUSTOM: r = per-bird phase, g = wings
// out (0 perched/folded, 1 flying). Perched birds fold their wings by
// pulling the span in; flying birds flap on a per-instance phase so the
// flock never beats in unison.
shader_type spatial;
render_mode cull_disabled;

const float BODY_HALF = 0.05;

void vertex() {
	float wing = smoothstep(BODY_HALF, 0.22, abs(VERTEX.x));
	float open = INSTANCE_CUSTOM.g;
	VERTEX.x *= mix(mix(1.0, 0.35, wing), 1.0, open);
	float flap = sin(TIME * 13.0 + INSTANCE_CUSTOM.r) * 0.09;
	VERTEX.y += wing * open * flap;
}

void fragment() {
	ALBEDO = vec3(0.13, 0.13, 0.15);  // silhouette bird — read, don't inspect
	ROUGHNESS = 0.9;
}
