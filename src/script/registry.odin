package script

// The native registry — the host side of every script call, keyed (scriptClass,
// functionName) → an Odin implementation. This is the VM-AGNOSTIC mutation layer
// from the phase4-scripting-plan: a transpiled-Lua call, a hand-written mod, or a
// unit test all funnel through the same call() dispatch, so the whole thing is
// built and tested WITHOUT a Lua VM. When the VM lands it's just one more
// front-end — a dispatcher C-function marshalling Lua values into call().
//
// Writes go through the Phase-3 worldstate overlay (set_disabled/set_moved/…);
// reads resolve baseline (gamedb) ⊕ overlay. Forms are the wide Form_ID :: u64.
//
// The full declared API surface (the 674 base-game natives) is auto-stubbed from
// the generated native_manifest: an unimplemented-but-declared call type-checks,
// logs once, and returns None — it never crashes. Only the call-frequency hot set
// (see natives.odin) has real bodies; the long tail stays stubbed until needed.

import "base:runtime"
import "core:log"
import "core:strings"
import "../gamedb"
import "../worldstate"

Form_ID :: gamedb.Form_ID

// PLAYER is the player actor's form — Skyrim's hardcoded 0x14, which in our wide
// Form_ID is master slot 0 (Skyrim.esm), local 0x14.
PLAYER :: Form_ID(0x14)

// Value is a runtime script value. A nil Value is Papyrus None (→ Lua nil).
Value :: union {
	i32,
	f32,
	bool,
	string,
	Form_ID,
}

// Manifest_Entry is one declared native's signature (the generated manifest is a
// table of these). Names carry the canonical declaration casing — the codegen seed
// (Papyrus is case-insensitive, so call sites in the wild use mixed casing).
Manifest_Entry :: struct {
	class:     string,
	fn:        string,
	ret:       string,
	nparams:   int,
	is_global: bool,
}

// Key is a lower-cased "class.fn" (Papyrus identifiers are case-insensitive, so
// every key folds case). Function/class names never contain '.', so the join is
// unambiguous.
Key :: distinct string

Call :: struct {
	self: Form_ID,                 // the receiver; 0 (no form) for global/static calls
	ws:   ^worldstate.World_State, // mutation target (the overlay)
	db:   ^gamedb.DB,              // baseline, for read-through
	reg:  ^Registry,
}

Native :: #type proc(c: ^Call, args: []Value) -> Value

Registry :: struct {
	natives:   map[Key]Native,         // implemented (class.fn) → impl
	declared:  map[Key]Manifest_Entry, // the whole manifest (auto-stub surface)
	warned:    map[Key]bool,           // unimplemented-native log-once guard
	allocator: runtime.Allocator,
}

// init builds the registry: auto-stubs the entire declared manifest, then layers
// the implemented hot set over it.
init :: proc(reg: ^Registry, allocator := context.allocator) {
	reg.allocator = allocator
	reg.natives = make(map[Key]Native, allocator)
	reg.declared = make(map[Key]Manifest_Entry, allocator)
	reg.warned = make(map[Key]bool, allocator)

	for e in native_manifest {
		reg.declared[key_own(e.class, e.fn, allocator)] = e
	}
	register_builtins(reg)
}

destroy :: proc(reg: ^Registry) {
	for k in reg.natives {delete(string(k), reg.allocator)}
	delete(reg.natives)
	for k in reg.declared {delete(string(k), reg.allocator)}
	delete(reg.declared)
	for k in reg.warned {delete(string(k), reg.allocator)}
	delete(reg.warned)
}

// register installs (or overrides) a native implementation.
register :: proc(reg: ^Registry, class, fn: string, impl: Native) {
	reg.natives[key_own(class, fn, reg.allocator)] = impl
}

// call dispatches one native invocation. Three outcomes: implemented → invoke;
// declared-but-unimplemented → log once + return None; unknown → log an error
// (a real bug — a call to something the base game never declared).
call :: proc(reg: ^Registry, class, fn: string, c: ^Call, args: []Value) -> Value {
	c.reg = reg
	k := key_temp(class, fn)
	if impl, ok := reg.natives[k]; ok {
		return impl(c, args)
	}
	if e, ok := reg.declared[k]; ok {
		if k not_in reg.warned {
			reg.warned[key_own(class, fn, reg.allocator)] = true
			log.warnf("script: unimplemented native %s.%s -> None", e.class, e.fn)
		}
		return nil
	}
	log.errorf("script: unknown native %s.%s (not in the declared manifest)", class, fn)
	return nil
}

// is_implemented / is_declared expose registry coverage (used by tests + tooling).
is_implemented :: proc(reg: ^Registry, class, fn: string) -> bool {
	return key_temp(class, fn) in reg.natives
}
is_declared :: proc(reg: ^Registry, class, fn: string) -> bool {
	return key_temp(class, fn) in reg.declared
}

// key_temp builds a lookup key in the temp allocator (no lasting ownership — map
// lookups compare by content, so a transient key matches an owned one).
@(private)
key_temp :: proc(class, fn: string) -> Key {
	joined := strings.concatenate({class, ".", fn}, context.temp_allocator)
	return Key(strings.to_lower(joined, context.temp_allocator))
}

// key_own builds a key whose backing string is owned by `alloc` (for insertion).
@(private)
key_own :: proc(class, fn: string, alloc: runtime.Allocator) -> Key {
	joined := strings.concatenate({class, ".", fn}, context.temp_allocator)
	return Key(strings.to_lower(joined, alloc))
}
