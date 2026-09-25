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
// The full declared API surface (the 686 natives LE and SE declare together) is
// auto-stubbed from the generated native_manifest: an unimplemented-but-declared call
// type-checks, logs once, and returns its fallback (native_fallbacks) — it never crashes.
// Only the call-frequency hot set (see natives.odin) has real bodies; the long tail
// stays stubbed until needed.

import "base:runtime"
import "core:log"
import "core:strings"
import "../gamedb"
import "../worldstate"

Form_ID :: gamedb.Form_ID


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
	latent:    bool, // suspends the caller (pex.LATENT_GLOBALS / LATENT_METHODS)
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
// declared-but-unimplemented → warn once + return its fallback; unknown → warn once +
// None (a call the manifest never declared: usually a form whose kind resolved wrong, rt.odin).
call :: proc(reg: ^Registry, class, fn: string, c: ^Call, args: []Value) -> Value {
	c.reg = reg
	k := key_temp(class, fn)
	if impl, ok := reg.natives[k]; ok {
		return impl(c, args)
	}
	first := k not_in reg.warned
	if first {reg.warned[key_own(class, fn, reg.allocator)] = true}
	if e, ok := reg.declared[k]; ok {
		v := fallback(e)
		if first {log.warnf("script: unimplemented native %s.%s -> %v", e.class, e.fn, v)}
		return v
	}
	if first {log.warnf("script: unknown native %s.%s (not in the declared manifest)", class, fn)}
	return nil
}

// FAR_DISTANCE is GetDistance between refs in different cells or worldspaces, or with no position.
FAR_DISTANCE :: f32(1e9)

// native_fallbacks is what a stub answers where its type's zero would be wrong: Papyrus's
// documented value, else the absent, quiet, done answer (docs/script-rewrite.md "Missing data").
native_fallbacks := []struct {
	class, fn: string,
	value:     Value,
}{
	{"Actor", "GetLightLevel", f32(100)}, // bright: a "dark" check (< 30) stays quiet
}

fallback :: proc(e: Manifest_Entry) -> Value {
	for f in native_fallbacks {
		if f.class == e.class && f.fn == e.fn {return f.value}
	}
	return zero_of(e.ret)
}

// zero_of is a type's zero. Object types stay None, which is their real zero;
// a None for bool would reach Lua as the truthy None sentinel.
zero_of :: proc(type_name: string) -> Value {
	switch strings.to_lower(type_name, context.temp_allocator) {
	case "bool":   return false
	case "int":    return i32(0)
	case "float":  return f32(0)
	case "string": return ""
	}
	return nil
}

// none_value is what a call named `fn` returns on None: the zero of the first declared native of that
// name (Papyrus: a call on None returns its type's default). ok is false when no native has the name.
none_value :: proc(fn: string) -> (v: Value, ok: bool) {
	for e in native_manifest {
		if strings.equal_fold(e.fn, fn) {return zero_of(e.ret), true}
	}
	return nil, false
}

// is_engine_class reports whether `name` is one of the engine's own Papyrus classes (a manifest
// class, or ScriptObject), as opposed to a script's class.
is_engine_class :: proc(name: string) -> bool {
	if strings.equal_fold(name, "ScriptObject") {return true}
	for e in native_manifest {
		if strings.equal_fold(e.class, name) {return true}
	}
	return false
}

// is_implemented / is_declared expose registry coverage (used by tests + tooling).
is_implemented :: proc(reg: ^Registry, class, fn: string) -> bool {
	return key_temp(class, fn) in reg.natives
}
is_declared :: proc(reg: ^Registry, class, fn: string) -> bool {
	return key_temp(class, fn) in reg.declared
}

// REF_CLASS_CHAIN is the object-ref method-resolution order, most-derived first.
// A `ref:Method()` call walks it and dispatches to the first class that declares
// the method — Papyrus resolves methods up the script class chain the same way.
// This is the naive-first chain (Actor → ObjectReference → Form): enough to split
// actor-only verbs from the object-ref bulk. Used for object refs and for any form
// whose kind isn't specially classified. Global-only classes (Game/Debug/Utility)
// are never on a ref. Package-level (not a literal) so the returned slice is stable.
REF_CLASS_CHAIN := []string{"Actor", "ObjectReference", "Form"}

// EFFECT_CLASS_CHAIN: ActiveMagicEffect extends nothing in Papyrus.
EFFECT_CLASS_CHAIN := []string{"ActiveMagicEffect"}

