#version 450

// One straight-alpha colour per draw, half-lambert off a fixed light so the shape reads.
layout(location = 0) in vec3 v_normal;

layout(set = 3, binding = 0) uniform T {
	vec4 color;
} t;

layout(location = 0) out vec4 out_color;

void main() {
	float shade = 0.5 + 0.5 * dot(normalize(v_normal), normalize(vec3(0.4, 0.6, 1.0)));
	out_color = vec4(t.color.rgb * (0.4 + 0.6 * shade), t.color.a);
}
