package main

// magic2lua — the standalone driver for src/magictranslate, for porting a mod: it translates the
// magic records a plugin defines or overrides into Lua the mod then ships.
//
//   odin run tools/magic2lua -- <Data dir> <plugin.esp> [masters...] -o <outdir>
//
// The plugin's masters are read to resolve its references; what they hold is baked into the output
// as it is now (a later mod changing a master's effect does not reach the ported files).

import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "../../src/magictranslate"

main :: proc() {
	context.logger = log.create_console_logger(.Warning)
	args := os.args[1:]
	out := ""
	rest := make([dynamic]string)
	for i := 0; i < len(args); i += 1 {
		if args[i] == "-o" && i + 1 < len(args) {
			out = args[i + 1]
			i += 1
		} else {
			append(&rest, args[i])
		}
	}
	if len(rest) < 2 || out == "" {
		fmt.eprintln("usage: magic2lua <Data dir> <plugin.esp> [masters...] -o <outdir>")
		os.exit(2)
	}
	plugin := rest[1]
	order := make([dynamic]string)
	for name in rest[2:] {
		if !slice.contains(order[:], name) && name != plugin {append(&order, name)} // a plugin twice crashes the load
	}
	append(&order, plugin)
	st, ok := magictranslate.translate(rest[0], order[:], {plugin}, out)
	if !ok {os.exit(1)}
	fmt.printfln("magic2lua: %d spell(s), %d effect(s), %d record(s) not translated yet -> %s", st.spells, st.effects, st.skipped, out)
}
