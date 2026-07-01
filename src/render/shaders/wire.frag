#version 450

// Debug wireframe fragment shader: a flat bright green for the collision-hitbox overlay.
layout(location = 0) out vec4 o_color;

void main() {
	o_color = vec4(0.15, 1.0, 0.35, 1.0);
}
