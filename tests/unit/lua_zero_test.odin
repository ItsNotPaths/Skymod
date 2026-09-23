package unit_tests

// 0-based Lua fork (build/lua-zero-index.patch): runs lua_zero.lua in a bare state.

import "core:strings"
import "core:testing"
import lua "../../vendor/lua"

LUA_ZERO_SRC :: #load("lua_zero.lua", string)

@(test)
test_lua_zero_index :: proc(t: ^testing.T) {
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	src := strings.clone_to_cstring(LUA_ZERO_SRC)
	defer delete(src)

	if lua.L_dostring(L, src) != 0 {
		testing.fail_now(t, string(lua.tostring(L, -1)))
	}
}
