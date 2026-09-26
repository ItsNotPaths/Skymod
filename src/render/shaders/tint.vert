#version 450

// World-space positions + normals, flat-coloured by tint.frag.
layout(set = 1, binding = 0) uniform U {
	mat4 vp;
} u;

layout(location = 0) in vec3 pos;
layout(location = 1) in vec3 normal;

layout(location = 0) out vec3 v_normal;

void main() {
	v_normal = normal;
	gl_Position = u.vp * vec4(pos, 1.0);
}
