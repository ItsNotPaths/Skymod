package script_lua

// The script-visible ref system — decision #1 (refs) and #2 (None) of the locked
// Phase-4 substrate (docs/script-runtime-decisions.md).
//
// A ref is a Lua FULL USERDATA wrapping the wide u64 Form_ID (the same identity as
// overlay keys, the save form-table, and gamedb). It is NOT a plain integer: the
// metatable makes `ref:Method(args)` dispatch up the class chain into the registry,
// `tostring(ref)` self-describe as `[Class 0xFORMID "editorid"]`, and `==` be form
// identity. One userdata per Form_ID, kept in a WEAK-VALUED registry cache so
// `push_ref` twice for the same form yields the same object (Papyrus `==` semantics)
// and GC reclaims handles nothing references.
//
// None is a single sentinel userdata (Papyrus None is a runtime value, not nil):
// its metatable ABSORBS any method call — logs once, returns None — so None
// propagates through call chains like the vanilla null-object. The patched Lua makes
// it falsy (`if x` is false for None) and `None == nil` true, so it reads as Papyrus.

import "core:c"
import "core:fmt"
import "core:log"
import "core:strings"
import lua "../../../vendor/lua"
import "../../gamedb"
import script ".."

// Registry keys / metatable names. The metatables live in the Lua registry under
// their names (L_newmetatable); the cache and the singleton None sit beside them.
@(private)
REF_MT :: "skymod.ref"
@(private)
NONE_MT :: "skymod.none"
@(private)
REF_CACHE_KEY :: "skymod.ref.cache"
@(private)
NONE_VALUE_KEY :: "skymod.none.value"

// setup_ref_system installs the ref + None metatables, the weak cache, and the
// `ref()` / `None` globals into vm.L. Called from init() so EVERY VM can marshal a
// Form_ID → ref (push_value depends on the metatables existing). ^VM rides as a
// closure upvalue so the metamethod C bridges can reach the registry + call context.
@(private)
setup_ref_system :: proc(vm: ^VM) {
	L := vm.L

	// ── ref metatable ─────────────────────────────────────────────────────────
	lua.L_newmetatable(L, REF_MT) // pushes the fresh metatable
	lua.pushlightuserdata(L, vm)
	lua.pushcclosure(L, ref_index, 1)
	lua.setfield(L, -2, "__index")
	lua.pushlightuserdata(L, vm)
	lua.pushcclosure(L, ref_tostring, 1)
	lua.setfield(L, -2, "__tostring")
	lua.pushcfunction(L, papyrus_eq)
	lua.setfield(L, -2, "__eq")
	lua.pushstring(L, "ref")
	lua.setfield(L, -2, "__name")
	lua.pop(L, 1) // pop the metatable

	// ── weak-valued cache: registry[REF_CACHE_KEY] = setmetatable({}, {__mode="v"})
	lua.newtable(L) // the cache
	lua.newtable(L) // its metatable
	lua.pushstring(L, "v")
	lua.setfield(L, -2, "__mode")
	lua.setmetatable(L, -2) // pops the metatable, sets it on the cache
	lua.setfield(L, lua.REGISTRYINDEX, REF_CACHE_KEY) // pops the cache

	// ── None metatable + the singleton sentinel ───────────────────────────────
	lua.L_newmetatable(L, NONE_MT)
	lua.pushlightuserdata(L, vm)
	lua.pushcclosure(L, none_index, 1)
	lua.setfield(L, -2, "__index")
	lua.pushcfunction(L, none_call)
	lua.setfield(L, -2, "__call")
	lua.pushcfunction(L, none_tostring)
	lua.setfield(L, -2, "__tostring")
	lua.pushcfunction(L, papyrus_eq)
	lua.setfield(L, -2, "__eq")
	lua.pushstring(L, "None")
	lua.setfield(L, -2, "__name")
	lua.pop(L, 1)
	lua.newuserdatauv(L, 1, 0) // 1-byte payload (unused) — identity is the pointer
	lua.L_setmetatable(L, NONE_MT)
	lua.setfalsy(L, -1, 1) // `if x` is false for None (build/lua-03-falsy-userdata.patch)
	lua.setfield(L, lua.REGISTRYINDEX, NONE_VALUE_KEY) // stash the one None

	// ── globals: ref(formid) constructor + None ───────────────────────────────
	lua.pushcfunction(L, ref_ctor)
	lua.setglobal(L, "ref")
	push_none(L)
	lua.setglobal(L, "None")
}

