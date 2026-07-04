// C entry points for Jolt's built-in hierarchical profiler, which upstream joltc
// does not expose. Compiled by build-jolt.sh and appended to lib/libjoltc.a; the
// Odin side is the ProfileNextFrame/ProfileDump foreign decls that download-deps.sh
// appends to vendor/joltc-odin/joltc.odin (link_prefix JPH_). The JPH_PROFILE_*
// macros expand to no-ops unless the lib is built with JOLT_PROFILE=ON
// (-DJPH_PROFILE_ENABLED), so these shims are safe in both configurations.
#include <Jolt/Jolt.h>
#include <Jolt/Core/Profiler.h>

extern "C" {

void JPH_ProfileNextFrame(void)
{
	JPH_PROFILE_NEXTFRAME();
}

// Dump writes profile_<tag>.html (call tree + per-phase timings) to the CWD on the
// next NextFrame(). Tag may be null/empty.
void JPH_ProfileDump(const char *tag)
{
	(void)tag;
	JPH_PROFILE_DUMP(tag != nullptr ? JPH::string_view(tag) : JPH::string_view());
}

} // extern "C"
