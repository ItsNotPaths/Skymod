#version 450
//
// Model highlight (inspect mode): overdraw the hovered model in a solid highlight colour so
// the user sees what a click selects. Reuses mesh.vert (so it keeps the alpha-test cutout —
// leaves don't fill as solid quads). A cheap fixed-direction half-lambert off the world normal
// keeps the model's form readable; this is a DEBUG overlay, so it deliberately does NOT read
// the scene lighting UBO (no set-3 dependency on the highlight pipeline).

layout(location = 0) in vec3 v_normal;
layout(location = 1) in vec2 v_uv;
layout(location = 3) in float v_cutoff;

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;

layout(location = 0) out vec4 out_color;

void main() {
    float a = texture(u_diffuse, v_uv).a;
    if (a < v_cutoff) discard; // respect foliage cutouts
    float shade = 0.5 + 0.5 * max(dot(normalize(v_normal), normalize(vec3(0.4, 0.6, 1.0))), 0.0);
    vec3 hl = vec3(1.0, 0.85, 0.2); // warm yellow
    out_color = vec4(hl * (0.55 + 0.45 * shade), 1.0);
}
