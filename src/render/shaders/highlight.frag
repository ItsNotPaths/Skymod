#version 450
//
// Model highlight (inspect mode): overdraw the hovered model in a flat highlight colour so the
// user sees what a click selects. Reuses mesh.vert (so it keeps the alpha-test cutout —
// leaves don't fill as solid quads).

layout(location = 0) in vec2 v_uv;
layout(location = 1) in float v_cutoff;

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;

layout(location = 0) out vec4 out_color;

void main() {
    float a = texture(u_diffuse, v_uv).a;
    if (a < v_cutoff) discard; // respect foliage cutouts
    out_color = vec4(1.0, 0.85, 0.2, 1.0); // warm yellow
}