// push_ref pushes the ref userdata for `form`, creating+caching it on first use.
// form 0 (no form) pushes None — a null ref reads as None everywhere.
push_ref :: proc "contextless" (L: ^lua.State, form: script.Form_ID) {
	if form == 0 {
		push_none(L)
		return
	}
	lua.getfield(L, lua.REGISTRYINDEX, REF_CACHE_KEY) // [cache]
	lua.rawgeti(L, -1, lua.Integer(form)) // [cache, ref-or-nil]
	if !lua.isnil(L, -1) {
		lua.replace(L, -2) // [ref]
		return
	}
	lua.pop(L, 1) // pop the nil → [cache]
	ud := cast(^u64)lua.newuserdatauv(L, size_of(u64), 0) // [cache, ud]
	ud^ = u64(form)
	lua.L_setmetatable(L, REF_MT)
	lua.pushvalue(L, -1) // [cache, ud, ud]
	lua.rawseti(L, -3, lua.Integer(form)) // cache[form]=ud → [cache, ud]
	lua.replace(L, -2) // [ud]
}

// push_none pushes the singleton None sentinel.
push_none :: proc "contextless" (L: ^lua.State) {
	lua.getfield(L, lua.REGISTRYINDEX, NONE_VALUE_KEY)
}

// ref_form reads the Form_ID out of a ref userdata at `idx`. ok=false if the value
// there isn't one of our refs (wrong userdata / a different type). None is not a ref
// — it reads back as form 0 via to_value, not here.
ref_form :: proc "contextless" (L: ^lua.State, idx: c.int) -> (form: script.Form_ID, ok: bool) {
	p := lua.L_testudata(L, idx, REF_MT)
	if p == nil {
		return 0, false
	}
	return script.Form_ID((cast(^u64)p)^), true
}

// is_none reports whether the value at `idx` is the None sentinel.
is_none :: proc "contextless" (L: ^lua.State, idx: c.int) -> bool {
	return lua.L_testudata(L, idx, NONE_MT) != nil
}

// ── metamethods ────────────────────────────────────────────────────────────────

// ref_index(self, key) → a bound method closure. The closure carries (^VM, key) and,
// when called as `self:key(...)`, resolves the class chain and dispatches. Creating a
// closure per method *access* is fine for the console/REPL; hot transpiled paths can
// memoise later. Upvalue 1 = ^VM.
@(private)
ref_index :: proc "c" (L: ^lua.State) -> c.int {
	// arg 1 = self (ref), arg 2 = key. Carry ^VM + key into the method closure.
	lua.pushvalue(L, upvalueindex(1)) // ^VM lightuserdata
	lua.pushvalue(L, 2) // the method name
	lua.pushcclosure(L, ref_method, 2)
	return 1
}

// ref_method is the bound-method closure. Upvalues: 1=^VM, 2=method name (string).
// Called `self:Method(a, b, …)` → self is arg 1, the args follow.
@(private)
ref_method :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context

	fn := to_string(L, upvalueindex(2))
	form, ok := ref_form(L, 1)
	if !ok {
		lua.L_error(L, "ref method '%s' called on a non-ref", lua.tostring(L, upvalueindex(2)))
		return 0
	}

	push_value(L, call_method(vm, L, form, fn, 2))
	return 1
}

// call_method calls native `fn` on `form` with the Lua arguments from `first` on. The form's kind
// (QUST/GLOB/FACT/…) picks the class chain, so a Quest handle dispatches up {Quest, Form}, not the
// object-ref chain. db may be nil (headless) → Unknown → the object-ref chain.
@(private)
call_method :: proc(vm: ^VM, L: ^lua.State, form: script.Form_ID, fn: string, first: c.int) -> script.Value {
	n := lua.gettop(L)
	args := make([dynamic]script.Value, 0, max(int(n - first + 1), 0), context.temp_allocator)
	for i in first ..= n {
		append(&args, to_value(L, i))
	}
	class, _ := script.method_class(vm.reg, fn, gamedb.form_kind(vm.ctx.db, form))
	cc := vm.ctx
	cc.self = form
	return script.call(vm.reg, class, fn, &cc, args[:])
}

// ref_tostring → `[Class 0xFORMID "editorid"]`. The class is the ref-chain class the
// gamedb record resolves to (naive: ObjectReference until records land a form→class);
// the label is the editor id where the DB knows one, else omitted. Upvalue 1 = ^VM.
@(private)
ref_tostring :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context
	form, ok := ref_form(L, 1)
	if !ok {
		lua.pushstring(L, "[ref ?]")
		return 1
	}
	// The form's real class: a weapon base prints [Weapon …], a quest [Quest …]; object refs
	// and unclassified forms stay [ObjectReference …]. db may be nil (headless) → Unknown.
	class := script.class_display(gamedb.form_kind(vm.ctx.db, form))
	label := ref_label(vm, form)
	if label != "" {
		lua.pushstring(L, tcstr("[%s 0x%08X \"%s\"]", class, u64(form), label))
	} else {
		lua.pushstring(L, tcstr("[%s 0x%08X]", class, u64(form)))
	}
	return 1
}

