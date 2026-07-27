#[compute]
#version 450

// Heightfield wave-equation step (docs/water-research.md §2): Verlet
// integration over a 3-texture ring (prev / curr / next), Laplacian
// coefficient 0.25 (max stable for the 4-neighbor stencil), plus this
// frame's impact splats and absorbing bands on the short (open) ends so
// blasts don't leave standing waves. Dispatched at a fixed 30 Hz by
// water_sim.gd; the water material samples the newest texture directly
// via Texture2DRD.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r32f, set = 0, binding = 0) uniform restrict readonly image2D prev_img;
layout(r32f, set = 0, binding = 1) uniform restrict readonly image2D curr_img;
layout(r32f, set = 0, binding = 2) uniform restrict writeonly image2D next_img;

// xy = texel position, z = radius in texels, w = strength (negative =
// surface pushed down by an entering body).
layout(set = 0, binding = 3, std430) restrict readonly buffer Splats {
	vec4 data[];
} splats;

layout(push_constant, std430) uniform Params {
	vec2 size;        // texture dimensions
	float damp;       // fraction of the new height lost per step
	float splat_count;
	float edge_band;  // absorbing band width on the x ends, texels
	float pad0;
	float pad1;
	float pad2;
} params;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 dims = ivec2(params.size);
	if (id.x >= dims.x || id.y >= dims.y) {
		return;
	}
	ivec2 mx = dims - 1;
	float up = imageLoad(curr_img, min(id + ivec2(0, 1), mx)).r;
	float dn = imageLoad(curr_img, max(id - ivec2(0, 1), ivec2(0))).r;
	float lf = imageLoad(curr_img, max(id - ivec2(1, 0), ivec2(0))).r;
	float rt = imageLoad(curr_img, min(id + ivec2(1, 0), mx)).r;
	float c = imageLoad(curr_img, id).r;
	float p = imageLoad(prev_img, id).r;

	float next = 2.0 * c - p + 0.25 * (up + dn + lf + rt - 4.0 * c);
	next -= params.damp * next;

	for (int i = 0; i < int(params.splat_count); i++) {
		vec4 s = splats.data[i];
		float d = distance(vec2(id), s.xy);
		next += s.w * (1.0 - smoothstep(0.0, max(s.z, 1.0), d));
	}

	// Long banks (z edges) reflect like real banks; the short x ends absorb.
	float bx = min(float(id.x), params.size.x - 1.0 - float(id.x));
	if (bx < params.edge_band) {
		next *= mix(0.93, 1.0, bx / params.edge_band);
	}
	imageStore(next_img, id, vec4(next, 0.0, 0.0, 0.0));
}
