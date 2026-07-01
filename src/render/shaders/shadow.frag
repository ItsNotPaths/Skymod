#version 450
//
// Shadow caster fragment stage (ROADMAP full-scene-lighting Phase D1). Empty — the shadow pass has
// no color target and only writes depth. A fragment shader is provided (rather than none) for
// portability across SDL3_gpu backends; D2 will add an alpha-test discard here for foliage casters.

void main() {
}
