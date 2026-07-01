#version 450
//
// Portal STENCIL-MARK fragment shader. Used by portal_mark_pipeline: the doorway quad is
// depth-tested (so a wall in front of the door hides it) and, where it passes, writes
// stencil = 1. Color is masked off in the pipeline, and we deliberately do NOT write
// gl_FragDepth here — the depth test must use the quad's real depth to know whether the
// door is the nearest surface. The output exists only to satisfy the pipeline.

layout(location = 0) out vec4 o_color;

void main() {
    o_color = vec4(0.0);
}
