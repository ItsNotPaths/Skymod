#version 450
//
// Shadow caster vertex stage (ROADMAP full-scene-lighting Phase D). Depth pass: transform the
// position by the model matrix then the cascade's light view-projection. Also passes the UV +
// alpha cutoff through for the ALPHA-TESTED caster (foliage), so leaves cast cutout-shaped
// shadows; the opaque shadow.frag ignores them. (Casters: opaque statics + terrain + tree trunks;
// alpha leaves in full mode / blacklisted trees; cheap canopy hulls cast as opaque.)

layout(location = 0) in vec3 a_pos;
layout(location = 2) in vec2 a_uv;

layout(set = 1, binding = 0) uniform UBO {
    mat4 light_vp; // cascade light view-projection
    mat4 model;    // world transform (identity for terrain / canopy-hull verts already world-ish)
    vec4 params;   // x = alpha-test cutoff (0 = opaque)
} ubo;

layout(location = 0) out vec2 v_uv;
layout(location = 1) out float v_cutoff;

void main() {
    gl_Position = ubo.light_vp * ubo.model * vec4(a_pos, 1.0);
    v_uv = a_uv;
    v_cutoff = ubo.params.x;
}
