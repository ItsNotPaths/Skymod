package unit_tests

// Operator fork (build/lua-04-compound-assign.patch, build/lua-05-papyrus-spellings.patch): runs lua_ops.lua in a bare state.

import "core:strings"
import "core:testing"
import lua "../../vendor/lua"

LUA_OPS_SRC :: #load("lua_ops.lua", string)

@(test)
test_lua_ops :: proc(t: ^testing.T) {
	L := lua.L_newstate()
	defer lua.close(L)
	lua.L_openlibs(L)

	src := strings.clone_to_cstring(LUA_OPS_SRC)
	defer delete(src)

	if lua.L_dostring(L, src) != 0 {
		testing.fail_now(t, string(lua.tostring(L, -1)))
	}
}