// tcstr formats into a temp-allocator cstring (for pushstring). Needs `context` set
// — every caller runs after `context = vm.host_context`.
@(private)
tcstr :: proc(format: string, args: ..any) -> cstring {
	return strings.clone_to_cstring(fmt.tprintf(format, ..args), context.temp_allocator)
}

// papyrus_eq is `==` for refs and None, the Papyrus rule: a ref, a script instance (its .form)
// and None/nil each reduce to a form (None is 0), and equal forms are equal. The patched VM
// consults __eq across types, so `ref == inst` and `None == nil` both land here.
@(private)
papyrus_eq :: proc "c" (L: ^lua.State) -> c.int {
	a, aok := papyrus_form(L, 1)
	b, bok := papyrus_form(L, 2)
	lua.pushboolean(L, b32(aok && bok && a == b))
	return 1
}

@(private)
papyrus_form :: proc "contextless" (L: ^lua.State, idx: c.int) -> (form: script.Form_ID, ok: bool) {
	if lua.isnoneornil(L, idx) || is_none(L, idx) {
		return 0, true
	}
	if lua.type(L, idx) == .TABLE {
		lua.getfield(L, idx, "form")
		defer lua.pop(L, 1)
		return ref_form(L, -1)
	}
	return ref_form(L, idx)
}

// ref_ctor is the `ref(formid)` global: wrap an integer Form_ID as a ref (bare-hex
// console input rewrites to this). A non-integer / 0 argument yields None.
@(private)
ref_ctor :: proc "c" (L: ^lua.State) -> c.int {
	if lua.isinteger(L, 1) {
		push_ref(L, script.Form_ID(lua.tointeger(L, 1)))
	} else {
		push_none(L)
	}
	return 1
}

// none_index answers a name read on None (logged once per name). A native's name gives a caller
// that returns that native's zero, so `None:GetValue() + 1` is 1.0 as in Papyrus; any other name
// is None, so `None.x` is falsy and `None:f()` calls None, which none_call absorbs.
@(private)
none_index :: proc "c" (L: ^lua.State) -> c.int {
	vm := cast(^VM)lua.touserdata(L, upvalueindex(1))
	context = vm.host_context
	name := to_string(L, 2)
	warn_none_once(vm, name)
	if v, ok := script.none_value(name); ok {
		push_value(L, v)
		lua.pushcclosure(L, none_returns, 1)
		return 1
	}
	push_none(L)
	return 1
}

// none_returns is a native's call on None: it returns its upvalue, the native's zero.
@(private)
none_returns :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushvalue(L, upvalueindex(1))
	return 1
}

@(private)
none_call :: proc "c" (L: ^lua.State) -> c.int {
	push_none(L)
	return 1
}

@(private)
none_tostring :: proc "c" (L: ^lua.State) -> c.int {
	lua.pushstring(L, "None")
	return 1
}

// ── host-side helpers (need the Odin `context`) ─────────────────────────────────

// ref_label returns the DB's human label for a form (editor id) or "". gamedb only
// indexes cell/world editor ids today; arbitrary base/ref labels arrive with the
// record + STRINGS decoders. Until then most refs print id-only, which is fine.
@(private)
ref_label :: proc(vm: ^VM, form: script.Form_ID) -> string {
	db := vm.ctx.db
	if db == nil {
		return ""
	}
	// A form's FULL display name (localized STRINGS or inline), resolved ref → base — the
	// human label for objects/actors/items. Cells and worldspaces carry no FULL, so fall
	// back to their editor id.
	if n := gamedb.name_of(db, form); n != "" {
		return n
	}
	if cell, ok := gamedb.cell_by_formid(db, form); ok && cell.editor_id != "" {
		return cell.editor_id
	}
	if id := gamedb.world_editor_id(db, form); id != "" {
		return id
	}
	return ""
}

// warn_none_once logs a None method-absorption a single time per method name, so a
// script hammering None doesn't flood the log (decision #2: "log-once, return None").
@(private)
warn_none_once :: proc(vm: ^VM, method: string) {
	if method in vm.none_warned {
		return
	}
	vm.none_warned[method] = true
	log.warnf("script: None.%s absorbed → None", method)
}
