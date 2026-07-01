#version 450
//
// Stopgap water vertex stage: the quad's vertices are already in world space (one plane
// per cell at the cell's water height), so this just projects them and forwards the world
// position — water.frag does all the procedural ripple/fresnel work per fragment.

layout(set = 1, binding = 0) uniform UBO {
    mat4 vp;
    vec4 cam;
    vec4 sun;
    vec4 deep;
    vec4 shallow;
    vec4 params;
} u;

layout(location = 0) in vec3 in_pos;

layout(location = 0) out vec3 v_world;

void main() {
    v_world = in_pos;
    gl_Position = u.vp * vec4(in_pos, 1.0);
}
