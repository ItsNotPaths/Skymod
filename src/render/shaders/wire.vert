#version 450

// Debug wireframe vertex shader: world-space positions (the collision-hitbox overlay feeds
// already-world-space geometry), projected by the view-projection in the UBO.
layout(set = 1, binding = 0) uniform U {
	mat4 vp;
} u;

layout(location = 0) in vec3 pos;

void main() {
	gl_Position = u.vp * vec4(pos, 1.0);
}
