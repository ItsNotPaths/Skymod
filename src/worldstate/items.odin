package worldstate

// Items (ws.md Workstream J): a holder stores each plain unit as a count of its base; a unit that
// carries data is its own form, a created ref or the record ref it was placed as, and keeps that ID
// in an inventory and in the world. Its placement comes and goes; its data stays here.

// (hole item-units :tags (world save player) :sev gap) items are counts and refs: no unit carries data, carried refs are a side map, and a pickup leaves a disabled ref behind (script.take). Wanted: ws.units the one store of units with data, holder 0 = placed, IDs from create_ref's counter.
// (hole item-tempering :tags (combat player save) :sev gap :needs (item-units item-moves item-placement item-stolen-data item-save)) no unit has a quality, so no weapon or armor gets its smithing bonus and Mod_Tempering_Health (20 SE entries) runs nowhere. The bonus formula is not in the data (only fHealthDataValue1 1.1), and only the smithing screen makes a tempered item.
// Unit is one item that carries data.
Unit :: struct {
	base:   Form_ID,
	holder: Form_ID, // 0 = placed in the world
}

unit_of :: proc(ws: ^World_State, id: Form_ID) -> (Unit, bool) {
	return ws.units[id]
}
