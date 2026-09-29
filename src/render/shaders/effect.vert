#version 450
//
// Effect-shader vertex stage (BSEffectShaderProperty FX: flowing water, fire billboards,
// interior light beams). Like the mesh path it just projects the geometry, but instead of
// N·L shading it ANIMATES the UV: the effect's controller-derived scroll speed (tiles/sec)
// times the elapsed time slides the texture — the flowing-water / beam motion. Emissive, so
// no lighting; the additive effect_pipeline blends the result over the opaque scene.

layout(location = 0) in vec3 a_pos;
layout(location = 2) in vec2 a_uv;

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;
    mat4 model;
    vec4 anim; // xy = UV scroll speed (tiles/sec); z = time (seconds); w unused
} ubo;

layout(location = 0) out vec2 v_uv;

void main() {
    gl_Position = ubo.vp * (ubo.model * vec4(a_pos, 1.0));
    v_uv = a_uv + ubo.anim.xy * ubo.anim.z;
}
