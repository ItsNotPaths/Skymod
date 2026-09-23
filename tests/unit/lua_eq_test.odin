package unit_tests

// Papyrus equality fork (build/lua-02-papyrus-eq.patch): runs lua_eq.lua in a bare state.

import "core:strings"
import "core:testing"
import lua "../../vendor/lua"

LUA_EQ_SRC :: #load("lua_eq.lua", string)

@(test)
test_lua_papyrus_eq :: proc(t: ^testing.T) {
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	src := strings.clone_to_cstring(LUA_EQ_SRC)
	defer delete(src)

	if lua.L_dostring(L, src) != 0 {
		testing.fail_now(t, string(lua.tostring(L, -1)))
	}
}
