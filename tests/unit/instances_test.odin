package unit_tests

// Script instances at runtime (src/script/lua/instances.odin + rt.attach): plugin property values
// reach a script's members, OnInit fires on every instance, and a runaway handler is stopped by the
// instruction budget without stopping the next one. Hermetic: a temp scripts dir, no game files.

import "core:os"
import "core:path/filepath"
import "core:testing"
import "../../src/formats/esm"
import "../../src/gamedb"
import "../../src/script"
import slua "../../src/script/lua"
import "../../src/worldstate"

@(private = "file")
PROPS_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Props", nil)
C.__vars = {
  ["::target_var"] = { type = "objectreference", default = nil },
  ["::via_alias_var"] = { type = "objectreference", default = nil },
  ["::count_var"] = { type = "Int", default = nil },
  ["::speed_var"] = { type = "Float", default = nil },
  ["::on_var"] = { type = "Bool", default = nil },
  ["::label_var"] = { type = "String", default = nil },
  ["::list_var"] = { type = "Int[]", default = nil },
  ["::unset_var"] = { type = "Int", default = nil },
}
for _, p in ipairs({ "target", "via_alias", "count", "speed", "on", "label", "list", "unset" }) do
  C.__autoprop[p] = "::" .. p .. "_var"
end
C.__fn["oninit"] = function(self)
  local v = self.vars
  __seen = {
    target = v["::target_var"] === ref(0x5000),
    alias_none = v["::via_alias_var"] == nil and not v["::via_alias_var"],
    count = v["::count_var"] === 7,
    speed = v["::speed_var"] == 1.5,
    on = v["::on_var"] === true,
    label = v["::label_var"] === "Hello",
    list = rt.alen(v["::list_var"]) == 3 and rt.aget(v["::list_var"], 2) == 30,
    unset = v["::unset_var"] === 0,
  }
end
return C
`

@(private = "file")
SPIN_LUA :: `local rt = require('skymod.rt')
local C = rt.class("Spin", nil)
C.__fn["oninit"] = function(self) while true do end end
return C
`

@(private = "file")
AFTER_LUA :: `local rt = require('skymod.rt')
local C = rt.class("After", nil)
C.__fn["oninit"] = function(self) __after = true end
return C
`

@(test)
test_attach_props_and_oninit :: proc(t: ^testing.T) {
	tmp, _ := os.temp_dir(context.temp_allocator)
	dir, _ := filepath.join({tmp, "skymod_instances_test"}, context.temp_allocator)
	os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	for f in ([][2]string{{"props.lua", PROPS_LUA}, {"spin.lua", SPIN_LUA}, {"after.lua", AFTER_LUA}}) {
		p, _ := filepath.join({dir, f[0]}, context.temp_allocator)
		testing.expect(t, os.write_entire_file(p, transmute([]u8)f[1]) == nil, "write fixture")
	}

	reg: script.Registry
	script.init(&reg)
	defer script.destroy(&reg)
	ws: worldstate.World_State
	worldstate.init(&ws)
	defer worldstate.destroy(&ws)
	db: gamedb.DB
	vm: slua.VM
	testing.expect(t, slua.init(&vm, &reg, script.Call{ws = &ws, db = &db}), "VM init")
	defer slua.destroy(&vm)
	slua.set_script_dirs(&vm, {dir})

	props := []esm.Script_Prop {
		{name = "Target", kind = .Object, status = 1, value = esm.Prop_Object{form = 0x5000, alias = -1}},
		{name = "Via_Alias", kind = .Object, status = 1, value = esm.Prop_Object{form = 0x6000, alias = 0}},
		{name = "Count", kind = .Int, status = 1, value = i32(7)},
		{name = "Speed", kind = .Float, status = 1, value = f32(1.5)},
		{name = "On", kind = .Bool, status = 1, value = true},
		{name = "Label", kind = .String, status = 1, value = "Hello"},
		{name = "List", kind = .Int_Array, status = 1, value = []i32{10, 20, 30}},
		{name = "Unset", kind = .Int, status = 3, value = i32(99)}, // removed: stays at the type's zero
	}
	scripts := []esm.Script_Attach{{name = "Props", props = props}, {name = "Spin"}, {name = "After"}}
	// The spin handler exceeds the budget by design and warns; that is not a test failure.
	made := slua.attach(&vm, script.Form_ID(0x1234), scripts, true)
	testing.expect_value(t, made, 3)

	ok := slua.do_string(&vm, `
		for k, v in pairs(__seen) do assert(v, "property " .. k) end
		assert(__after, "OnInit after a runaway handler still ran")`)
	testing.expect(t, ok, "OnInit saw every property value, and the budget stopped only the runaway")
}
