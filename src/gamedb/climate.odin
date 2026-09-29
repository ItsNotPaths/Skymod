package gamedb

// Climates and region weather: which weathers a worldspace's climate and a cell's regions offer.
// Choosing one of them is the weather seam's job (src/weather).

import "../formats/esm"

// Weather_Chance is one weather a climate or region offers, remapped.
Weather_Chance :: struct {
	weather: Form_ID,
	chance:  i32,
	global:  Form_ID, // 0 = none
}

// Region_Weather is a REGN's weather block. An override region hides the lower regions' weathers.
Region_Weather :: struct {
	override: bool,
	priority: u8,
	weathers: []Weather_Chance, // owned
}

// World_Climate is a WRLD's own climate (CNAM) and the parent it may take one from.
World_Climate :: struct {
	climate:        Form_ID,
	parent:         Form_ID,
	parent_climate: bool,
}

@(private)
index_climate :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, had := db.climates[rec.form_id]; had {delete(old, db.allocator)}
	db.climates[rec.form_id] = remap_chances(db, esm.weather_chances(fl, "WLST"), fm)
}

@(private)
index_region :: proc(db: ^DB, rec: esm.Record, fm: ^esm.Form_Map) {
	fl, backing, ok := esm.fields(rec)
	if !ok {return}
	defer delete(fl)
	defer if backing != nil {delete(backing)}
	if old, had := db.region_weathers[rec.form_id]; had {
		delete(old.weathers, db.allocator)
		delete_key(&db.region_weathers, rec.form_id)
	}
	override, priority, has := esm.region_weather(fl)
	if !has {return}
	db.region_weathers[rec.form_id] = {override, priority, remap_chances(db, esm.weather_chances(fl, "RDWT"), fm)}
}

@(private)
index_world_climate :: proc(db: ^DB, form: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	wc: World_Climate
	if c, ok := esm.subrecord_formid(fl, "CNAM"); ok {wc.climate = esm.remap_form(fm, c)}
	parent, parent_climate := esm.world_parent(fl)
	if parent != 0 {wc.parent, wc.parent_climate = esm.remap_form(fm, parent), parent_climate}
	db.world_climates[form] = wc
}

@(private)
index_cell_regions :: proc(db: ^DB, cell: Form_ID, fl: []esm.Field, fm: ^esm.Form_Map) {
	if old, had := db.cell_regions[cell]; had {
		delete(old, db.allocator)
		delete_key(&db.cell_regions, cell)
	}
	if regions := remap_formid_list(db, esm.cell_regions(fl), fm); regions != nil {db.cell_regions[cell] = regions}
}

@(private = "file")
remap_chances :: proc(db: ^DB, raw: []esm.Weather_Chance, fm: ^esm.Form_Map) -> []Weather_Chance {
	if raw == nil {return nil}
	defer delete(raw)
	out := make([]Weather_Chance, len(raw), db.allocator)
	for r, i in raw {
		out[i] = {esm.remap_form(fm, r.weather), r.chance, esm.remap_form(fm, r.global) if r.global != 0 else 0}
	}
	return out
}

// world_climate is the climate a worldspace uses: its own, else its parent's when it takes it.
// 0 = none.
world_climate :: proc(db: ^DB, world: Form_ID) -> Form_ID {
	w := world
	for _ in 0 ..< 8 {
		wc := db.world_climates[w]
		if wc.climate != 0 || !wc.parent_climate {return wc.climate}
		w = wc.parent
	}
	return 0
}

// climate_weathers is a climate's weather list, owned by the DB.
climate_weathers :: proc(db: ^DB, climate: Form_ID) -> []Weather_Chance {
	return db.climates[climate]
}

// region_weather is a region's weather block; ok=false for a region without one.
region_weather :: proc(db: ^DB, region: Form_ID) -> (Region_Weather, bool) {
	r, ok := db.region_weathers[region]
	return r, ok
}

// cell_regions is an exterior cell's regions (XCLR), owned by the DB.
cell_regions :: proc(db: ^DB, cell: Form_ID) -> []Form_ID {
	return db.cell_regions[cell]
}

@(private)
free_climate_indexes :: proc(db: ^DB) {
	for _, c in db.climates {delete(c, db.allocator)}
	delete(db.climates)
	for _, r in db.region_weathers {delete(r.weathers, db.allocator)}
	delete(db.region_weathers)
	delete(db.world_climates)
	for _, r in db.cell_regions {delete(r, db.allocator)}
	delete(db.cell_regions)
}
