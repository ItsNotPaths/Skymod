#version 450
//
// Alpha-tested shadow caster fragment stage (ROADMAP full-scene-lighting Phase D2). For foliage
// (leaves/plants): discard fragments below the diffuse-alpha cutoff so the shadow takes the cutout
// shape instead of a solid quad. No color output — depth only.

layout(location = 0) in vec2 v_uv;
layout(location = 1) in float v_cutoff;

layout(set = 2, binding = 0) uniform sampler2D u_diffuse;

void main() {
    if (texture(u_diffuse, v_uv).a < v_cutoff) discard;
}
