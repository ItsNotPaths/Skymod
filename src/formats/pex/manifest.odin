package pex

// Derivations over a parsed Pex that prime the script registry (phase4 plan
// steps 3–4): the native SIGNATURE MANIFEST (what functions exist, to auto-stub
// the whole API surface) and the native-call HISTOGRAM (which functions get
// called, to rank the implement-hot-set first). Both are corpus-aggregated by the
// caller (tools/pexdump), so the map/clone bookkeeping that outlives a single
// Pex lives here.

import "core:strings"

// Signature is one declared function: enough to key the registry and type-check
// callers. `is_native` marks the engine-provided API surface (no body); the rest
// are script-defined functions (also useful — they're PEX→Lua transpile targets).
Signature :: struct {
	class:     string, // owning object/script name
	fn:        string, // function name
	ret:       string, // return type ("None" = void)
	nparams:   int,
	is_global: bool,
	is_native: bool,
}

// Natives that suspend the calling script, lower "class.fn", keyed by the declaring class
// (Scene.Start does not suspend). The seed is what cannot finish inside one of OUR ticks: the
// `blocking` rows of mydocs/natives-classified.tsv minus the ones we implement as immediate
// (Quest.Start, SetCurrentStageID, Enable, Disable, DamageObject, and SendStoryEventAndWait, which is
// a story-manager walk plus Quest.Start). Message.Show, ShowGiftMenu and ShowLimitedRaceMenu are out too: their menus pause
// the world, so they return within the tick they were called in.
LATENT_GLOBALS := []string{
	"utility.wait",
	"utility.waitmenumode",
	"utility.waitgametime",
	"debug.centeroncellandwait",
	"debug.playermovetoandwait",
	"game.playbink",
}
LATENT_METHODS := []string{
	"objectreference.playanimationandwait",
	"objectreference.playsyncedanimationandwaitss",
	"objectreference.waitforanimationevent",
	"actor.pathtoreference",
	"sound.playandwait",
}

is_latent :: proc(class, fn: string) -> bool {
	key := strings.to_lower(strings.concatenate({class, ".", fn}, context.temp_allocator), context.temp_allocator)
	for k in LATENT_GLOBALS {if k == key {return true}}
	for k in LATENT_METHODS {if k == key {return true}}
	return false
}

// collect_signatures emits one Signature per named function across every object
// and state. Strings ALIAS the Pex string table — valid only while `p` lives; the
// caller must clone anything it keeps past destroy(p). (pexdump uses these only
// for transient per-file printing + native-count tallies.)
collect_signatures :: proc(p: ^Pex, allocator := context.allocator) -> []Signature {
	out := make([dynamic]Signature, allocator)
	for &o in p.objects {
		for &st in o.states {
			for &f in st.functions {
				append(&out, Signature {
					class     = o.name,
					fn        = f.name,
					ret       = f.return_type,
					nparams   = len(f.params),
					is_global = f.is_global,
					is_native = f.is_native,
				})
			}
		}
	}
	return out[:]
}

// tally_calls walks every instruction and increments `counts` per call target,
// keyed "Class.fn" for static calls and "<obj>.fn" for instance calls (the
// static type of the receiver isn't recoverable without type inference, so it's
// folded under a placeholder). Keys are cloned into `allocator` on first sight so
// the map outlives `p`; the caller frees the keys on teardown.
tally_calls :: proc(p: ^Pex, counts: ^map[string]int, allocator := context.allocator) {
	for &o in p.objects {
		for &st in o.states {
			for &f in st.functions {
				for ins in f.instructions {
					key, has := call_key(ins)
					if !has {continue}
					if existing, found := counts[key]; found {
						counts[key] = existing + 1
					} else {
						counts[strings.clone(key, allocator)] = 1
					}
				}
			}
		}
	}
}

// call_key forms the "class.fn" / "<obj>.fn" target string for a call opcode,
// LOWER-CASED — Papyrus identifiers are case-insensitive, so the corpus mixes
// `Game.GetPlayer`/`game.getPlayer`/`SetStage`/`setstage` for the same target;
// folding case is required for an accurate frequency rank (and the registry keys
// the same way). The returned string lives in temp; tally_calls clones it before
// retaining. has=false for non-call opcodes.
@(private)
call_key :: proc(ins: Instruction) -> (key: string, has: bool) {
	raw: string
	#partial switch ins.op {
	case .CallStatic:
		if len(ins.args) >= 2 {
			raw = strings.concatenate({ins.args[0].str, ".", ins.args[1].str}, context.temp_allocator)
		}
	case .CallMethod:
		if len(ins.args) >= 1 {
			raw = strings.concatenate({"<obj>.", ins.args[0].str}, context.temp_allocator)
		}
	case .CallParent:
		if len(ins.args) >= 1 {
			raw = strings.concatenate({"<parent>.", ins.args[0].str}, context.temp_allocator)
		}
	}
	if raw == "" {return "", false}
	return strings.to_lower(raw, context.temp_allocator), true
}