// KIND_CHAIN is the method-resolution order for each Form-SUBTYPE handle: a Quest/GlobalVariable/
// Weapon/… form resolves methods up its own class then Form (Papyrus's hierarchy). The class name
// comes from gamedb.class_name (the single source of truth). Package-level so class_chain returns a
// stable slice. .Unknown's entry is unused (class_chain routes it to REF_CLASS_CHAIN). Together with
// the gamedb form→kind map this replaces the fixed chain with a per-form one (the record decoder).
KIND_CHAIN := [gamedb.Form_Kind][2]string {
	.Unknown            = {"ObjectReference", "Form"}, // unused — Unknown uses REF_CLASS_CHAIN
	.Quest              = {gamedb.class_name(.Quest), "Form"},
	.Global             = {gamedb.class_name(.Global), "Form"},
	.Faction            = {gamedb.class_name(.Faction), "Form"},
	.ActorBase          = {gamedb.class_name(.ActorBase), "Form"},
	.Weapon             = {gamedb.class_name(.Weapon), "Form"},
	.Potion             = {gamedb.class_name(.Potion), "Form"},
	.Ingredient         = {gamedb.class_name(.Ingredient), "Form"},
	.Scroll             = {gamedb.class_name(.Scroll), "Form"},
	.Spell              = {gamedb.class_name(.Spell), "Form"},
	.Enchantment        = {gamedb.class_name(.Enchantment), "Form"},
	.Keyword            = {gamedb.class_name(.Keyword), "Form"},
	.FormList           = {gamedb.class_name(.FormList), "Form"},
	.MagicEffect        = {gamedb.class_name(.MagicEffect), "Form"},
	.Location           = {gamedb.class_name(.Location), "Form"},
	.Weather            = {gamedb.class_name(.Weather), "Form"},
	.Cell_              = {gamedb.class_name(.Cell_), "Form"},
	.Sound              = {gamedb.class_name(.Sound), "Form"},
	.VisualEffect       = {gamedb.class_name(.VisualEffect), "Form"},
	.EffectShader       = {gamedb.class_name(.EffectShader), "Form"},
	.Scene              = {gamedb.class_name(.Scene), "Form"},
	.ImageSpaceModifier = {gamedb.class_name(.ImageSpaceModifier), "Form"},
	.LeveledItem        = {gamedb.class_name(.LeveledItem), "Form"},
	.Message            = {gamedb.class_name(.Message), "Form"},
	.MusicType          = {gamedb.class_name(.MusicType), "Form"},
	.SoundCategory      = {gamedb.class_name(.SoundCategory), "Form"},
	.ShaderParticleGeometry= {gamedb.class_name(.ShaderParticleGeometry), "Form"},
	.Package            = {gamedb.class_name(.Package), "Form"},
	.LeveledSpell       = {gamedb.class_name(.LeveledSpell), "Form"},
	.LeveledActor       = {gamedb.class_name(.LeveledActor), "Form"},
	.TopicInfo          = {gamedb.class_name(.TopicInfo), "Form"},
	.Topic              = {gamedb.class_name(.Topic), "Form"},
	.Light              = {gamedb.class_name(.Light), "Form"},
	.Armor              = {gamedb.class_name(.Armor), "Form"},
	.Ref_Alias          = {gamedb.class_name(.Ref_Alias), "Alias"},
	.Location_Alias     = {gamedb.class_name(.Location_Alias), "Alias"},
	.Active_Effect      = {"ActiveMagicEffect", "ActiveMagicEffect"}, // unused — see EFFECT_CLASS_CHAIN
}

// class_chain picks the method-resolution order for a form's kind. Unknown (object
// refs / unclassified) keeps the naive object-ref chain, preserving prior behaviour.
class_chain :: proc(kind: gamedb.Form_Kind) -> []string {
	if kind == .Unknown {
		return REF_CLASS_CHAIN
	}
	if kind == .Active_Effect {
		return EFFECT_CLASS_CHAIN
	}
	return KIND_CHAIN[kind][:]
}

// class_display is a form kind's `__tostring` class: the ref's nominal class ("ObjectReference"
// for Unknown / object refs), else its most-derived class. Distinct from class_chain[0], which is
// "Actor" for Unknown (the dispatch chain), not what a bare object ref should print as.
class_display :: proc(kind: gamedb.Form_Kind) -> string {
	return gamedb.class_name(kind)
}

// method_class resolves which class in a form's chain owns `fn`. `kind` selects the
// chain (default Unknown = the object-ref chain, so existing callers are unchanged).
// Returns the first declared/implemented class (ok=true); on a miss it falls back so
// the call still dispatches + logs through the normal path — "ObjectReference" for the
// object-ref/Unknown chain (as before), else the form's own most-derived class.
method_class :: proc(reg: ^Registry, fn: string, kind := gamedb.Form_Kind.Unknown) -> (class: string, ok: bool) {
	chain := class_chain(kind)
	for c in chain {
		if is_implemented(reg, c, fn) || is_declared(reg, c, fn) {
			return c, true
		}
	}
	if kind == .Unknown {
		return "ObjectReference", false
	}
	return chain[0], false
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
