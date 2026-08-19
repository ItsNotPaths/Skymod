package gamedb

// Perk indexing: the PERK records themselves, and the perk-TREE layout that AVIF carries. The two
// halves answer different questions. A PERK says what a perk is called, whether the player may take
// it, and which perk is its next rank. An AVIF perk tree says where each perk sits in its skill's
// constellation and which nodes it connects to — the data the stats menu draws.
//
// Decoders live in src/formats/esm/records_actors.odin; this file owns the storage and the queries.
//
// NOT decoded: perk ENTRIES (the PRKE/EPFT/EPFD blocks) — the gameplay effects a perk applies, and
// the CTDA conditions that gate them. An entry drives the combat and magic systems, which do not
// exist yet, so decoding it would produce another dangling link. The menu needs none of it: it
// draws the tree from AVIF and reads names off the PERK header.

import "core:strings"
import "../formats/esm"

// Perk is a PERK record's identity and rank link.
Perk :: struct {
	name:        string, // FULL, owned. "" when absent — 342 of the 375 carry one.
	description: string, // DESC, owned. The card text the stats menu shows.
	next_rank:   Form_ID, // NNAM, remapped. The next perk in this chain, 0 at the last rank.
	min_level:   u8,     // DATA min level. Always 0 across the base game.
	num_ranks:   u8,     // DATA rank count, AS AUTHORED — unreliable, use perk_ranks instead.
	trait:       bool,
	playable:    bool, // The player may take it: 347 of 375. The rest are NPC or quest perks.
	hidden:      bool, // Taken by script, never drawn in the tree: 42 of 375.
}

// Perk_Node is one star in a skill's constellation — a perk plus where it sits and what it links to.
Perk_Node :: struct {
	perk:        Form_ID, // PNAM, remapped. 0 marks the tree ROOT (see index_perk_tree).
	index:       u32,     // INAM — this node's id WITHIN its tree, which connections address.
	grid:        [2]u32,  // XNAM/YNAM coarse grid cell.
	pos:         [2]f32,  // HNAM/VNAM fine offset within the cell.
	connections: []u32,   // CNAM node indices this one leads to, owned.
}

// free_perk releases a Perk's owned strings.
@(private)
free_perk :: proc(db: ^DB, p: Perk) {
	delete(p.name, db.allocator)
	delete(p.description, db.allocator)
}

// free_perk_tree releases a tree's nodes and their connection lists.
@(private)
free_perk_tree :: proc(db: ^DB, nodes: []Perk_Node) {
	for n in nodes {
		delete(n.connections, db.allocator)
	}
	delete(nodes, db.allocator)
}

// index_perk decodes a PERK's identity. FULL and DESC are short text, so both resolve through plain
// STRINGS (verified: all 342 FULL and all 375 DESC ids resolve there, 0 in DLSTRINGS).
@(private)
index_perk :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec) // heap scratch; freed below
	if !ok {
		return
	}
	defer delete(fl)
	defer if backing != nil {delete(backing)}

	h, hok := esm.perk_header(fl)
	if !hok {
		return
	}
	if old, existed := db.perks[rec.form_id]; existed {
		free_perk(db, old) // override: free the previous plugin's clone
	}

	p := Perk {
		min_level = h.min_level,
		num_ranks = h.num_ranks,
		trait     = h.trait,
		playable  = h.playable,
		hidden    = h.hidden,
	}
	if f, fok := esm.find_field(fl, "FULL"); fok {
		p.name = strings.clone(resolve_lstring(db, f, db.cur_strings), db.allocator)
	}
	if f, dok := esm.find_field(fl, "DESC"); dok {
		p.description = strings.clone(resolve_lstring(db, f, db.cur_strings), db.allocator)
	}
	if n, nok := esm.subrecord_formid(fl, "NNAM"); nok && n != 0 {
		p.next_rank = esm.remap_form(fm, n)
	}
	db.perks[rec.form_id] = p
}

