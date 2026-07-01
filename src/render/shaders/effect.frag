#version 450
//
// Effect-shader fragment stage (BSEffectShaderProperty FX: flowing water, fire billboards,
// interior light beams). Samples the effect's source texture at the scrolled UV and emits it
// for ADDITIVE blending (the effect_pipeline uses SRC_ALPHA→ONE, matching the canonical
// Skyrim FX alpha — value 4109). With additive blend the final contribution is rgb·a, so
// bright/opaque texels glow over the scene and dark/transparent ones add nothing — the right
// look for flame, foam/flowing water, and light beams. Untextured effects (no Source
// Texture) fall back to the 1x1 white map.

layout(location = 0) in vec2 v_uv;

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;

layout(location = 0) out vec4 out_color;

void main() {
    vec4 d = texture(u_diffuse, v_uv);
    out_color = vec4(d.rgb, d.a);
}