// index_perk_tree decodes the perk-tree nodes an AVIF carries and files them under that skill.
// Called from index_actor_value, because the nodes trail the actor-value identity in the same
// record. A non-skill AVIF has no nodes and stores nothing — 18 of the 149 records carry a tree,
// one per skill, holding 198 nodes between them.
//
// LAYOUT. Each node is the run `PNAM FNAM XNAM YNAM HNAM VNAM SNAM [CNAM...] INAM`, so PNAM opens a
// node and the fields that follow belong to it until the next PNAM. CNAM is overloaded: the copy
// BEFORE the first PNAM is the record's own, and only the ones inside a node are connections, which
// is why this tracks whether a node is open. Verified against AVOneHanded — Armsman is the trunk
// and connects to Bladesman, Hack and Slash, Bone Breaker, Fighting Stance and Dual Flurry, exactly
// the vanilla constellation.
//
// THE ROOT NODE. Every tree in the base game and the DLC opens with a node whose PNAM is 0. It is the skill's trunk, and its
// connections name the perks the tree starts from, so it is kept. Its grid and position fields hold
// uninitialized Creation Kit junk — AVConjuration's read as fragments of ASCII — so they are zeroed
// here rather than passed on. FNAM is dropped: it reads 1 on all 180 real nodes and garbage on the
// roots, so it carries nothing. SNAM is dropped too: every node points back at its own record.
@(private)
index_perk_tree :: proc(db: ^DB, rec: esm.Record, fl: []esm.Field, fm: ^esm.Form_Map) {
	nodes := make([dynamic]Perk_Node, 0, 16, db.allocator)
	conns := make([dynamic]u32, 0, 4, context.temp_allocator)

	flush := proc(nodes: ^[dynamic]Perk_Node, conns: ^[dynamic]u32, allocator := context.allocator) {
		if len(nodes) == 0 {
			return
		}
		cur := &nodes[len(nodes) - 1]
		cur.connections = make([]u32, len(conns), allocator)
		copy(cur.connections, conns[:])
		clear(conns)
	}

	open := false
	for f in fl {
		switch f.type {
		case "PNAM":
			flush(&nodes, &conns, db.allocator) // close the previous node
			local, _ := esm.field_u32(f)
			append(&nodes, Perk_Node{perk = esm.remap_form(fm, local)}) // 0 stays 0: the root

			open = true
		case "XNAM":
			if open {
				nodes[len(nodes) - 1].grid.x, _ = esm.field_u32(f)
			}
		case "YNAM":
			if open {
				nodes[len(nodes) - 1].grid.y, _ = esm.field_u32(f)
			}
		case "HNAM":
			if open {
				nodes[len(nodes) - 1].pos.x, _ = esm.field_f32(f)
			}
		case "VNAM":
			if open {
				nodes[len(nodes) - 1].pos.y, _ = esm.field_f32(f)
			}
		case "CNAM":
			if open {
				if v, vok := esm.field_u32(f); vok {
					append(&conns, v)
				}
			}
		case "INAM":
			if open {
				nodes[len(nodes) - 1].index, _ = esm.field_u32(f)
			}
		}
	}
	flush(&nodes, &conns, db.allocator) // close the last node

	if len(nodes) == 0 {
		delete(nodes)
		return
	}
	// The root's placement fields are junk; only its connections mean anything.
	for &n in nodes {
		if n.perk == 0 {
			n.grid = {}
			n.pos = {}
		}
	}
	if old, existed := db.perk_trees[rec.form_id]; existed {
		free_perk_tree(db, old)
	}
	db.perk_trees[rec.form_id] = nodes[:]
}

// --- queries ----------------------------------------------------------------------------

// perk_of returns a PERK's identity. Borrowed — the DB owns the strings. ok=false when the form is
// not an indexed perk.
perk_of :: proc(db: ^DB, form: Form_ID) -> (Perk, bool) {
	if db == nil {
		return {}, false
	}
	p, ok := db.perks[form]
	return p, ok
}

// perk_tree_of returns a skill's constellation nodes, in record order, with the root first.
// Borrowed. Empty for an actor value that is not a skill.
perk_tree_of :: proc(db: ^DB, avif: Form_ID) -> []Perk_Node {
	if db == nil {
		return {}
	}
	return db.perk_trees[avif]
}

// perk_ranks counts the ranks in a perk chain, starting at `form` and following NNAM. This is the
// count to show, because the authored num_ranks does not survive contact with the data — see
// esm.perk_header. Armsman00 returns 5. A perk outside any chain returns 1, and an unknown form 0.
// The visit cap stops a plugin that links a chain into a cycle.
perk_ranks :: proc(db: ^DB, form: Form_ID) -> int {
	if db == nil {
		return 0
	}
	n := 0
	cur := form
	for n < 64 {
		p, ok := db.perks[cur]
		if !ok {
			break
		}
		n += 1
		if p.next_rank == 0 || p.next_rank == cur {
			break
		}
		cur = p.next_rank
	}
	return n
}
