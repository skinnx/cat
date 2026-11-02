extends RefCounted
## Hàng Mây city generator (owner: world).
##
## build() deterministically assembles the playable quarter from the asset catalogs
## (assets/models/{city,landmarks,props,vehicles,nature}/catalog.json) plus procedural world
## content (ground, lake, trees, procedural landmark stand-ins, street furniture, markers,
## interactables). post_physics() runs once the tree is inside a SceneTree with physics: it measures
## rooftops by ray casts, adds connectors (crate stairs / planks / walkable cable bundles) so the
## rooftop network is traversable, and bakes the navigation mesh. Re-running the builder picks up new
## or changed catalog entries automatically. Run via scripts/world/tools/build_city.gd.

const L := preload("res://scripts/world/city_layout.gd")
const MU := preload("res://scripts/world/mesh_util.gd")
const WM := preload("res://scripts/world/world_materials.gd")
const CS := preload("res://scripts/world/city_structures.gd")
const TG := preload("res://scripts/world/tree_gen.gd")

const CATALOGS := {
	"city": "res://assets/models/city/catalog.json",
	"landmarks": "res://assets/models/landmarks/catalog.json",
	"props": "res://assets/models/props/catalog.json",
	"vehicles": "res://assets/models/vehicles/catalog.json",
	"nature": "res://assets/models/nature/catalog.json",
}
const WIDTH_STEP := 0.5
const ROAD_Y := L.ROAD_Y

var seed_value := 20260915
var rng := RandomNumberGenerator.new()
var root: Node3D
var catalogs: Dictionary = {}
var placed: Array[Dictionary] = []        # building modules: id, entry, xf, w, d, row, net, node
var report: Dictionary = {"placeholders": [], "warnings": [], "counts": {}}
var _ground_sts: Dictionary = {}          # key -> SurfaceTool
var _ground_nodes: Dictionary = {}
var _groups: Dictionary = {}              # name -> Node3D container
var _scene_cache: Dictionary = {}
var _tree_count := 0
var decks: Dictionary = {}               # module id -> measured roof deck height (module_decks.json)
const DECKS_PATH := "res://scenes/world/module_decks.json"
const MAX_ROW_STEP := 3.6                # deck step between neighbours a crate stair can bridge


# =================================================================================================
# entry points
# =================================================================================================

func build() -> Node3D:
	rng.seed = seed_value
	WM.clear_cache()
	_load_catalogs()
	root = Node3D.new()
	root.name = "City"
	root.set_script(load("res://scripts/world/city.gd"))
	root.set_meta(&"map_bounds", Rect2(-124.0, -98.0, 248.0, 212.0))
	for g in ["Environment", "Ground", "Water", "Buildings", "Landmarks", "Nature", "StreetFurniture",
			"Cables", "Decals", "Lights", "Markers", "Interactables", "Zones", "Probes", "Occluders", "Festival", "Connectors"]:
		var n := Node3D.new()
		n.name = g
		root.add_child(n)
		_groups[g] = n
	_build_environment()
	_build_ground()
	_build_lake()
	_build_buildings()
	_build_landmarks()
	_build_nature()
	_build_street_furniture()
	_build_festival()
	_build_decals()
	_build_markers()
	_build_interactables()
	_build_zones()
	_build_probes_and_occluders()
	_finish_ground()
	return root


func grp(name: String) -> Node3D:
	return _groups[name]


# =================================================================================================
# catalogs
# =================================================================================================

func deck_of(e: Dictionary) -> float:
	var id := str(e.get("id", ""))
	if decks.has(id):
		return float(decks[id])
	# heuristic until measured: lowest high nap spot, else height - 1.3
	var h := float(e.get("height", 10.0))
	var best := INF
	for p: Variant in e.get("nap_spots", []):
		var y := float((p as Array)[1])
		if y >= h * 0.6:
			best = minf(best, y)
	return best if best < INF else h - 1.3


func _load_catalogs() -> void:
	if FileAccess.file_exists(DECKS_PATH):
		var dd: Variant = JSON.parse_string(FileAccess.get_file_as_string(DECKS_PATH))
		if dd is Dictionary:
			decks = dd
	for k: String in CATALOGS:
		var path: String = CATALOGS[k]
		var arr: Array = []
		if FileAccess.file_exists(path):
			var txt := FileAccess.get_file_as_string(path)
			var data: Variant = JSON.parse_string(txt)
			if data is Array:
				arr = data
			elif data is Dictionary:
				for key in ["modules", "items", "props", "entries", "assets"]:
					if (data as Dictionary).has(key) and data[key] is Array:
						arr = data[key]
						break
		# keep only entries whose file exists (other agents may still be writing)
		var ok: Array = []
		for e: Variant in arr:
			if e is Dictionary and ResourceLoader.exists(str(e.get("file", ""))):
				ok.append(e)
		catalogs[k] = ok
		report["counts"]["catalog_" + k] = ok.size()


func cat_find(cat: String, pred: Callable) -> Array:
	var out: Array = []
	for e: Dictionary in catalogs.get(cat, []):
		if pred.call(e):
			out.append(e)
	return out


func cat_by_id(cat: String, id: String) -> Dictionary:
	for e: Dictionary in catalogs.get(cat, []):
		if str(e.get("id", "")) == id:
			return e
	return {}


## First catalog entry (any of the given catalogs) whose id or tags contain any keyword.
func cat_keyword(cats: Array, keywords: Array) -> Dictionary:
	for c: String in cats:
		for e: Dictionary in catalogs.get(c, []):
			var hay := (str(e.get("id", "")) + " " + str(e.get("kind", "")) + " " + " ".join(PackedStringArray(e.get("tags", [])))).to_lower()
			for kw: String in keywords:
				if hay.contains(kw):
					return e
	return {}


func instance(file: String) -> Node3D:
	if not _scene_cache.has(file):
		_scene_cache[file] = load(file)
	var ps: PackedScene = _scene_cache[file]
	if ps == null:
		return null
	return ps.instantiate() as Node3D


func placeholder(what: String, why: String) -> void:
	(report["placeholders"] as Array).append("%s — %s" % [what, why])


# =================================================================================================
# environment: WorldEnvironment, Sun, Moon, WeatherSystem, NightLights
# =================================================================================================

func _build_environment() -> void:
	var g := grp("Environment")
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://shaders/sky_hangmay.gdshader")
	sm.set_shader_parameter(&"noise_tex", load("res://assets/textures/ground/noise_rgba.png"))
	sky.sky_material = sm
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_REALTIME
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.0
	env.ssr_enabled = true
	env.ssr_max_steps = 64
	env.ssr_fade_in = 0.15
	env.ssr_fade_out = 2.0
	env.ssr_depth_tolerance = 0.3
	env.ssao_enabled = true
	env.ssao_radius = 1.2
	env.ssao_intensity = 2.2
	env.ssao_power = 1.6
	env.ssao_detail = 0.6
	env.ssil_enabled = false
	env.sdfgi_enabled = true
	env.sdfgi_use_occlusion = true
	env.sdfgi_cascades = 5
	env.sdfgi_min_cell_size = 0.2
	env.sdfgi_y_scale = Environment.SDFGI_Y_SCALE_75_PERCENT
	env.sdfgi_energy = 1.0
	env.sdfgi_bounce_feedback = 0.5
	env.glow_enabled = true
	env.glow_intensity = 0.4
	env.glow_strength = 0.9
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.2
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.0015
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.25
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.0045
	env.volumetric_fog_length = 96.0
	env.volumetric_fog_anisotropy = 0.55
	env.volumetric_fog_detail_spread = 2.0
	env.volumetric_fog_sky_affect = 0.15
	env.volumetric_fog_gi_inject = 0.6
	env.volumetric_fog_temporal_reprojection_enabled = true
	env.adjustment_enabled = true
	env.adjustment_contrast = 1.04
	env.adjustment_saturation = 1.03
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	var ca := CameraAttributesPractical.new()
	ca.dof_blur_far_enabled = false
	we.camera_attributes = ca
	we.set_script(load("res://scripts/world/world_environment.gd"))
	root.add_child(we)
	# Sun first (LIGHT0 in the sky shader), Moon second (LIGHT1)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.light_angular_distance = 0.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 140.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.18
	sun.directional_shadow_split_3 = 0.45
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.2
	sun.light_volumetric_fog_energy = 1.4
	sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_AND_SKY
	root.add_child(sun)
	var moon := DirectionalLight3D.new()
	moon.name = "Moon"
	moon.shadow_enabled = false
	moon.light_energy = 0.0
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.directional_shadow_max_distance = 80.0
	moon.light_volumetric_fog_energy = 2.0
	root.add_child(moon)
	root.move_child(we, 0)
	root.move_child(sun, 1)
	root.move_child(moon, 2)
	var ws := Node3D.new()
	ws.name = "WeatherSystem"
	ws.set_script(load("res://scripts/world/weather_system.gd"))
	root.add_child(ws)
	var nl := Node.new()
	nl.name = "NightLights"
	nl.set_script(load("res://scripts/world/night_lights.gd"))
	root.add_child(nl)


# =================================================================================================
# ground
# =================================================================================================

func gst(key: StringName) -> SurfaceTool:
	if not _ground_sts.has(key):
		_ground_sts[key] = MU.new_st()
	return _ground_sts[key]


func grect(key: StringName, x0: float, z0: float, x1: float, z1: float, y: float) -> void:
	if x1 - x0 < 0.01 or z1 - z0 < 0.01:
		return
	MU.rect_xz(gst(key), x0, z0, x1, z1, y, WM.tile_of(key))


func gbox(key: StringName, center: Vector3, size: Vector3, yaw: float = 0.0, skip: PackedStringArray = PackedStringArray()) -> void:
	MU.box(gst(key), Transform3D(Basis(Vector3.UP, yaw), center), size, WM.tile_of(key), skip)


## Rect minus square holes (tree pits): splits along the long axis.
func grect_holes(key: StringName, x0: float, z0: float, x1: float, z1: float, y: float, holes: Array) -> void:
	var along_x := (x1 - x0) >= (z1 - z0)
	var cuts: Array = []
	for h: Rect2 in holes:
		if h.position.x >= x1 or h.end.x <= x0 or h.position.y >= z1 or h.end.y <= z0:
			continue
		cuts.append(h)
	cuts.sort_custom(func(a: Rect2, b: Rect2) -> bool: return (a.position.x < b.position.x) if along_x else (a.position.y < b.position.y))
	var cur := x0 if along_x else z0
	for h: Rect2 in cuts:
		if along_x:
			grect(key, cur, z0, h.position.x, z1, y)
			grect(key, h.position.x, z0, h.end.x, h.position.y, y)
			grect(key, h.position.x, h.end.y, h.end.x, z1, y)
			cur = h.end.x
		else:
			grect(key, x0, cur, x1, h.position.y, y)
			grect(key, x0, h.position.y, h.position.x, h.end.y, y)
			grect(key, h.end.x, h.position.y, x1, h.end.y, y)
			cur = h.end.y
	if along_x:
		grect(key, cur, z0, x1, z1, y)
	else:
		grect(key, x0, cur, x1, z1, y)


var tree_pits: Array = []        # Vector3 positions of street-tree pits


func _build_ground() -> void:
	# --- streets: asphalt, gutters, curbs, sidewalks with tree pits ---
	for s: Array in L.STREETS:
		var axis: String = s[1]
		var c: float = s[2]
		var a0: float = s[3]
		var a1: float = s[4]
		var rw: float = s[5]
		var sw: float = s[6]
		var hw := rw * 0.5
		if axis == "x":
			grect(&"asphalt", a0, c - hw, a1, c + hw, ROAD_Y)
		else:
			grect(&"asphalt", c - hw, a0, c + hw, a1, ROAD_Y)
		_street_edges(s)
	# intersections: fill the crossing squares are part of the N-S asphalt (z range overlaps)
	# --- block fills (alleys/courtyards at sidewalk level) ---
	grect(&"concrete", -121.0, -63.0, -61.0, 55.0, 0.0)          # west maze (alleys + light wells)
	grect(&"concrete", 56.0, -63.0, 122.0, 55.0, 0.0)            # market quarter
	grect(&"concrete", -122.0, -100.0, 122.0, -77.0, 0.0)        # behind the north row
	grect(&"concrete", -122.0, 69.0, -34.0, 112.0, 0.0)          # behind temple-street south rows
	grect(&"concrete", 34.0, 69.0, 122.0, 112.0, 0.0)
	grect(&"brick", -34.0, 69.0, 34.0, 112.0, 0.0)               # temple garden (the kit has its own courtyard)
	# market plaza: terrazzo-ish concrete under the hall is the same concrete; stall lanes get brick
	grect(&"brick", 56.0, 3.5, 118.0, 12.5, 0.005)               # fish lane paving
	# lake park lawn handled in _build_lake (needs the ellipse hole)


func _street_edges(s: Array) -> void:
	var id: String = s[0]
	var axis: String = s[1]
	var c: float = s[2]
	var a0: float = s[3]
	var a1: float = s[4]
	var hw: float = float(s[5]) * 0.5
	var sw: float = s[6]
	# sidewalk spans exclude crossings with perpendicular roads
	var crossings: Array = []
	for o: Array in L.STREETS:
		if o[1] != axis:
			var oc: float = o[2]
			var ohw: float = float(o[5]) * 0.5
			crossings.append([oc - ohw, oc + ohw, float(o[3]), float(o[4])])
	for side: float in [-1, 1]:
		var curb_line := c + side * hw
		var outer := c + side * (hw + sw)
		var spans: Array = [[a0, a1]]
		for cr: Array in crossings:
			# the perpendicular road crosses this sidewalk only if it reaches it
			var reach_lo: float = cr[2]
			var reach_hi: float = cr[3]
			var sw_lo := minf(curb_line, outer)
			var sw_hi := maxf(curb_line, outer)
			if reach_hi < sw_lo - 0.01 or reach_lo > sw_hi + 0.01:
				continue
			var new_spans: Array = []
			for sp: Array in spans:
				if cr[1] <= sp[0] or cr[0] >= sp[1]:
					new_spans.append(sp)
				else:
					if cr[0] > sp[0]:
						new_spans.append([sp[0], cr[0]])
					if cr[1] < sp[1]:
						new_spans.append([cr[1], sp[1]])
			spans = new_spans
		# N-S street sidewalks stop at the E-W sidewalks
		if axis == "z":
			spans = [[a0 + 3.0, a1 - 3.0]]
		for sp: Array in spans:
			var s0: float = sp[0]
			var s1: float = sp[1]
			if s1 - s0 < 0.5:
				continue
			var curb_in := curb_line + side * 0.2
			# street trees: pits every ~11 m on wide sidewalks (not in front of the lake block's park side)
			var holes: Array = []
			var t := s0 + 6.0
			while t < s1 - 3.0:
				var pit_c := curb_line + side * (0.2 + 0.8)
				var hole: Rect2
				if axis == "x":
					hole = Rect2(t - 0.6, pit_c - 0.6, 1.2, 1.2)
				else:
					hole = Rect2(pit_c - 0.6, t - 0.6, 1.2, 1.2)
				if rng.randf() < 0.8 and _tree_pit_allowed(id, side, t):
					holes.append(hole)
					tree_pits.append(Vector3(hole.get_center().x, 0.0, hole.get_center().y))
				t += rng.randf_range(10.0, 13.0)
			if axis == "x":
				grect_holes(&"pavers", s0, minf(curb_in, outer), s1, maxf(curb_in, outer), 0.0, holes)
				# curb (granite) between road and sidewalk
				var cz := curb_line + side * 0.1
				gbox(&"granite", Vector3((s0 + s1) * 0.5, ROAD_Y * 0.5 - 0.05, cz), Vector3(s1 - s0, -ROAD_Y + 0.1, 0.2), 0.0, PackedStringArray(["bottom"]))
				grect(&"gutter", s0, minf(curb_line, curb_line - side * 0.4), s1, maxf(curb_line, curb_line - side * 0.4), ROAD_Y + 0.004)
			else:
				var hs: Array = []
				for h: Rect2 in holes:
					hs.append(h)
				grect_holes(&"pavers", minf(curb_in, outer), s0, maxf(curb_in, outer), s1, 0.0, hs)
				var cx := curb_line + side * 0.1
				gbox(&"granite", Vector3(cx, ROAD_Y * 0.5 - 0.05, (s0 + s1) * 0.5), Vector3(0.2, -ROAD_Y + 0.1, s1 - s0), 0.0, PackedStringArray(["bottom"]))
				grect(&"gutter", minf(curb_line, curb_line - side * 0.4), s0, maxf(curb_line, curb_line - side * 0.4), s1, ROAD_Y + 0.004)
	# tree pits: soil + granite frame
	for p: Vector3 in tree_pits:
		grect(&"lakebed", p.x - 0.6, p.z - 0.6, p.x + 0.6, p.z + 0.6, -0.04)


func _tree_pit_allowed(_street: String, _side: int, _t: float) -> bool:
	return true


func _finish_ground() -> void:
	var g := grp("Ground")
	var surfaces := {&"asphalt": &"asphalt", &"pavers": &"tile", &"granite": &"concrete", &"concrete": &"concrete",
		&"gutter": &"concrete", &"brick": &"tile", &"grass": &"grass", &"embankment": &"concrete", &"wood": &"wood", &"lakebed": &"dirt"}
	for key: StringName in _ground_sts:
		var st: SurfaceTool = _ground_sts[key]
		st.generate_tangents()
		var mesh := st.commit()
		mesh.surface_set_material(0, WM.ground(key))
		var mi := MeshInstance3D.new()
		mi.name = "Ground_" + String(key)
		mi.mesh = mesh
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if key in [&"asphalt", &"pavers", &"gutter", &"concrete", &"brick", &"grass", &"lakebed"] else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		g.add_child(mi)
		if key == &"lakebed":
			continue          # tree pit soil & lake bed: lake bed collision is added separately
		var body := StaticBody3D.new()
		body.name = "GroundBody_" + String(key)
		body.collision_layer = 1
		body.collision_mask = 0
		body.set_meta(&"surface", surfaces.get(key, &"concrete"))
		body.add_to_group(&"nav_source")
		var cs := CollisionShape3D.new()
		cs.shape = mesh.create_trimesh_shape()
		body.add_child(cs)
		g.add_child(body)
	# safety floor far below (anything that falls through the world lands somewhere)
	var floor_body := StaticBody3D.new()
	floor_body.name = "SafetyFloor"
	floor_body.collision_layer = 1
	floor_body.set_meta(&"surface", &"dirt")
	var fcs := CollisionShape3D.new()
	var fbs := BoxShape3D.new()
	fbs.size = Vector3(300, 1, 260)
	fcs.shape = fbs
	fcs.position = Vector3(0, -6.0, 0)
	floor_body.add_child(fcs)
	g.add_child(floor_body)
	# map boundary (invisible walls at the street ends)
	var bound := StaticBody3D.new()
	bound.name = "MapBounds"
	bound.collision_layer = 1 | (1 << 8)
	for b: Array in [[Vector3(-126, 10, -70), Vector3(1, 30, 30)], [Vector3(126, 10, -70), Vector3(1, 30, 30)],
			[Vector3(-126, 10, 62), Vector3(1, 30, 30)], [Vector3(126, 10, 62), Vector3(1, 30, 30)]]:
		var c := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = b[1]
		c.shape = bs
		c.position = b[0]
		bound.add_child(c)
	g.add_child(bound)


# =================================================================================================
# lake: lawn with ellipse hole, promenade ring, embankment, water, bed, islet, bridge
# =================================================================================================

func _ell(t: float, scale: float = 1.0, center: Vector2 = L.LAKE_CENTER, radii: Vector2 = L.LAKE_RADII) -> Vector2:
	return center + Vector2(cos(t) * radii.x * scale, sin(t) * radii.y * scale)


func _in_ellipse(p: Vector2, center: Vector2, radii: Vector2, grow: float = 0.0) -> bool:
	var q := (p - center) / (radii + Vector2(grow, grow))
	return q.length_squared() < 1.0


func _build_lake() -> void:
	var cen: Vector2 = L.LAKE_CENTER
	var rad: Vector2 = L.LAKE_RADII
	var wy: float = L.LAKE_WATER_Y
	var segs := 96
	# lawn: 1 m cells over the park, skipping cells inside promenade outer ellipse
	var pw: float = L.PROMENADE_W
	var park := Rect2(-49.0, -49.0, 93.0, 104.0)
	var step := 1.0
	var x := park.position.x
	while x < park.end.x - 0.001:
		var z := park.position.y
		var run_start := NAN
		while z < park.end.y - 0.001:
			var inside := _in_ellipse(Vector2(x + step * 0.5, z + step * 0.5), cen, rad, pw - 0.6)
			if inside:
				if not is_nan(run_start):
					grect(&"grass", x, run_start, x + step, z, 0.0)
					run_start = NAN
			elif is_nan(run_start):
				run_start = z
			z += step
		if not is_nan(run_start):
			grect(&"grass", x, run_start, x + step, park.end.y, 0.0)
		x += step
	# promenade ring (brick) from the water edge outward, just under the kit paving (which covers 3 m)
	var st := gst(&"brick")
	for i in segs:
		var t0 := TAU * i / segs
		var t1 := TAU * (i + 1) / segs
		var a0 := _ell(t0, 1.0)
		var a1 := _ell(t1, 1.0)
		var b0 := cen + (a0 - cen).normalized() * ((a0 - cen).length() + pw)
		var b1 := cen + (a1 - cen).normalized() * ((a1 - cen).length() + pw)
		var A := Vector3(a0.x, -0.005, a0.y)
		var B := Vector3(a1.x, -0.005, a1.y)
		var C := Vector3(b1.x, -0.005, b1.y)
		var D := Vector3(b0.x, -0.005, b0.y)
		var tile := WM.tile_of(&"brick")
		var uvs: Array[Vector2] = [Vector2(A.x, A.z) / tile, Vector2(D.x, D.z) / tile, Vector2(C.x, C.z) / tile, Vector2(B.x, B.z) / tile]
		MU.quad(st, A, D, C, B, Vector3.UP, uvs)
	if cat_by_id("landmarks", "ho_embank_straight_4m").is_empty():
		placeholder("Lake embankment (procedural, city_builder._procedural_embankment)", "no ho_embank_* in the landmarks catalog")
		_procedural_embankment(segs)
	else:
		_kit_embankment()
	# lake bed (bowl)
	var bst := MU.new_st()
	var rings := 10
	for r in rings:
		for i in segs:
			var t0 := TAU * i / segs
			var t1 := TAU * (i + 1) / segs
			var s0 := float(r) / rings
			var s1 := float(r + 1) / rings
			var pts: Array[Vector3] = []
			for c: Array in [[t0, s1], [t1, s1], [t1, s0], [t0, s0]]:
				var q := _ell(float(c[0]), maxf(float(c[1]), 0.001) * 1.0 + 0.0)
				var dd: float = float(c[1])
				var y: float = L.LAKE_BED_EDGE_Y - L.LAKE_DEPTH * (1.0 - dd * dd)
				pts.append(Vector3(q.x, y, q.y))
			MU.quad(bst, pts[0], pts[1], pts[2], pts[3], Vector3.UP, [Vector2(pts[0].x, pts[0].z) / 4.0, Vector2(pts[1].x, pts[1].z) / 4.0, Vector2(pts[2].x, pts[2].z) / 4.0, Vector2(pts[3].x, pts[3].z) / 4.0])
	bst.generate_normals()
	bst.generate_tangents()
	var bed_mesh := bst.commit()
	bed_mesh.surface_set_material(0, WM.ground(&"lakebed"))
	var bed := MeshInstance3D.new()
	bed.name = "LakeBed"
	bed.mesh = bed_mesh
	bed.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	grp("Water").add_child(bed)
	var bed_body := StaticBody3D.new()
	bed_body.name = "LakeBedBody"
	bed_body.collision_layer = 1
	bed_body.set_meta(&"surface", &"dirt")
	var bcs := CollisionShape3D.new()
	bcs.shape = bed_mesh.create_trimesh_shape()
	bed_body.add_child(bcs)
	grp("Water").add_child(bed_body)
	# water surface: fan of triangles slightly larger than the wall
	var wst := MU.new_st()
	for i in segs:
		var t0 := TAU * i / segs
		var t1 := TAU * (i + 1) / segs
		for r in 6:
			var s0 := float(r) / 6.0
			var s1 := float(r + 1) / 6.0
			var q00 := _ell(t0, s0 * 1.01)
			var q10 := _ell(t1, s0 * 1.01)
			var q11 := _ell(t1, s1 * 1.01)
			var q01 := _ell(t0, s1 * 1.01)
			var A := Vector3(q01.x, wy, q01.y)
			var B := Vector3(q11.x, wy, q11.y)
			var C := Vector3(q10.x, wy, q10.y)
			var D := Vector3(q00.x, wy, q00.y)
			MU.quad(wst, D, C, B, A, Vector3.UP, [Vector2(D.x, D.z), Vector2(C.x, C.z), Vector2(B.x, B.z), Vector2(A.x, A.z)])
	wst.generate_tangents()
	var wmesh := wst.commit()
	var wmat := WM.water()
	wmat.set_shader_parameter(&"lake_center", cen)
	wmat.set_shader_parameter(&"lake_radii", rad)
	wmat.set_shader_parameter(&"max_depth", L.LAKE_DEPTH)
	var water := MeshInstance3D.new()
	water.name = "LakeWater"
	water.mesh = wmesh
	water.material_override = wmat
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	water.add_to_group(&"lake_water")
	grp("Water").add_child(water)
	# water volume (layer 7) — top face = water surface, meta water_level
	var area := Area3D.new()
	area.name = "LakeVolume"
	area.collision_layer = 1 << 6
	area.collision_mask = 0
	area.monitorable = true
	area.monitoring = false
	area.set_meta(&"water_level", wy)
	area.set_meta(&"surface", &"water")
	area.add_to_group(&"water")
	var acs := CollisionShape3D.new()
	var abs := BoxShape3D.new()
	abs.size = Vector3(rad.x * 2.0, 3.0, rad.y * 2.0)
	acs.shape = abs
	acs.position = Vector3(cen.x, wy - 1.5, cen.y)
	area.add_child(acs)
	grp("Water").add_child(area)
	# lotus & water hyacinth patches (nature kit; origin = water surface)
	var lotus_e := cat_by_id("nature", "lotus_cluster")
	var hyac_e := cat_by_id("nature", "water_hyacinth")
	for lp: Array in [[Vector2(-24, -8), 7.0, 140], [Vector2(-10, 24), 5.0, 80], [Vector2(6, -18), 4.0, 50], [Vector2(-28, 16), 3.5, 40]]:
		var c2: Vector2 = lp[0]
		if lotus_e.is_empty():
			var lotus := TG.make_lotus_patch(lp[1], lp[2], int(c2.x * 13 + c2.y))
			lotus.position = Vector3(c2.x, wy, c2.y)
			grp("Water").add_child(lotus)
			continue
		var r: float = lp[1]
		var count := int(r * r * 0.55)
		for k in count:
			var ang := rng.randf() * TAU
			var rr := sqrt(rng.randf()) * r
			var q := c2 + Vector2(cos(ang), sin(ang)) * Vector2(rr, rr * 0.7)
			if not _in_ellipse(q, cen, rad, -1.2) or _in_ellipse(q, L.ISLET_CENTER, L.ISLET_RADII, 1.0):
				continue
			var use_h := not hyac_e.is_empty() and k % 4 == 3
			var n := instance(str((hyac_e if use_h else lotus_e)["file"]))
			n.position = Vector3(q.x, wy, q.y)
			n.rotation.y = rng.randf() * TAU
			var sc := rng.randf_range(0.75, 1.25)
			n.scale = Vector3(sc, sc, sc)
			grp("Water").add_child(n)
	_place_islet_and_bridge()


## Islet + red bridge to the east shore. Kit: bridge midpoint at walkway level spanning local Z ±8.8,
## islet centre 11.6 m from the bridge midpoint along the bridge axis (islet landing = its +Z side).
func _place_islet_and_bridge() -> void:
	var ic: Vector2 = L.ISLET_CENTER
	var mid := Vector3(ic.x + 11.6, 0.0, ic.y)
	islet = lm("ho_islet_shrine", Vector3(ic.x, 0.0, ic.y), PI * 0.5, "IsletShrine")
	if islet == null:
		_build_islet()
		islet = _landmark(["mieu"], func() -> Node3D: return CS.make_shrine(), Vector3(ic.x + 1.0, 0.25, ic.y + 1.0), -PI * 0.5, "IsletShrine")
	bridge = lm("ho_bridge", mid, PI * 0.5, "Bridge")
	if bridge == null:
		var x0 := ic.x + L.ISLET_RADII.x - 0.6
		var x1 := mid.x + 8.0
		var blen := x1 - x0
		bridge = _landmark(["cau_bridge"], func() -> Node3D: return CS.make_bridge(blen, 2.4, 1.1), Vector3((x0 + x1) * 0.5, 0, ic.y), 0.0, "Bridge")
	report["counts"]["bridge_length"] = 17.6


## Hồ Gương embankment from the city-landmarks kit: ~52 straight 4 m chords around the ellipse
## (water side = local +Z toward the lake), water steps at L.LAKE_STEPS_T, railings on the coping
## except at steps and the bridge landing, promenade lamps & benches behind the coping.
func _kit_embankment() -> void:
	var cen: Vector2 = L.LAKE_CENTER
	# arc-length parametrisation of the ellipse
	var fine := 2048
	var cum: Array[float] = [0.0]
	var prev := _ell(0.0)
	for i in range(1, fine + 1):
		var q := _ell(TAU * i / fine)
		cum.append(cum[i - 1] + prev.distance_to(q))
		prev = q
	var total: float = cum[fine]
	var n := int(round(total / 4.0))
	var ts: Array[float] = []
	var j := 0
	for k in n:
		var target := total * k / n
		while j < fine and cum[j + 1] < target:
			j += 1
		var f := (target - cum[j]) / maxf(cum[j + 1] - cum[j], 0.0001)
		ts.append(TAU * (j + f) / fine)
	# chords whose middle is closest to each requested step param
	var step_chords: Dictionary = {}
	for st_t: float in L.LAKE_STEPS_T:
		var best := -1
		var bd := INF
		for k in n:
			var tm := ts[k] + (TAU / n) * 0.5
			var d := absf(wrapf(tm - fposmod(st_t, TAU), -PI, PI))
			if d < bd:
				bd = d
				best = k
		step_chords[best] = true
	var bridge_pt := Vector2(L.ISLET_CENTER.x + 11.6 + 7.4, L.ISLET_CENTER.y)
	var lamp_i := 0
	for k in n:
		var p0 := _ell(ts[k])
		var p1 := _ell(ts[(k + 1) % n])
		var mid := (p0 + p1) * 0.5
		var along := (p1 - p0).normalized()
		var inward := Vector2(-along.y, along.x)
		if inward.dot(cen - mid) < 0.0:
			inward = -inward
		var yaw := atan2(inward.x, inward.y)
		var pos := Vector3(mid.x, 0.0, mid.y)
		var is_steps := step_chords.has(k)
		var piece := lm("ho_embank_steps_4m" if is_steps else "ho_embank_straight_4m", pos, yaw, "Embank_%02d" % k, grp("Water"))
		if is_steps and piece != null:
			lake_steps.append(piece)
			continue
		# distance of the bridge axis point to this chord
		var near_bridge := Geometry2D.get_closest_point_to_segment(bridge_pt, p0, p1).distance_to(bridge_pt) < 2.6
		if near_bridge:
			continue
		lm("ho_railing_4m", pos, yaw, "Railing_%02d" % k, grp("Water"))
		var basis := Basis(Vector3.UP, yaw)
		if k % 5 == 2:
			lm("ho_lamp_post", pos - basis.z * 2.55 + basis.x * 1.0, yaw, "PromenadeLamp_%02d" % lamp_i, grp("Water"))
			lamp_i += 1
		elif k % 5 == 4 or k % 5 == 0:
			var bpos := pos - basis.z * 2.25 + basis.x * (0.6 if k % 2 == 0 else -0.6)
			if lm("ho_bench", bpos, yaw, "PromenadeBench_%02d" % k, grp("StreetFurniture")) == null:
				var bn := CS.make_bench(1.8)
				bn.position = bpos
				bn.rotation.y = yaw
				grp("StreetFurniture").add_child(bn)
	report["counts"]["embankment_pieces"] = n


func _procedural_embankment(segs: int) -> void:
	var cen: Vector2 = L.LAKE_CENTER
	var wall_top := 0.0
	var bed_edge: float = L.LAKE_BED_EDGE_Y + 0.25
	var est := gst(&"embankment")
	var cst := gst(&"granite")
	var ebody := StaticBody3D.new()
	ebody.name = "Embankment"
	ebody.collision_layer = 1
	ebody.set_meta(&"surface", &"concrete")
	grp("Water").add_child(ebody)
	for i in segs:
		var t0 := TAU * i / segs
		var t1 := TAU * (i + 1) / segs
		var p0 := _ell(t0)
		var p1 := _ell(t1)
		var top0 := Vector3(p0.x, wall_top, p0.y)
		var top1 := Vector3(p1.x, wall_top, p1.y)
		var bot0 := Vector3(p0.x, bed_edge - 0.3, p0.y)
		var bot1 := Vector3(p1.x, bed_edge - 0.3, p1.y)
		var inward := Vector3(cen.x - (p0.x + p1.x) * 0.5, 0, cen.y - (p0.y + p1.y) * 0.5).normalized()
		var seg_len := p0.distance_to(p1)
		var uvs: Array[Vector2] = [Vector2(i * seg_len / 2.0, 0), Vector2((i + 1) * seg_len / 2.0, 0), Vector2((i + 1) * seg_len / 2.0, 0.9), Vector2(i * seg_len / 2.0, 0.9)]
		MU.quad(est, top1, top0, bot0, bot1, inward, uvs)
		var out0 := top0 - inward * 0.45
		var out1 := top1 - inward * 0.45
		MU.quad(cst, top0 + Vector3.UP * 0.12, top1 + Vector3.UP * 0.12, out1 + Vector3.UP * 0.12, out0 + Vector3.UP * 0.12, Vector3.UP, [Vector2(i * seg_len, 0), Vector2((i + 1) * seg_len, 0), Vector2((i + 1) * seg_len, 0.45), Vector2(i * seg_len, 0.45)])
		var mid := (top0 + top1) * 0.5 - inward * 0.2
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(seg_len + 0.06, wall_top - bed_edge + 0.62, 0.45)
		cs.shape = bs
		cs.transform = Transform3D(Basis.looking_at(inward, Vector3.UP), Vector3(mid.x, (wall_top + 0.12 + bed_edge - 0.5) * 0.5, mid.z))
		ebody.add_child(cs)
	for t: float in L.LAKE_STEPS_T:
		_lake_steps(t)


func _lake_steps(t: float) -> void:
	var p := _ell(t)
	var inward := (L.LAKE_CENTER - p).normalized()
	var yaw := atan2(inward.x, inward.y)
	var n := Node3D.new()
	n.name = "LakeSteps"
	n.position = Vector3(p.x, 0, p.y)
	n.rotation.y = yaw
	grp("Water").add_child(n)
	var k := CS.Kit.new(n)
	var stone := WM.ground_std(&"granite")
	for i in 4:
		var y := 0.12 - (i + 1) * 0.16
		k.box(stone, Transform3D(Basis(), Vector3(0, y - 0.1 + 0.08, 0.2 + i * 0.35)), Vector3(2.4, 0.2, 0.36), 1.0, &"concrete")
	k.finish("Steps")


func _build_islet() -> void:
	var c: Vector2 = L.ISLET_CENTER
	var r: Vector2 = L.ISLET_RADII
	var segs := 40
	var top := 0.25
	var gst_grass := gst(&"grass")
	var est := gst(&"embankment")
	var body := StaticBody3D.new()
	body.name = "Islet"
	body.collision_layer = 1
	body.set_meta(&"surface", &"grass")
	grp("Water").add_child(body)
	for i in segs:
		var t0 := TAU * i / segs
		var t1 := TAU * (i + 1) / segs
		var p0 := _ell(t0, 1.0, c, r)
		var p1 := _ell(t1, 1.0, c, r)
		var A := Vector3(c.x, top, c.y)
		var B := Vector3(p0.x, top, p0.y)
		var C := Vector3(p1.x, top, p1.y)
		# fan (clockwise from above) — top
		for v: Vector3 in [A, C, B]:
			gst_grass.set_normal(Vector3.UP)
			gst_grass.set_uv(Vector2(v.x, v.z) / 2.0)
			gst_grass.add_vertex(v)
		var outward := Vector3((p0.x + p1.x) * 0.5 - c.x, 0, (p0.y + p1.y) * 0.5 - c.y).normalized()
		var seg_len := p0.distance_to(p1)
		MU.quad(est, Vector3(p0.x, top, p0.y), Vector3(p1.x, top, p1.y), Vector3(p1.x, L.LAKE_WATER_Y - 1.0, p1.y), Vector3(p0.x, L.LAKE_WATER_Y - 1.0, p0.y), outward,
			[Vector2(i * seg_len / 2.0, 0), Vector2((i + 1) * seg_len / 2.0, 0), Vector2((i + 1) * seg_len / 2.0, 0.8), Vector2(i * seg_len / 2.0, 0.8)])
	var cs := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = minf(r.x, r.y)
	cyl.height = 2.0
	cs.shape = cyl
	cs.position = Vector3(c.x, top - 1.0, c.y)
	cs.scale = Vector3.ONE
	body.add_child(cs)
	# fill the ellipse ends with boxes
	for sx: float in [-1, 1]:
		var bcs := CollisionShape3D.new()
		var bb := BoxShape3D.new()
		bb.size = Vector3(r.x - r.y + 0.6, 2.0, r.y * 1.2)
		bcs.shape = bb
		bcs.position = Vector3(c.x + sx * (r.y + (r.x - r.y) * 0.5 - 0.6), top - 1.0, c.y)
		body.add_child(bcs)


# =================================================================================================
# buildings
# =================================================================================================

func _module_pool(max_depth: float, styles: Dictionary) -> Array:
	return cat_find("city", func(e: Dictionary) -> bool:
		return str(e.get("kind", "")) in ["house", "shop"] and float(e.get("depth", 99)) <= max_depth + 0.01 \
			and styles.has(str(e.get("style", ""))))


func _reachable_lengths(widths: Array, max_len: float) -> Dictionary:
	var n := int(round(max_len / WIDTH_STEP))
	var reach := {0: true}
	for i in range(1, n + 1):
		for w: float in widths:
			var j := i - int(round(w / WIDTH_STEP))
			if j >= 0 and reach.has(j):
				reach[i] = true
				break
	return reach


func _build_buildings() -> void:
	for row: Array in L.ROWS:
		_fill_row(row)
	for wr: Array in L.WALL_RUNS:
		_wall_run(wr)
	report["counts"]["building_modules"] = placed.size()


func _row_basis(facing: Vector2) -> Basis:
	return Basis(Vector3.UP, atan2(facing.x, facing.y))


func _fill_row(row: Array) -> void:
	var name: String = row[0]
	var start: Vector2 = row[1]
	var facing: Vector2 = row[2]
	var length: float = row[3]
	var max_depth: float = row[4]
	var styles: Dictionary = row[5]
	var gaps: Array = row[6]
	var corner_end: bool = row[7]
	var net: bool = row[8]
	var basis := _row_basis(facing)
	var along := basis.x
	var origin := Vector3(start.x, 0.0, start.y)
	# landmark modules forced into this row (e.g. Bông's café) become gaps the filler skips
	gaps = gaps.duplicate()
	for rv: Array in L.ROW_RESERVED.get(name, []):
		var re := cat_by_id("landmarks", str(rv[0]))
		if re.is_empty():
			continue
		var a0 := float(rv[1])
		var rw := float(re["width"])
		var node := lm(str(rv[0]), origin + along * (a0 + rw * 0.5), atan2(facing.x, facing.y), str(rv[0]).to_pascal_case(), grp("Buildings"))
		if str(rv[0]) == "cafe_bong":
			cafe = node
		gaps.append([a0, a0 + rw])
		if a0 + rw >= length - 0.01:
			corner_end = false
	var pool := _module_pool(max_depth, styles)
	if pool.is_empty():
		report["warnings"].append("row %s: no modules for styles %s" % [name, styles.keys()])
		return
	var widths: Array = []
	for e: Dictionary in pool:
		var w := float(e["width"])
		if not w in widths:
			widths.append(w)
	# spans between gaps
	var spans: Array = []
	var cur := 0.0
	var sorted_gaps := gaps.duplicate()
	sorted_gaps.sort_custom(func(a: Array, b: Array) -> bool: return float(a[0]) < float(b[0]))
	for g: Array in sorted_gaps:
		spans.append([cur, float(g[0])])
		cur = float(g[1])
	spans.append([cur, length])
	var corner_entry := {}
	if corner_end:
		var corners := cat_find("city", func(e: Dictionary) -> bool: return str(e.get("kind", "")) == "corner" and float(e.get("depth", 99)) <= max_depth + 0.01)
		if not corners.is_empty():
			corner_entry = corners[rng.randi_range(0, corners.size() - 1)]
	var prev_variant := ""
	var prev_h := -1.0
	for si in spans.size():
		var s0: float = spans[si][0]
		var s1: float = spans[si][1]
		if si == spans.size() - 1 and not corner_entry.is_empty():
			var cw := float(corner_entry["width"])
			_place_module(corner_entry, origin + along * (s1 - cw * 0.5), basis, name, net)
			s1 -= cw
		var span := s1 - s0
		var usable := floorf(span / WIDTH_STEP) * WIDTH_STEP
		var reach := _reachable_lengths(widths, usable)
		# fall back to the largest reachable length ≤ usable
		var target_steps := int(round(usable / WIDTH_STEP))
		while target_steps > 0 and not reach.has(target_steps):
			target_steps -= 1
		var filled := float(target_steps) * WIDTH_STEP
		var slack := span - filled
		var pos := s0 + slack * 0.5
		if slack > 0.05:
			_filler_pier(origin + along * (s0 + slack * 0.25), basis, slack * 0.5, name)
			_filler_pier(origin + along * (s1 - slack * 0.25), basis, slack * 0.5, name)
		var remaining_steps := target_steps
		while remaining_steps > 0:
			var cands: Array = []
			for e: Dictionary in pool:
				var ws := int(round(float(e["width"]) / WIDTH_STEP))
				if ws > remaining_steps or not reach.has(remaining_steps - ws):
					continue
				if str(e.get("variant_of", e["id"])) == prev_variant:
					continue
				cands.append(e)
			if cands.is_empty():
				for e: Dictionary in pool:
					var ws := int(round(float(e["width"]) / WIDTH_STEP))
					if ws <= remaining_steps and reach.has(remaining_steps - ws):
						cands.append(e)
			if cands.is_empty():
				break
			if net and prev_h > 0.0:
				var near: Array = cands.filter(func(e: Dictionary) -> bool: return absf(deck_of(e) - prev_h) <= MAX_ROW_STEP)
				if not near.is_empty():
					cands = near
				else:
					var ph := prev_h
					cands.sort_custom(func(a: Dictionary, c: Dictionary) -> bool: return absf(deck_of(a) - ph) < absf(deck_of(c) - ph))
					cands = cands.slice(0, 1)
			var pick := _weighted_pick(cands, styles, prev_h, net)
			var w := float(pick["width"])
			_place_module(pick, origin + along * (pos + w * 0.5), basis, name, net)
			pos += w
			remaining_steps -= int(round(w / WIDTH_STEP))
			prev_variant = str(pick.get("variant_of", pick["id"]))
			prev_h = deck_of(pick)


func _weighted_pick(cands: Array, styles: Dictionary, prev_h: float, net: bool) -> Dictionary:
	var total := 0.0
	var ws: Array = []
	for e: Dictionary in cands:
		var w := float(styles.get(str(e.get("style", "")), 0.5))
		if net and prev_h > 0.0:
			var dh := absf(deck_of(e) - prev_h)
			w *= 1.0 if dh <= 3.0 else (0.35 if dh <= 6.0 else 0.12)
		ws.append(w)
		total += w
	var r := rng.randf() * total
	for i in cands.size():
		r -= float(ws[i])
		if r <= 0.0:
			return cands[i]
	return cands[cands.size() - 1]


func _place_module(e: Dictionary, pos: Vector3, basis: Basis, row: String, net: bool) -> Node3D:
	var inst := instance(str(e["file"]))
	if inst == null:
		report["warnings"].append("cannot instance " + str(e["file"]))
		return null
	inst.name = "%s_%d" % [str(e["id"]), placed.size()]
	inst.transform = Transform3D(basis, pos)
	inst.set_meta(&"module_id", str(e["id"]))
	inst.set_meta(&"row", row)
	grp("Buildings").add_child(inst)
	placed.append({"id": str(e["id"]), "entry": e, "xf": inst.transform, "w": float(e["width"]),
		"d": float(e["depth"]), "h": float(e.get("height", 10.0)), "row": row, "net": net, "node": inst})
	return inst


## Narrow plaster pier filling < 0.5 m slack in a row (looks like a party-wall pilaster).
func _filler_pier(pos: Vector3, basis: Basis, width: float, row: String) -> void:
	if width < 0.02:
		return
	var n := Node3D.new()
	n.name = "Pier_" + row
	grp("Buildings").add_child(n)
	var k := CS.Kit.new(n)
	k.box(WM.arch("cement_render"), Transform3D(basis, pos + Vector3(0, 3.6, 0) - basis.z * 4.0), Vector3(width, 7.2, 8.0), 2.0, &"concrete")
	k.finish("PierMesh")


func _wall_run(wr: Array) -> void:
	var start: Vector2 = wr[0]
	var facing: Vector2 = wr[1]
	var length: float = wr[2]
	var kind: String = wr[3]
	if length <= 0.0:
		return
	var pool := cat_find("city", func(e: Dictionary) -> bool: return str(e.get("kind", "")) == kind)
	if pool.is_empty():
		return
	var basis := _row_basis(facing)
	var along := basis.x
	var origin := Vector3(start.x, 0.0, start.y)
	var pos := 0.0
	var prev := ""
	while pos < length - 1.0:
		var cands := pool.filter(func(e: Dictionary) -> bool: return str(e.get("id")) != prev)
		var e: Dictionary = cands[rng.randi_range(0, cands.size() - 1)]
		var w := float(e["width"])
		var inst := instance(str(e["file"]))
		if inst == null:
			return
		inst.name = "%s_wall_%d" % [str(e["id"]), int(pos)]
		inst.transform = Transform3D(basis, origin + along * (pos + w * 0.5))
		grp("Buildings").add_child(inst)
		prev = str(e["id"])
		pos += w


# =================================================================================================
# landmarks (catalog first, procedural stand-ins otherwise)
# =================================================================================================

var temple_hall: Node3D          # dinh_hang_may complex (or the procedural stand-in)
var water_tower: Node3D
var market_hall: Node3D
var tea_stall: Node3D
var cafe: Node3D
var islet: Node3D
var bridge: Node3D
var lake_steps: Array[Node3D] = []
var _lm_entries: Dictionary = {}      # landmark node -> catalog entry


func _landmark(keywords: Array, fallback: Callable, pos: Vector3, yaw: float, label: String) -> Node3D:
	var e := cat_keyword(["landmarks"], keywords)
	var n: Node3D
	if not e.is_empty():
		n = instance(str(e["file"]))
		n.name = label
		n.set_meta(&"catalog_id", str(e["id"]))
		_lm_entries[n] = e
	else:
		n = fallback.call()
		n.name = label
		placeholder("%s (procedural, scripts/world/city_structures.gd)" % label, "no landmarks catalog entry matching %s" % str(keywords))
	n.position = pos
	n.rotation.y = yaw
	grp("Landmarks").add_child(n)
	return n


## Instance a landmark by exact catalog id (null when the kit does not provide it).
func lm(id: String, pos: Vector3, yaw: float, label: String = "", parent: Node3D = null) -> Node3D:
	var e := cat_by_id("landmarks", id)
	if e.is_empty():
		return null
	var n := instance(str(e["file"]))
	if n == null:
		return null
	n.name = label if label != "" else id
	n.set_meta(&"catalog_id", id)
	n.position = pos
	n.rotation.y = yaw
	_lm_entries[n] = e
	(parent if parent != null else grp("Landmarks")).add_child(n)
	return n


## World position of a catalog marker (`markers[name][idx]`, Godot space relative to the module).
func lm_point(n: Node3D, marker: String, fallback: Vector3, idx: int = 0) -> Vector3:
	if n == null or not _lm_entries.has(n):
		return fallback
	var mk: Dictionary = (_lm_entries[n] as Dictionary).get("markers", {})
	if not mk.has(marker) or (mk[marker] as Array).size() <= idx:
		return fallback
	var a: Array = mk[marker][idx]
	return n.transform * Vector3(float(a[0]), float(a[1]), float(a[2]))


## World positions of a catalog point list (nap_spots / climb_points / entrances) of a landmark.
func lm_points(n: Node3D, key: String) -> Array:
	var out: Array = []
	if n == null or not _lm_entries.has(n):
		return out
	for a: Variant in (_lm_entries[n] as Dictionary).get(key, []):
		var arr := a as Array
		out.append(n.transform * Vector3(float(arr[0]), float(arr[1]), float(arr[2])))
	return out


func _build_landmarks() -> void:
	var tr: Rect2 = L.TEMPLE_RECT
	# --- Đình Hàng Mây: kit complex (gate on Phố Đình, +Z front turned to face the street at -Z) ---
	temple_hall = lm("dinh_hang_may", Vector3(L.TEMPLE_GATE.x, 0, L.TEMPLE_GATE.y), PI, "DinhHangMay")
	var gate_half := 13.0
	if temple_hall == null:
		temple_hall = _landmark(["temple_hall"], func() -> Node3D: return CS.make_temple_hall(), Vector3(L.TEMPLE_HALL_CENTER.x, 0, L.TEMPLE_HALL_CENTER.y), PI, "TempleHall")
		_landmark(["tam_quan"], func() -> Node3D: return CS.make_temple_gate(), Vector3(0, 0, tr.position.y + 0.8), PI, "TempleGate")
		_landmark(["bell_pavilion"], func() -> Node3D: return CS.make_bell_pavilion(), Vector3(L.BELL_PAVILION.x, 0, L.BELL_PAVILION.y), PI, "BellPavilion")
		_landmark(["incense_burner"], func() -> Node3D: return CS.make_incense_burner(), Vector3(0, 0, 80.0), 0.0, "IncenseBurner")
		gate_half = 6.4
	# outer garden walls around the complex (leave the complex frontage open; the kit has its own walls)
	var fz := tr.position.y + 0.8
	var walls := [
		[Vector3(tr.position.x, 0, fz), Vector3(-gate_half, 0, fz)],
		[Vector3(gate_half, 0, fz), Vector3(tr.end.x, 0, fz)],
		[Vector3(tr.position.x, 0, fz), Vector3(tr.position.x, 0, tr.end.y - 0.5)],
		[Vector3(tr.end.x, 0, fz), Vector3(tr.end.x, 0, tr.end.y - 0.5)],
		[Vector3(tr.position.x, 0, tr.end.y - 0.5), Vector3(tr.end.x, 0, tr.end.y - 0.5)],
	]
	for w: Array in walls:
		grp("Landmarks").add_child(CS.make_wall(w[0], w[1]))
	# --- market: covered hall facing Phố Chợ (west), open-air stall lanes, gate arch on the fish lane ---
	var mf: Vector2 = L.MARKET_HALL_FRONT
	market_hall = lm("cho_market_hall", Vector3(mf.x, 0, mf.y), -PI * 0.5, "ChoMarketHall")
	if market_hall == null:
		var mh: Rect2 = L.MARKET_HALL
		market_hall = _landmark(["market_hall"], func() -> Node3D: return CS.make_market_hall(mh.size.x, mh.size.y),
			Vector3(mh.get_center().x, 0, mh.get_center().y), 0.0, "MarketHall")
	lm("cho_gate_arch", Vector3(57.2, 0, L.FISH_LANE_Z), PI * 0.5, "ChoGateArch")
	_build_market_stalls()
	# --- water tower (no kit asset: procedural steel tower) ---
	var wt: Vector2 = L.WATER_TOWER_POS
	water_tower = _landmark(["water_tower", "thap_nuoc"], func() -> Node3D: return CS.make_water_tower(), Vector3(wt.x, 0, wt.y), 0.0, "WaterTower")
	# --- Grandma Tư's tea stall + Bông's café are placed by the street furniture / row passes ---
	# --- small shrines: tree shrine at the hẻm A / hẻm B crossing, wall box shrines in alleys ---
	lm("shrine_tree", Vector3(-90.6, 0, -6.7), PI * 0.5, "ShrineTree_HemCross")
	lm("shrine_tree", Vector3(-31.0, 0, 50.5), PI, "ShrineTree_LakeSW")
	lm("shrine_wall_box", Vector3(-91.05, 1.5, 22.0), PI * 0.5, "ShrineBox_HemA")
	lm("shrine_wall_box", Vector3(114.0, 1.6, -63.05), PI, "ShrineBox_Market")


func _build_market_stalls() -> void:
	var n := 0
	for sl: Array in L.STALL_LANES:
		if lm("cho_stall_lane", Vector3(float(sl[0]), 0, float(sl[1])), float(sl[2]), "StallLane_%02d" % n) != null:
			n += 1
	if n == 0:
		# stand-in stalls only when the landmark kit has no stall lane
		placeholder("Market stalls (procedural CS.make_stall)", "no cho_stall_lane in the landmarks catalog")
		for sl: Array in L.STALL_LANES:
			for k in 3:
				var s := CS.make_stall(["veg", "fruit", "fish", "dry", "flowers"][(n + k) % 5], rng, true)
				var b := Basis(Vector3.UP, float(sl[2]))
				s.transform = Transform3D(b, Vector3(float(sl[0]), 0, float(sl[1])) + b.x * (k - 1) * 3.6)
				grp("Landmarks").add_child(s)
				n += 1
	report["counts"]["market_stalls"] = n
	_build_market_clutter()


## Life around the stalls: crate stacks, sacks, basins, umbrellas (with shelter areas), parked
## scooters along the hall, scattered cardboard — all catalog props, deterministic.
func _build_market_clutter() -> void:
	var lg := grp("StreetFurniture")
	var small := ["wooden_crate", "plastic_crate_blue", "plastic_crate_red", "styrofoam_box", "rice_sack", "basin_plastic",
		"fruit_basket", "bucket_plastic", "cardboard_box_closed", "recycling_sack"]
	var placed_n := 0
	for sl: Array in L.STALL_LANES:
		var b := Basis(Vector3.UP, float(sl[2]))
		var front := Vector3(float(sl[0]), 0.0, float(sl[1]))
		# behind the stalls (service side): stacked crates and sacks
		for k in 5:
			var along := rng.randf_range(-5.5, 5.5)
			var p := front - b.z * rng.randf_range(3.5, 4.1) + b.x * along
			var id: String = small[rng.randi_range(0, 4)]
			var base := _prop(id, p, rng.randf_range(-0.3, 0.3) + float(sl[2]), lg)
			if base != null:
				placed_n += 1
				if id.contains("crate") and rng.randf() < 0.6:
					_prop(id, p + Vector3(0, 0.28, 0), rng.randf_range(-0.2, 0.2) + float(sl[2]), lg)
		# in front (aisle side): a basin or basket at the kerb of the stall
		if rng.randf() < 0.8:
			_prop(["basin_plastic", "fruit_basket", "fish_basin"][rng.randi_range(0, 2)], front + b.z * 0.45 + b.x * rng.randf_range(-4.5, 4.5), rng.randf() * TAU, lg)
	# umbrella vendors on the open plaza east of the hall + shelter areas under them
	var umb := 0
	for p2: Vector2 in [Vector2(86.0, -46.0), Vector2(105.0, -46.0), Vector2(114.0, -12.0), Vector2(88.0, 18.0), Vector2(104.0, 18.0), Vector2(70.0, 20.0)]:
		var up := Vector3(p2.x, 0.0, p2.y)
		if _prop("umbrella_tarp", up, rng.randf() * TAU, lg) == null:
			continue
		umb += 1
		_prop("table_plastic_low", up + Vector3(0.3, 0, 0.2), rng.randf() * TAU, lg)
		_prop(["fruit_basket", "flower_bucket", "fish_basin"][umb % 3], up + Vector3(-0.5, 0, 0.6), rng.randf() * TAU, lg)
		_prop("stool_plastic_red" if umb % 2 == 0 else "stool_plastic_blue", up + Vector3(0.9, 0, -0.5), rng.randf() * TAU, lg)
		var a := Area3D.new()
		a.name = "Shelter_Umbrella_%d" % umb
		a.add_to_group(&"shelter")
		a.collision_layer = 1 << 9
		a.collision_mask = 0
		a.monitoring = false
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(2.4, 2.2, 2.4)
		cs.shape = bs
		a.add_child(cs)
		a.position = up + Vector3(0, 1.1, 0)
		grp("Zones").add_child(a)
	# scooters parked in a row along the hall's north and south sides
	var bikes := cat_find("vehicles", func(e: Dictionary) -> bool: return str(e.get("id", "")) in ["scooter_auto", "underbone_step", "manual_classic", "bicycle_city"])
	if not bikes.is_empty():
		for side: float in [-1.0, 1.0]:
			var z := L.MARKET_HALL_FRONT.y + side * 13.6
			var x := 71.0
			while x < 80.5:
				var e: Dictionary = bikes[rng.randi_range(0, bikes.size() - 1)]
				var bk := instance(str(e["file"]))
				bk.position = Vector3(x, 0.0, z)
				bk.rotation.y = side * PI * 0.5 + rng.randf_range(-0.15, 0.15) + PI * 0.5
				lg.add_child(bk)
				x += rng.randf_range(0.85, 1.3)
	report["counts"]["market_clutter"] = placed_n + umb
	# exposed party walls along the market entrance: bougainvillea, posters, a wall shrine
	for wd: Array in [[Vector3(64.5, 0.0, -38.0), Vector3(0, 0, 1)], [Vector3(64.5, 0.0, -12.0), Vector3(0, 0, -1)]]:
		_wall_dressing(wd[0], wd[1])


## Dress a blank side wall (base point on the wall face, outward normal): climbing bougainvillea,
## two pasted posters (decals) and a red wall shrine box.
func _wall_dressing(p: Vector3, n: Vector3) -> void:
	var yaw := atan2(n.x, n.z)
	var b := Basis(Vector3.UP, yaw)
	_plant("bougainvillea_wall", p + n * 0.05 - b.x * 3.0, yaw)
	var dec_basis := Basis(b.x, n, b.x.cross(n))
	var posters := ["poster_rent", "poster_lessons", "poster_lost_cat", "poster_festival"]
	for k in 2:
		var d := _decal(posters[rng.randi_range(0, posters.size() - 1)], p + n * 0.05 + b.x * (1.0 + k * 0.9) + Vector3(0, 1.55 + k * 0.12, 0),
			Vector3(0.6, 0.3, 0.8), dec_basis.rotated(n, rng.randf_range(-0.06, 0.06)))
		d.cull_mask = 1
	lm("shrine_wall_box", p + n * 0.02 + b.x * 3.6 + Vector3(0, 1.45, 0), yaw, "ShrineBox_Wall")


# =================================================================================================
# nature: street trees, park trees, banyans
# =================================================================================================

## Tree from the nature catalog by role, varied deterministically per seed; procedural fallback.
const TREE_IDS := {
	&"banyan": ["banyan"],
	&"street": ["sao_tree", "flame_tree", "sao_tree"],
	&"park": ["flame_tree", "sao_tree", "flame_tree", "areca_palm", "sao_tree", "coconut_palm"],
	&"shore": ["weeping_willow"],
	&"small": ["frangipani", "areca_palm", "shrub_ixora"],
}


func _tree(kind: StringName, pos: Vector3, yaw: float, seed_i: int) -> Node3D:
	var ids: Array = TREE_IDS.get(kind, ["flame_tree"])
	var e := cat_by_id("nature", str(ids[absi(seed_i) % ids.size()]))
	if e.is_empty():
		for id: String in ids:
			e = cat_by_id("nature", id)
			if not e.is_empty():
				break
	var n: Node3D
	if not e.is_empty():
		n = instance(str(e["file"]))
		var sc := 0.88 + float(absi(seed_i * 7919) % 100) / 400.0
		n.scale = Vector3(sc, sc, sc)
	else:
		n = TG.make_tree(&"park" if kind == &"shore" else kind, seed_i)
		_tree_count += 1
	n.position = pos
	n.rotation.y = yaw
	grp("Nature").add_child(n)
	return n


## Nature kit scene by id at a transform (null when missing).
func _plant(id: String, pos: Vector3, yaw: float, sc: float = 1.0, parent: Node3D = null) -> Node3D:
	var e := cat_by_id("nature", id)
	if e.is_empty():
		return null
	var n := instance(str(e["file"]))
	n.position = pos
	n.rotation.y = yaw
	n.scale = Vector3(sc, sc, sc)
	(parent if parent != null else grp("Nature")).add_child(n)
	return n


## Scatter a small nature asset as one MultiMeshInstance3D per mesh surface set (weeds, moss, litter).
func _scatter_mm(id: String, xfs: Array[Transform3D], vis_end: float = 45.0) -> int:
	var e := cat_by_id("nature", id)
	if e.is_empty() or xfs.is_empty():
		return 0
	var inst := instance(str(e["file"]))
	if inst == null:
		return 0
	var meshes: Array = []
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D and (nd as MeshInstance3D).mesh != null:
			meshes.append([(nd as MeshInstance3D).mesh, _rel_xform(inst, nd as Node3D)])
		for c in nd.get_children():
			stack.append(c)
	for mm_data: Array in meshes:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mm_data[0]
		mm.instance_count = xfs.size()
		var local: Transform3D = mm_data[1]
		for i in xfs.size():
			mm.set_instance_transform(i, xfs[i] * local)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "MM_" + id
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = vis_end
		mmi.visibility_range_end_margin = 8.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		grp("Nature").add_child(mmi)
	inst.free()
	return xfs.size()


func _rel_xform(root_n: Node3D, nd: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = nd
	while cur != null and cur != root_n:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


var temple_banyan: Node3D
var lake_banyan: Node3D


func _build_nature() -> void:
	if cat_by_id("nature", "flame_tree").is_empty() and cat_by_id("nature", "sao_tree").is_empty():
		placeholder("Trees & banyans (procedural, scripts/world/tree_gen.gd)", "no assets/models/nature catalog yet")
	var i := 0
	for p: Vector3 in tree_pits:
		_tree(&"street", p, rng.randf() * TAU, 1000 + i)
		i += 1
	# park ring trees between promenade and streets; willows lean over the water at the shore
	for k in 34:
		var t := TAU * k / 34.0 + rng.randf_range(-0.05, 0.05)
		var q := _ell(t, 1.0)
		var dir := (q - L.LAKE_CENTER).normalized()
		var p := q + dir * (L.PROMENADE_W + rng.randf_range(2.0, 5.0))
		if p.x < -47.0 or p.x > 42.0 or p.y < -47.5 or p.y > 53.0:
			continue
		if p.distance_to(L.LAKE_BANYAN) < 9.0:
			continue
		_tree(&"park", Vector3(p.x, 0, p.y), rng.randf() * TAU, 2000 + k)
	for k in 9:
		var t := TAU * (k + 0.37) / 9.0
		var q := _ell(t, 1.0)
		var dir := (q - L.LAKE_CENTER).normalized()
		var p := q + dir * (L.PROMENADE_W + 0.9)
		if p.distance_to(Vector2(L.ISLET_CENTER.x + 18.0, L.ISLET_CENTER.y)) < 6.0:
			continue
		_tree(&"shore", Vector3(p.x, 0, p.y), atan2(-dir.x, -dir.y), 3000 + k)
	# temple courtyard banyan in the kit's planter
	var tb := lm_point(temple_hall, "MARKER_banyan", Vector3(L.TEMPLE_BANYAN.x, 0.0, L.TEMPLE_BANYAN.y))
	temple_banyan = _tree(&"banyan", tb, 0.6, 77)
	temple_banyan.name = "TempleBanyan"
	lake_banyan = _tree(&"banyan", Vector3(L.LAKE_BANYAN.x, 0.0, L.LAKE_BANYAN.y), 2.1, 4242)
	lake_banyan.name = "LakeBanyan"
	lake_banyan.scale = Vector3(1.12, 1.12, 1.12)
	# temple garden (outside the kit complex): frangipani, areca, coconut, bamboo, hedges
	var garden := [["frangipani", Vector2(-24, 78)], ["frangipani", Vector2(24, 78)], ["areca_palm", Vector2(-20, 90)],
		["areca_palm", Vector2(-27, 96)], ["coconut_palm", Vector2(22, 92)], ["coconut_palm", Vector2(28, 102)],
		["bamboo_clump", Vector2(-30, 106)], ["bamboo_clump", Vector2(30, 84)], ["frangipani", Vector2(-18, 104)],
		["shrub_ixora", Vector2(-17, 74)], ["shrub_ixora", Vector2(17, 74)], ["fern_clump", Vector2(-15.5, 80)]]
	for g: Array in garden:
		var v: Vector2 = g[1]
		_plant(str(g[0]), Vector3(v.x, 0, v.y), rng.randf() * TAU, rng.randf_range(0.9, 1.1))
	for hx: float in [-30.0, -25.0, 25.0, 30.0]:
		_plant("hedge_trimmed", Vector3(hx, 0, 71.6), 0.0)
	# courtyards & market corners
	for g: Array in [["bamboo_clump", Vector2(-116.5, -46.0)], ["areca_palm", Vector2(-106.0, -22.5)], ["frangipani", Vector2(108, 30)],
			["areca_palm", Vector2(64, 36)], ["shrub_ixora", Vector2(-99.0, -24.0)], ["fern_clump", Vector2(-91.6, 12.0)],
			["fern_clump", Vector2(-88.4, 30.0)]]:
		var v: Vector2 = g[1]
		_plant(str(g[0]), Vector3(v.x, 0, v.y), rng.randf() * TAU)
	# bougainvillea on alley and garden walls (front +Z = away from the wall)
	for g: Array in [[Vector3(-91.1, 0, 8.0), PI * 0.5], [Vector3(-88.9, 0, -30.0), -PI * 0.5], [Vector3(-33.5, 0, 88.0), PI * 0.5],
			[Vector3(33.5, 0, 98.0), -PI * 0.5], [Vector3(-104.75, 0, -40.0), -PI * 0.5], [Vector3(-110.0, 0, -48.6), 0.0]]:
		_plant("bougainvillea_wall", g[0], g[1])
	_scatter_ground_cover()
	report["counts"]["procedural_trees"] = _tree_count


## Weeds in kerb cracks / wall feet, moss in alleys, grass tufts at the lawn edge, leaf litter under trees
## — MultiMeshes, faded out with distance.
func _scatter_ground_cover() -> void:
	var weeds: Array[Transform3D] = []
	var weeds_b: Array[Transform3D] = []
	var moss: Array[Transform3D] = []
	var tufts: Array[Transform3D] = []
	var tufts_b: Array[Transform3D] = []
	var litter: Array[Transform3D] = []
	var rnd := func(p: Vector3, sc: float) -> Transform3D:
		return Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc * rng.randf_range(0.7, 1.3)), p)
	for s: Array in L.STREETS:
		var axis: String = s[1]
		var c: float = s[2]
		var hw := float(s[5]) * 0.5
		var sw := float(s[6])
		var t := float(s[3]) + 2.0
		while t < float(s[4]) - 2.0:
			var sd := -1.0 if rng.randf() < 0.5 else 1.0
			var r := rng.randf()
			var off := c + sd * (hw + 0.17) if r < 0.6 else c + sd * (hw + sw - 0.12)   # kerb joint or wall foot
			var p := Vector3(t, 0.0, off) if axis == "x" else Vector3(off, 0.0, t)
			if absf(p.x) < 120.0 and absf(p.z) < 108.0:
				(weeds if rng.randf() < 0.6 else weeds_b).append(rnd.call(p, 1.0))
			t += rng.randf_range(1.5, 4.5)
	# alleys: moss + weeds along both walls of hẻm A / B and ngõ C
	for rc: Rect2 in [L.HEM_A, L.HEM_B, L.NGO_C]:
		var long_x := rc.size.x > rc.size.y
		var length := rc.size.x if long_x else rc.size.y
		var d := 0.0
		while d < length:
			for side: float in [0.0, 1.0]:
				if rng.randf() < 0.55:
					var p := Vector3(rc.position.x + d, 0.0, rc.position.y + side * rc.size.y + (0.12 if side == 0.0 else -0.12)) if long_x \
						else Vector3(rc.position.x + side * rc.size.x + (0.12 if side == 0.0 else -0.12), 0.0, rc.position.y + d)
					moss.append(rnd.call(p, 1.2))
					if rng.randf() < 0.4:
						weeds.append(rnd.call(p, 0.9))
			d += rng.randf_range(0.6, 1.6)
	# lawn edge tufts around the lake park
	for k in 260:
		var tt := rng.randf() * TAU
		var q := _ell(tt, 1.0)
		var dir := (q - L.LAKE_CENTER).normalized()
		var p := q + dir * (L.PROMENADE_W + rng.randf_range(-0.3, 6.0))
		if p.x < -48.0 or p.x > 43.0 or p.y < -48.0 or p.y > 54.0:
			continue
		(tufts if k % 2 == 0 else tufts_b).append(rnd.call(Vector3(p.x, 0.0, p.y), 1.0))
	# leaf litter under the street & park trees
	for tn: Node in grp("Nature").get_children():
		if not tn is Node3D or tn is MultiMeshInstance3D:
			continue
		var tp := (tn as Node3D).position
		if tp.y > 0.5:
			continue
		for k in 3:
			var a := rng.randf() * TAU
			var r := rng.randf_range(0.5, 3.0)
			litter.append(rnd.call(tp + Vector3(cos(a) * r, 0.01, sin(a) * r), 1.0))
	var n := 0
	n += _scatter_mm("weeds_crack_a", weeds)
	n += _scatter_mm("weeds_crack_b", weeds_b)
	n += _scatter_mm("moss_patch", moss, 35.0)
	n += _scatter_mm("grass_tuft_a", tufts, 40.0)
	n += _scatter_mm("grass_tuft_b", tufts_b, 40.0)
	n += _scatter_mm("leaf_litter", litter, 50.0)
	report["counts"]["ground_cover_instances"] = n


# =================================================================================================
# street furniture: lamps, poles, manholes, drains, bins, signs, benches, stall, carts
# =================================================================================================

var poles: Array = []          # [Node3D pole, street id, side]


func _prop(id: String, pos: Vector3, yaw: float, parent: Node3D = null) -> Node3D:
	var e := cat_by_id("props", id)
	if e.is_empty():
		return null
	var n := instance(str(e["file"]))
	if n == null:
		return null
	n.position = pos
	n.rotation.y = yaw
	(parent if parent != null else grp("StreetFurniture")).add_child(n)
	return n


func _build_street_furniture() -> void:
	var sf := grp("StreetFurniture")
	for s: Array in L.STREETS:
		var id: String = s[0]
		var axis: String = s[1]
		var c: float = s[2]
		var hw: float = float(s[5]) * 0.5
		var a0 := maxf(float(s[3]), -118.0)
		var a1 := minf(float(s[4]), 118.0)
		# street lamps alternate sides every ~18 m
		var t := a0 + 7.0
		var side := 1
		while t < a1 - 4.0:
			var off := c + side * (hw + 0.55)
			var pos := Vector3(t, 0, off) if axis == "x" else Vector3(off, 0, t)
			var yaw := (0.0 if side < 0 else PI) if axis == "x" else (PI * 0.5 if side < 0 else -PI * 0.5)
			var lamp_id := "lamp_post_colonial" if id in ["pho_dinh", "pho_ho"] else "lamp_post_modern"
			if _prop(lamp_id, pos, yaw) == null:
				_fallback_lamp(pos)
			t += 18.0
			side = -side
		# electric poles every ~32 m on one side (cable spans between them)
		var pole_side := -1 if id != "pho_dinh" else 1
		t = a0 + 14.0
		var prev_pole: Node3D = null
		while t < a1 - 4.0:
			var off := c + pole_side * (hw + 0.45)
			var pos := Vector3(t, 0, off) if axis == "x" else Vector3(off, 0, t)
			var yaw := PI * 0.5 if axis == "x" else 0.0
			var p := _prop("electric_pole_concrete", pos, yaw)
			if p != null:
				poles.append([p, id, pole_side])
			t += rng.randf_range(28.0, 34.0)
		# manholes in the road, drain grates in the gutter
		t = a0 + 10.0
		while t < a1 - 4.0:
			var mpos := Vector3(t, ROAD_Y, c + rng.randf_range(-1.5, 1.5)) if axis == "x" else Vector3(c + rng.randf_range(-1.2, 1.2), ROAD_Y, t)
			_prop("manhole_cover", mpos, rng.randf() * TAU)
			for sd: float in [-1, 1]:
				var g := c + sd * (hw - 0.22)
				var dpos := Vector3(t + 6.0, ROAD_Y, g) if axis == "x" else Vector3(g, ROAD_Y, t + 6.0)
				_prop("drain_grate", dpos, 0.0 if axis == "x" else PI * 0.5)
			t += rng.randf_range(24.0, 32.0)
		# bins, hydrants, mailboxes, signs along the building side of sidewalks
		t = a0 + 5.0
		while t < a1 - 3.0:
			var sd := -1 if rng.randf() < 0.5 else 1
			var off := c + sd * (hw + float(s[6]) - 0.6)
			var pos := Vector3(t, 0, off) if axis == "x" else Vector3(off, 0, t)
			var yaw := (0.0 if sd < 0 else PI) if axis == "x" else (PI * 0.5 if sd < 0 else -PI * 0.5)
			var choice := rng.randf()
			var pid := "trash_bin_municipal"
			if choice < 0.18:
				pid = "fire_hydrant"
			elif choice < 0.3:
				pid = "mailbox"
			elif choice < 0.5:
				pid = ["sign_aframe_com", "sign_aframe_cafe", "sign_lightbox", "banner_standing"][rng.randi_range(0, 3)]
			elif choice < 0.62:
				pid = "bicycle_rack"
			elif choice < 0.75:
				pid = "gas_cylinder"
			_prop(pid, pos, yaw + rng.randf_range(-0.2, 0.2))
			t += rng.randf_range(7.0, 14.0)
	# roadwork corner on Phố Hồ
	_prop("construction_barrier", Vector3(-54.0, ROAD_Y, 20.0), PI * 0.5)
	_prop("traffic_cone", Vector3(-54.0, ROAD_Y, 18.6), 0.0)
	_prop("traffic_cone", Vector3(-54.6, ROAD_Y, 21.6), 0.4)
	_prop("cable_drum", Vector3(-50.3, 0, 23.0), 0.3)
	# (lake benches & promenade lamps come with the embankment kit — _kit_embankment)
	# Grandma Tư's tea stall at hẻm A's north mouth (on the main-street south sidewalk, back on the facade)
	tea_stall = lm("quan_tra_ba_tu", Vector3(L.TEA_STALL.x, 0.0, L.TEA_STALL.y), PI, "TeaStall", sf)
	if tea_stall == null:
		placeholder("Tea stall (procedural CS.make_tea_stall)", "no quan_tra_ba_tu in the landmarks catalog")
		tea_stall = CS.make_tea_stall()
		tea_stall.name = "TeaStall"
		tea_stall.position = Vector3(L.TEA_STALL.x - 0.6, 0.0, L.TEA_STALL.y + 1.5)
		tea_stall.rotation.y = PI
		sf.add_child(tea_stall)
	# chú Sáu's bánh mì cart on Phố Hàng Mây (north sidewalk) + stools
	if _prop("banh_mi_cart", Vector3(18.0, 0.0, -75.3), 0.0) == null:
		var cart := CS.make_banh_mi_cart()
		cart.position = Vector3(18.0, 0.0, -75.3)
		sf.add_child(cart)
	for k in 3:
		_prop(["stool_plastic_red", "stool_plastic_blue", "stool_plastic_green"][k], Vector3(16.2 + k * 0.7, 0.0, -74.2 + (k % 2) * 0.3), rng.randf() * TAU)
	# street food & market clutter on the sidewalks (xôi cart, phở stove, crates, flowers)
	_prop("food_cart_xoi", Vector3(-40.0, 0.0, -64.4), PI)
	_prop("pho_pot_stove", Vector3(-12.0, 0.0, -75.6), 0.3)
	_prop("table_plastic_low", Vector3(-11.0, 0.0, -74.6), 0.1)
	for k in 4:
		_prop(["stool_plastic_red", "stool_plastic_blue"][k % 2], Vector3(-11.8 + (k % 2) * 1.6, 0.0, -74.0 - (k / 2) * 1.2), rng.randf() * TAU)
	_prop("flower_bucket", Vector3(46.0, 0.0, -64.3), 0.0)
	_prop("flower_bucket", Vector3(46.7, 0.0, -64.4), 1.0)
	# Bông's café (row module) gets potted plants by its terrace; the kit has its own furniture
	if cafe == null:
		for k in 6:
			var ch := CS.make_rattan_chair()
			ch.name = "CafeChair_%d" % k
			ch.position = Vector3(58.5 + (k % 3) * 1.1, 0, -64.6 - (k / 3) * 1.0)
			ch.rotation.y = rng.randf_range(-0.6, 0.6) + (PI if k / 3 == 1 else 0.0)
			sf.add_child(ch)
	# parked scooters / bicycles from the vehicles catalog (if any)
	var bikes := cat_find("vehicles", func(e: Dictionary) -> bool: return str(e.get("id", "")).contains("scooter") or str(e.get("id", "")).contains("bike") or str(e.get("kind", "")) in ["scooter", "bicycle", "motorbike"])
	if not bikes.is_empty():
		var n := 0
		for s: Array in L.STREETS:
			var axis: String = s[1]
			var c: float = s[2]
			var hw: float = float(s[5]) * 0.5
			var t := float(s[3]) + 9.0
			while t < float(s[4]) - 9.0 and n < 90:
				if rng.randf() < 0.55:
					var e: Dictionary = bikes[rng.randi_range(0, bikes.size() - 1)]
					var sd := 1 if rng.randf() < 0.5 else -1
					var off := c + sd * (hw + 1.0)
					var pos := Vector3(t, 0, off) if axis == "x" else Vector3(off, 0, t)
					var yaw := (PI * 0.5 if axis == "x" else 0.0) + rng.randf_range(-0.25, 0.25) + (PI if rng.randf() < 0.5 else 0.0)
					var b := instance(str(e["file"]))
					b.position = pos
					b.rotation.y = yaw
					sf.add_child(b)
					n += 1
				t += rng.randf_range(2.2, 6.0)
		report["counts"]["parked_vehicles"] = n
	else:
		placeholder("Parked scooters", "no vehicles catalog yet — streets have none until vehicles-nature delivers (rebuild picks them up)")


func _fallback_lamp(pos: Vector3) -> void:
	var l := OmniLight3D.new()
	l.position = pos + Vector3(0, 4.2, 0)
	l.omni_range = 12.0
	l.light_energy = 1.6
	l.light_color = Color(1.0, 0.78, 0.5)
	l.add_to_group(&"street_lamp")
	grp("Lights").add_child(l)


# =================================================================================================
# festival lanterns (shown on the festival night by NightLights)
# =================================================================================================

func _build_festival() -> void:
	var fg := grp("Festival")
	fg.add_to_group(&"festival_lantern")
	var spans := 0
	for s: Array in L.STREETS:
		if not s[0] in ["pho_hang_may", "pho_dinh"]:
			continue
		var c: float = s[2]
		var half := float(s[5]) * 0.5 + float(s[6]) - 0.3
		var x := -110.0
		while x < 110.0:
			var a := Vector3(x, 5.4, c - half)
			var b := Vector3(x + rng.randf_range(-1.5, 1.5), 5.6, c + half)
			var ls := CS.make_lantern_string(a, b, 9, rng)
			fg.add_child(ls)
			if spans % 3 == 0:
				var l := OmniLight3D.new()
				l.name = "LanternGlow"
				l.position = (a + b) * 0.5 + Vector3(0, -0.8, 0)
				l.omni_range = 9.0
				l.light_energy = 1.3
				l.light_color = Color(1.0, 0.55, 0.3)
				l.shadow_enabled = false
				l.distance_fade_enabled = true
				l.distance_fade_begin = 70.0
				l.add_to_group(&"festival_lantern")
				fg.add_child(l)
			spans += 1
			x += rng.randf_range(7.0, 10.0)
	# lantern strings across the temple courtyard
	# lantern strings across the temple garden on both sides of the kit complex
	for k in 6:
		var z := 73.0 + k * 5.5
		fg.add_child(CS.make_lantern_string(Vector3(-33.5, 3.4, z), Vector3(-14.0, 3.6, z + 1.0), 8, rng))
		fg.add_child(CS.make_lantern_string(Vector3(14.0, 3.6, z + 0.5), Vector3(33.5, 3.4, z), 8, rng))

	report["counts"]["lantern_spans"] = spans


# =================================================================================================
# decals
# =================================================================================================

func _decal(tex: String, pos: Vector3, size: Vector3, basis: Basis, group: StringName = &"", normal: String = "") -> Decal:
	var d := Decal.new()
	d.texture_albedo = load("res://assets/textures/decals/%s.png" % tex)
	if normal != "":
		d.texture_normal = load("res://assets/textures/decals/%s.png" % normal)
	d.size = size
	d.transform = Transform3D(basis, pos)
	d.distance_fade_enabled = true
	d.distance_fade_begin = 45.0
	d.distance_fade_length = 10.0
	d.cull_mask = 1
	d.upper_fade = 0.3
	d.lower_fade = 0.3
	if group != &"":
		d.add_to_group(group)
	grp("Decals").add_child(d)
	return d


func _ground_spot(on_road: bool) -> Vector3:
	var s: Array = L.STREETS[rng.randi_range(0, L.STREETS.size() - 1)]
	var axis: String = s[1]
	var c: float = s[2]
	var hw := float(s[5]) * 0.5
	var t := rng.randf_range(maxf(float(s[3]), -115.0), minf(float(s[4]), 115.0))
	var off: float
	if on_road:
		off = c + rng.randf_range(-hw + 0.5, hw - 0.5)
	else:
		var sd := 1 if rng.randf() < 0.5 else -1
		off = c + sd * (hw + rng.randf_range(0.4, float(s[6]) - 0.3))
	var y := ROAD_Y if on_road else 0.0
	return Vector3(t, y, off) if axis == "x" else Vector3(off, y, t)


func _build_decals() -> void:
	var up := Basis(Vector3.UP, 0.0)
	for i in 34:
		var p := _ground_spot(true)
		_decal(["oil_stain_a", "oil_stain_b"][i % 2], p, Vector3(rng.randf_range(0.8, 2.2), 0.5, rng.randf_range(0.8, 2.2)), Basis(Vector3.UP, rng.randf() * TAU))
	for i in 26:
		var p := _ground_spot(true)
		_decal(["crack_a", "crack_b", "crack_c"][i % 3], p, Vector3(rng.randf_range(1.5, 3.0), 0.5, rng.randf_range(1.5, 3.0)), Basis(Vector3.UP, rng.randf() * TAU), &"", ["crack_a_normal", "crack_b_normal", "crack_c_normal"][i % 3])
	for i in 24:
		var p := _ground_spot(false)
		_decal(["stain_damp", "stain_food", "stain_rust", "crack_b"][i % 4], p, Vector3(rng.randf_range(0.6, 1.4), 0.4, rng.randf_range(0.6, 1.4)), Basis(Vector3.UP, rng.randf() * TAU))
	for i in 10:
		var p := _ground_spot(true)
		_decal("tire_marks", p, Vector3(1.6, 0.4, rng.randf_range(3.0, 5.0)), Basis(Vector3.UP, rng.randf_range(-0.2, 0.2) + (0.0 if i % 2 == 0 else PI * 0.5)))
	# leaves under trees
	for n in grp("Nature").get_children():
		var r := float(n.get_meta(&"canopy_radius", 3.0)) * 0.6
		for k in 2:
			var off := Vector3(rng.randf_range(-r, r), 0, rng.randf_range(-r, r))
			_decal(["leaves_a", "leaves_b"][k], (n as Node3D).position + off, Vector3(r, 0.6, r), Basis(Vector3.UP, rng.randf() * TAU), &"", ["leaves_a_normal", "leaves_b_normal"][k])
	# puddles: only visible when wet (WeatherSystem fades them in)
	for i in 70:
		var on_road := rng.randf() < 0.6
		var p := _ground_spot(on_road)
		_decal(["puddle_a", "puddle_b"][i % 2], p, Vector3(rng.randf_range(0.8, 2.6), 0.3, rng.randf_range(0.8, 2.0)), Basis(Vector3.UP, rng.randf() * TAU), &"puddle_decal")
	for i in 16:
		var p := Vector3(rng.randf_range(-90.5, -89.5), 0.0, rng.randf_range(-55, 50))
		_decal(["puddle_a", "puddle_b"][i % 2], p, Vector3(0.9, 0.3, rng.randf_range(1.0, 2.2)), Basis(Vector3.UP, rng.randf_range(-0.2, 0.2)), &"puddle_decal")
	# chalk drawings: hẻm A and the lake promenade
	_decal("chalk_hopscotch", Vector3(-90.0, 0.0, 22.0), Vector3(1.9, 0.4, 1.9), Basis(Vector3.UP, PI * 0.5))
	var pq := _ell(PI * 0.5) + Vector2(0, 2.5)
	_decal("chalk_hopscotch", Vector3(pq.x, 0.01, pq.y), Vector3(2.4, 0.4, 2.4), Basis(Vector3.UP, 0.2))
	# posters on facades
	var posters := ["poster_rent", "poster_lost_cat", "poster_festival", "poster_lessons"]
	var k := 0
	for m: Dictionary in placed:
		if rng.randf() > 0.12:
			continue
		var xf: Transform3D = m["xf"]
		var basis: Basis = xf.basis
		var x := rng.randf_range(-float(m["w"]) * 0.35, float(m["w"]) * 0.35)
		var pos := xf.origin + basis.x * x + basis.z * 0.12 + Vector3(0, rng.randf_range(1.5, 2.1), 0)
		var db := basis * Basis(Vector3.RIGHT, PI * 0.5) * Basis(Vector3.UP, rng.randf_range(-0.06, 0.06))
		_decal(posters[k % posters.size()], pos, Vector3(0.48, 0.5, 0.66), db)
		k += 1
	report["counts"]["decals"] = grp("Decals").get_child_count()


# =================================================================================================
# markers: PlayerSpawn, locations, npc spawns, patrol/traffic paths, POIs, quest targets
# =================================================================================================

var cam_nap_pos := Vector3.ZERO


func _marker(name: String, pos: Vector3, group: StringName, meta: Dictionary, yaw: float = 0.0, parent: Node3D = null) -> Marker3D:
	var m := Marker3D.new()
	m.name = name
	m.position = pos
	m.rotation.y = yaw
	if group != &"":
		m.add_to_group(group)
	for k: String in meta:
		m.set_meta(StringName(k), meta[k])
	(parent if parent != null else grp("Markers")).add_child(m)
	return m


func module_world_points(m: Dictionary, key: String) -> Array:
	var out: Array = []
	var xf: Transform3D = m["xf"]
	for p: Variant in (m["entry"] as Dictionary).get(key, []):
		if p is Array and (p as Array).size() >= 3:
			out.append(xf * Vector3(float(p[0]), float(p[1]), float(p[2])))
	return out


## Highest catalog nap spot on the module nearest `near` (rooftop of Cam's home building).
func _rooftop_nap_near(near: Vector3, rows: Array) -> Vector3:
	var best := Vector3.INF
	var best_d := INF
	for m: Dictionary in placed:
		if not str(m["row"]) in rows:
			continue
		var o: Vector3 = (m["xf"] as Transform3D).origin
		var d := Vector2(o.x - near.x, o.z - near.z).length()
		if d > 12.0:
			continue
		for p: Vector3 in module_world_points(m, "nap_spots"):
			if p.y < 5.0:
				continue
			var score := d - p.y * 0.05
			if score < best_d:
				best_d = score
				best = p
	return best


func _build_markers() -> void:
	var mk := grp("Markers")
	# --- player spawn: Cam's rooftop nap spot above the tea stall ---
	cam_nap_pos = _rooftop_nap_near(Vector3(-84.0, 0, -58.0), ["main_south_w"])
	if cam_nap_pos == Vector3.INF:
		cam_nap_pos = Vector3(-84.0, 10.0, -58.0)
		report["warnings"].append("no rooftop nap spot near the tea stall; spawn fallback")
	_marker("PlayerSpawn", cam_nap_pos + Vector3(0, 0.05, 0), &"player_spawn", {"spot_id": "cam_rooftop"}, PI)
	# --- locations ---
	for l: Array in L.LOCATIONS:
		var pos := Vector3(float(l[2]), float(l[3]), float(l[4]))
		if l[0] == "water_tower" and water_tower != null:
			pos = water_tower.position + Vector3(0, float(water_tower.get_meta(&"catwalk_y", 13.6)) + 0.1, 3.5)
		if l[0] == "temple_roof":
			pos = hall_roof_pos()
		elif l[0] == "riddle_bell":
			pos = lm_point(temple_hall, "MARKER_bell", pos)
		elif l[0] == "tea_stall":
			pos = lm_point(tea_stall, "MARKER_tea_stall", pos)
		elif l[0] == "cafe_bong":
			pos = lm_point(cafe, "MARKER_cafe", pos)
		elif l[0] == "riddle_bridge":
			pos = lm_point(bridge, "MARKER_riddle_bridge", pos)
		elif l[0] == "islet_shrine":
			pos = lm_point(islet, "MARKER_islet_shrine", pos)
		elif l[0] == "cho_hang_may":
			pos = lm_point(market_hall, "MARKER_market_hall", pos)
		elif l[0] == "dinh_hang_may":
			pos = lm_point(temple_hall, "MARKER_burner", pos)
		_marker("Loc_" + str(l[0]), pos, &"location", {"location_id": str(l[0]), "display_name_key": str(l[1]), "radius": float(l[5])})
	# --- npc spawns ---
	var npcs := [
		["ba_tu", "vendor", lm_point(tea_stall, "MARKER_grandma", Vector3(-87.4, 0, -63.6)), PI],
		["mun", "cat", cam_nap_pos + Vector3(14.0, 0.0, 0.0), 0.0],
		["bong", "cat", lm_point(cafe, "MARKER_bong_spot", Vector3(57.6, 0, -62.4)), PI],
		["muop", "cat", _temple_nap(9, Vector3(3.0, 0.76, 97.4)), PI],
		["lao_qua", "crow", lake_banyan.position + Vector3(0, 4.8, 0) if lake_banyan != null else Vector3(14, 4, 2), 0.0],
		["ven", "dog", Vector3(84.0, 0, -8.0), 0.0],
		["co_hoa", "vendor", lm_point(market_hall, "MARKER_fish_stall", Vector3(62.0, 0, L.FISH_LANE_Z - 4.4)), PI * 0.5],
		["chu_sau", "vendor", Vector3(18.0, 0, -76.1), 0.0],
		["bin", "pedestrian", Vector3(-89.8, 0, 18.0), PI * 0.5],
		["xam", "pigeon_flock", lm_point(islet, "MARKER_pigeons", Vector3(-2.0, 0.0, -27.5)), 0.0],
	]
	for n: Array in npcs:
		var meta := {"npc_kind": str(n[1]), "npc_id": str(n[0])}
		if n[0] == "muop":
			meta["dialogue_id"] = "ong_muop"
		if n[0] == "xam":
			meta["count"] = 9
			meta["radius"] = 2.5
		_marker("NPC_" + str(n[0]), n[2], &"npc_spawn", meta, n[3])
	# generic spawns: pedestrians, pigeons, koi, mice, cats, crows
	var generic := [
		["pedestrian", 26], ["pigeon_flock", 5], ["koi", 6], ["mouse", 6], ["cat", 4], ["crow", 3],
	]
	for g: Array in generic:
		for i in int(g[1]):
			var pos := _generic_spawn(str(g[0]), i)
			var gm := {"npc_kind": str(g[0]), "npc_id": ""}
			match str(g[0]):
				"koi":
					gm["volume_size"] = Vector3(9.0, 1.0, 9.0)
					gm["count"] = 5
				"crow":
					gm["snap_to_surface"] = true
				"pigeon_flock":
					gm["count"] = 8
					gm["radius"] = 3.0
				"mouse":
					gm["day_active"] = false
				"cat":
					gm["roam_radius"] = 10.0
			_marker("Spawn_%s_%02d" % [g[0], i], pos, &"npc_spawn", gm, rng.randf() * TAU)
	# --- Vện's patrol through the market ---
	var patrol := Path3D.new()
	patrol.name = "Patrol_ven"
	patrol.add_to_group(&"patrol_path")
	patrol.set_meta(&"npc_id", "ven")
	var curve := Curve3D.new()
	for p: Vector3 in [Vector3(84, 0, -8), Vector3(96, 0, -10), Vector3(96, 0, -44), Vector3(86, 0, -44), Vector3(86, 0, -10),
			Vector3(106, 0, -8), Vector3(106, 0, 8), Vector3(75, 0, 8), Vector3(75, 0, -6), Vector3(84, 0, -8)]:
		curve.add_point(p)
	patrol.curve = curve
	mk.add_child(patrol)
	# Mun's rooftop patrol (north row roofs) is generated after rooftop measurement (post_physics).
	# --- traffic lanes (one per direction per street) ---
	for s: Array in L.STREETS:
		var axis: String = s[1]
		var c: float = s[2]
		var hw := float(s[5]) * 0.5
		for dir: float in [-1, 1]:
			var lane := Path3D.new()
			lane.name = "Lane_%s_%s" % [s[0], "a" if dir > 0 else "b"]
			lane.add_to_group(&"traffic_lane")
			lane.set_meta(&"vehicle_kinds", PackedStringArray(s[8]))
			lane.set_meta(&"speed_limit", float(s[7]))
			lane.set_meta(&"street_id", str(s[0]))
			var lc := Curve3D.new()
			var off := c + dir * hw * 0.45 * (1 if axis == "x" else -1)
			var a0 := float(s[3]) + 4.0
			var a1 := float(s[4]) - 4.0
			var pts: Array[Vector3] = []
			var n := int((a1 - a0) / 10.0)
			for i in n + 1:
				var t := a0 + (a1 - a0) * float(i) / n
				pts.append(Vector3(t, ROAD_Y + 0.02, off) if axis == "x" else Vector3(off, ROAD_Y + 0.02, t))
			if dir < 0:
				pts.reverse()
			for p in pts:
				lc.add_point(p)
			lane.curve = lc
			mk.add_child(lane)
	# --- pedestrian points of interest ---
	var pois := [
		["sit", Vector3(-87.4, 0, -62.2)], ["sit", Vector3(-86.7, 0, -62.0)], ["shop", Vector3(18.0, 0, -74.4)],
		["chat", Vector3(-30.0, 0, -75.5)], ["wait", Vector3(-55.0, 0, -64.5)], ["look", Vector3(0.0, 0, -26.5)],
		["sit", Vector3(58.6, 0, -64.6)], ["sit", Vector3(59.7, 0, -64.6)], ["shop", Vector3(70.0, 0, L.FISH_LANE_Z)],
		["shop", Vector3(85.0, 0, -20.0)], ["shop", Vector3(76.0, 0, -32.0)], ["chat", Vector3(92.0, 0, L.FISH_LANE_Z)],
		["look", Vector3(30.5, 0, 2.0)], ["look", Vector3(0.0, 0, 76.0)], ["chat", Vector3(-20.0, 0, 67.0)],
		["wait", Vector3(48.0, 0, 64.5)], ["look", Vector3(-35.0, 0, 30.0)], ["sit", Vector3(-30.0, 0, -32.0)],
		["chat", Vector3(-90.0, 0, -30.0)], ["look", Vector3(10.0, 0, 76.5)],
	]
	for i in pois.size():
		_marker("POI_%02d_%s" % [i, pois[i][0]], pois[i][1], &"pedestrian_poi", {"activity": str(pois[i][0])})
	# --- quest targets (ids not already provided by interactables / kit QUEST_* markers) ---
	var hall_roof := hall_roof_pos()
	var qts := [
		["tea_stall", lm_point(tea_stall, "MARKER_tea_stall", Vector3(-86.8, 0.0, -65.0))],
		["temple_roof", hall_roof],
		["water_tower", water_tower.position + Vector3(0, float(water_tower.get_meta(&"catwalk_y", 13.6)) + 0.1, 3.5) if water_tower != null else Vector3(-112, 14, -30)],
		["race_finish", hall_roof + Vector3(-6.0, 0, 0)],
		["banyan", lake_banyan.position + Vector3(0, 0.1, 2.2) if lake_banyan != null else Vector3(-14, 0, 44)],
		["cafe", lm_point(cafe, "MARKER_cafe", Vector3(57.6, 0.0, -62.0))],
		["market", lm_point(market_hall, "MARKER_market_hall", Vector3(72.0, 0, -25.0))],
		["fish_street", Vector3(88.0, 0.0, L.FISH_LANE_Z)],
		["islet_shrine", lm_point(islet, "MARKER_islet_shrine", Vector3(L.ISLET_CENTER.x, 0.05, L.ISLET_CENTER.y))],
		["bell", lm_point(temple_hall, "MARKER_bell", Vector3(L.BELL_PAVILION.x, 0.25, L.BELL_PAVILION.y))],
	]
	if not _lm_entries.has(temple_hall):
		qts.append(["crow_nest", hall_roof + Vector3(5.0, 0.2, 0.0)])
	if not _lm_entries.has(market_hall):
		qts.append(["fish_stall", Vector3(62.0, 0.85, L.FISH_LANE_Z - 3.2)])
	for q: Array in qts:
		_marker("QT_" + str(q[0]), q[1], &"quest_target", {"target_id": str(q[0])})


## Nap spot `idx` of the temple kit in world space (fallback when the kit is missing).
func _temple_nap(idx: int, fallback: Vector3) -> Vector3:
	var pts := lm_points(temple_hall, "nap_spots")
	return pts[idx] if pts.size() > idx else fallback


func _generic_spawn(kind: String, i: int) -> Vector3:
	match kind:
		"pedestrian":
			return _ground_spot(false)
		"pigeon_flock":
			return [Vector3(0, 0, -28), Vector3(0, 0, 74), Vector3(-30, 0, 30), Vector3(84, 0, -1), Vector3(-60, 0, -72)][i % 5]
		"koi":
			var q := _ell(TAU * (i + 0.3) / 6.0, 0.55)
			return Vector3(q.x, L.LAKE_WATER_Y, q.y)
		"mouse":
			return [Vector3(-90.2, 0, -40), Vector3(-110, 0, -12), Vector3(-90.4, 0, 30), Vector3(70, 0, 6.0), Vector3(96, 0, -44), Vector3(-108, 0, -40)][i % 6]
		"cat":
			return [Vector3(-90, 0, 0), Vector3(-40, 0, -64.5), Vector3(100, 0, 67.5), Vector3(-25, 0, 90)][i % 4]
		"crow":
			var tb := temple_banyan.position if temple_banyan != null else Vector3(7.5, 0, 78.8)
			return [hall_roof_pos() + Vector3(-5.0, 2.0, 0.0), tb + Vector3(0.5, 7.0, 0.5), Vector3(-30.0, 14.0, -82.0)][i % 3]
	return Vector3.ZERO


# =================================================================================================
# interactables (systems classes): naps, territory, memories, caps, food, scratch, knockables
# =================================================================================================

func _ia(script_path: String, name: String, pos: Vector3, props: Dictionary, parent: Node3D = null) -> Node3D:
	if not ResourceLoader.exists(script_path):
		return null
	var n := Area3D.new()
	n.set_script(load(script_path))
	n.name = name
	n.position = pos
	for k: String in props:
		n.set(StringName(k), props[k])
	(parent if parent != null else grp("Interactables")).add_child(n)
	return n


## Deterministic Fisher–Yates shuffle with the builder's seeded rng (Array.shuffle() is unseeded).
func _shuffle(a: Array) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var t: Variant = a[i]
		a[i] = a[j]
		a[j] = t


func _roof_points(rows: Array, min_y: float = 5.0) -> Array:
	var out: Array = []
	for m: Dictionary in placed:
		if not rows.is_empty() and not str(m["row"]) in rows:
			continue
		for p: Vector3 in module_world_points(m, "nap_spots"):
			if p.y >= min_y:
				out.append(p)
	return out


func _build_interactables() -> void:
	var S := "res://scripts/systems/"
	# ---- nap spots (8) ----
	var naps := [
		["cam_rooftop", cam_nap_pos, {"sleep_hours": 2.0, "comfort": 1.2}],
		["tea_stall_cushion", lm_point(tea_stall, "MARKER_cam_bed", Vector3(-87.4, 0.17, -64.3)), {"sleep_hours": 2.0, "comfort": 1.4, "warmth_bonus": 10.0}],
		["temple_veranda", _temple_nap(11, Vector3(6.0, 0.76, 92.0)), {"sleep_hours": 3.0}],
		["banyan_roots", lake_banyan.position + Vector3(1.6, 0.05, 1.4) if lake_banyan != null else Vector3(-12, 0.05, 44), {"sleep_hours": 2.0, "sheltered": true}],
		["market_rice_sacks", _lm_nap(market_hall, 9, Vector3(66.0, 0.85, -40.0)), {"sleep_hours": 2.0, "sheltered": true}],
		["cafe_window", lm_point(cafe, "MARKER_bong_spot", Vector3(59.6, 0.05, -65.4)), {"sleep_hours": 1.5, "comfort": 1.3}],
		["muop_secret_nap", _temple_nap(10, Vector3(L.BELL_PAVILION.x, 3.6, L.BELL_PAVILION.y)), {"sleep_hours": 3.0, "comfort": 1.6, "sheltered": true}],
	]
	var roof_naps := _roof_points(["hem_a_w_n", "hem_a_e_s", "pho_ho_w", "main_north"], 6.0)
	if not roof_naps.is_empty():
		naps.append(["sunny_rooftop", roof_naps[rng.randi_range(0, roof_naps.size() - 1)], {"sleep_hours": 2.0, "sheltered": false}])
	for n: Array in naps:
		var props: Dictionary = n[2]
		props["spot_id"] = StringName(n[0])
		_ia(S + "nap_spot.gd", "Nap_" + str(n[0]), n[1], props)
	# ---- territory spots (10) ----
	var terr: Array = []
	var roof_all := _roof_points(["main_south_w", "main_north", "hem_a_w_n", "hem_a_w_s", "hem_a_e_n", "hem_a_e_s", "pho_ho_w", "dinh_north_w"], 6.0)
	_shuffle(roof_all)
	for i in mini(5, roof_all.size()):
		terr.append(["roof_%02d" % (i + 1), roof_all[i]])
	terr.append(["alley_corner", Vector3(-90.0, 0.0, -5.0)])
	terr.append(["tower_base", Vector3(L.WATER_TOWER_POS.x + 2.8, 0.0, L.WATER_TOWER_POS.y)])
	terr.append(["temple_wall", Vector3(-34.0, 2.35, 80.0)])
	terr.append(["market_crates", Vector3(101.5, 0.0, -44.0)])
	terr.append(["lake_bench", Vector3(_ell(1.0).x + 3.0, 0.0, _ell(1.0).y + 3.0)])
	for t: Array in terr:
		_ia(S + "territory_spot.gd", "Territory_" + str(t[0]), t[1], {"spot_id": StringName(t[0]), "faction": &"rooftop_cats"})
	report["counts"]["territory_spots"] = terr.size()
	# ---- memories (12 old photographs) ----
	var mem_spots := [
		lm_point(tea_stall, "MARKER_cam_bed", Vector3(-87.9, 0.13, -64.4)) + Vector3(0.25, 0.0, 0.0), Vector3(-112.0, 0.05, -30.5),
		Vector3(-90.3, 0.05, 35.0), _temple_nap(4, Vector3(-4.0, 0.8, 85.0)),
		_lm_nap(islet, 0, Vector3(L.ISLET_CENTER.x + 2.5, 0.75, L.ISLET_CENTER.y + 2.5)), Vector3(-30.0, 0.05, 72.5),
		_lm_nap(market_hall, 1, Vector3(76.0, 0.83, -37.0)),
		Vector3(112.0, 0.05, 36.0), Vector3(30.0, 0.05, -47.0), Vector3(-58.8, 0.05, -10.0), Vector3(118.0, 0.05, -46.0),
	]
	if not roof_naps.is_empty():
		mem_spots.append(roof_naps[roof_naps.size() / 2])
	else:
		mem_spots.append(Vector3(-100.0, 0.05, 0.0))
	for i in mem_spots.size():
		var id := "memory_%02d" % (i + 1)
		_ia(S + "collectible.gd", "Memory_%02d" % (i + 1), mem_spots[i], {"collectible_id": StringName(id), "kind": &"memory"})
	# ---- bottle caps (30 stashes) ----
	var caps: Array = []
	for i in 18:
		caps.append(_ground_spot(false) + Vector3(0, 0.03, 0))
	var roofs := _roof_points([], 5.0)
	_shuffle(roofs)
	for i in mini(8, roofs.size()):
		caps.append(roofs[i] + Vector3(0.3, 0.02, 0.2))
	for p: Vector3 in [Vector3(-90.0, 0.03, -50.0), Vector3(-105.0, 0.03, -5.0), Vector3(84.0, 0.03, 0.5), Vector3(-12.0, 0.03, 74.0)]:
		caps.append(p)
	while caps.size() < 30:
		caps.append(_ground_spot(false) + Vector3(0, 0.03, 0))
	for i in caps.size():
		_ia(S + "collectible.gd", "Caps_%02d" % i, caps[i], {"collectible_id": StringName("caps_%02d" % i), "kind": &"caps",
			"amount": 1 + (i % 3), "auto_collect_on_touch": true})
	report["counts"]["cap_stashes"] = caps.size()
	# ---- food & water ----
	_ia(S + "food_source.gd", "Food_GrandmaBowl", lm_point(tea_stall, "MARKER_bowl", Vector3(-86.6, 0.02, -63.4)), {"source_id": &"grandma_bowl", "food_amount": 40.0, "servings": 2, "refill_hours": 8.0, "owner_npc_id": &"ba_tu"})
	_ia(S + "food_source.gd", "Food_FishStall", lm_point(market_hall, "QUEST_fish_stall", Vector3(62.0, 0.85, L.FISH_LANE_Z - 3.2)), {"source_id": &"fish_stall", "gives_item": &"fish", "is_stealing": true, "owner_npc_id": &"co_hoa", "food_amount": 30.0})
	_ia(S + "food_source.gd", "Food_BanhMi", Vector3(18.0, 0.02, -74.6), {"source_id": &"banh_mi_crumbs", "food_amount": 15.0, "servings": 3, "refill_hours": 6.0, "owner_npc_id": &"chu_sau"})
	var lake_drink := lm_point(lake_steps[0], "MARKER_water_access", _lake_step_pos(-0.9)) if not lake_steps.is_empty() else _lake_step_pos(-0.9)
	_ia(S + "food_source.gd", "Water_Lake", lake_drink, {"source_id": &"lake_water", "is_water": true, "food_amount": 0.0, "servings": 99, "verb": &"drink"})
	_ia(S + "food_source.gd", "Water_TempleBasin", Vector3(-8.0, 0.0, 77.0), {"source_id": &"temple_basin", "is_water": true, "food_amount": 0.0, "servings": 99, "verb": &"drink"})
	_ia(S + "food_source.gd", "Food_MarketScraps", Vector3(98.0, 0.02, -46.5), {"source_id": &"market_scraps", "food_amount": 20.0, "servings": 2, "refill_hours": 12.0})
	# ---- scratch posts ----
	if temple_banyan != null:
		_ia(S + "scratch_post.gd", "Scratch_TempleBanyan", temple_banyan.position + Vector3(0, 0.3, 1.25), {"post_id": &"temple_banyan", "marks_territory": true})
	if lake_banyan != null:
		_ia(S + "scratch_post.gd", "Scratch_LakeBanyan", lake_banyan.position + Vector3(0, 0.3, 1.25), {"post_id": &"lake_banyan"})
	_ia(S + "scratch_post.gd", "Scratch_CafeChair", _lm_nap(cafe, 1, Vector3(58.5, 0.6, -64.6)) - Vector3(0, 0.45, 0), {"post_id": &"cafe_rattan"})
	_ia(S + "scratch_post.gd", "Scratch_StallLeg", tea_stall.transform * Vector3(1.9, 0.15, -0.3) if tea_stall != null else Vector3(-86.8, 0.15, -64.1), {"post_id": &"tea_stall_leg"})
	# ---- story interactables ----
	_ia(S + "interactable.gd", "Sniff_StallCounter", lm_point(tea_stall, "MARKER_stall_counter", Vector3(-87.4, 0.1, -64.3)) + Vector3(0, 0.6, 0), {"verb": &"sniff", "target_id": &"stall_counter", "interact_distance": 1.4})
	var nest := lm_point(temple_hall, "QUEST_crow_nest", hall_roof_pos() + Vector3(5.0, 0.2, 0.0))
	if not _lm_entries.has(temple_hall):
		var nest_node := Node3D.new()
		nest_node.name = "CrowNest"
		nest_node.position = nest
		grp("Landmarks").add_child(nest_node)
		_crow_nest_visual(nest_node)
	var fest := {"quest": "main_05_festival_night", "state": "active"}
	_ia(S + "pickup_item.gd", "Pickup_Figurine", nest + Vector3(0, 0.12, 0), {"item_id": &"lucky_cat_figurine", "requirement": fest, "show_when_locked": false, "target_id": &"crow_nest"})
	_ia(S + "pickup_item.gd", "Pickup_HairClip", nest + Vector3(0.25, 0.1, 0.15), {"item_id": &"hair_clip", "requirement": fest, "show_when_locked": false})
	_ia(S + "pickup_item.gd", "Pickup_BinsKey", Vector3(-104.5, 0.05, -10.0), {"item_id": &"key", "target_id": &"bins_key_spot"})
	_ia(S + "pickup_item.gd", "Pickup_LegBand", Vector3(10.5, 0.6, 74.0), {"item_id": &"leg_band", "target_id": &"leg_band_spot"}).set_meta(&"snap_from", 0.8)
	_ia(S + "pickup_item.gd", "Pickup_Letter", Vector3(34.6, 0.05, -76.0), {"item_id": &"letter", "target_id": &"postman_bag"})
	_ia(S + "quest_trigger.gd", "Trigger_RaceStart", cam_nap_pos + Vector3(6.0, 0.0, 0.0), {"event": &"reach_location", "location_id": &"race_start", "target_id": &"race_start", "discover_location": false})
	_ia(S + "quest_trigger.gd", "Trigger_TempleRoof", hall_roof_pos(), {"event": &"reach_location", "location_id": &"temple_roof", "box_size": Vector3(10.0, 3.0, 4.0)})
	# ---- knockable objects (~25) ----
	_build_knockables()


## World nap spot `idx` of a landmark (fallback when missing).
func _lm_nap(n: Node3D, idx: int, fallback: Vector3) -> Vector3:
	var pts := lm_points(n, "nap_spots")
	return pts[idx] if pts.size() > idx else fallback


func hall_roof_pos() -> Vector3:
	if _lm_entries.has(temple_hall):
		return lm_point(temple_hall, "MARKER_temple_roof", Vector3(0, 9.3, 97.75)) + Vector3(0, 0.15, 0)
	if temple_hall != null:
		return temple_hall.position + Vector3(0, float(temple_hall.get_meta(&"roof_ridge_y", 9.7)) + 0.5, 0)
	return Vector3(0, 10, 90)


func _lake_step_pos(t: float) -> Vector3:
	var p := _ell(t)
	var inward := (L.LAKE_CENTER - p).normalized()
	var q := p + inward * 1.25
	return Vector3(q.x, -0.36, q.y)


func _crow_nest_visual(parent: Node3D) -> void:
	var k := CS.Kit.new(parent)
	var twig := WM.flat("twigs", Color(0.32, 0.24, 0.16), 0.9)
	for i in 40:
		var a := rng.randf() * TAU
		var r := rng.randf_range(0.18, 0.32)
		var p0 := Vector3(cos(a) * r, rng.randf_range(0.0, 0.12), sin(a) * r)
		var p1 := p0 + Vector3(rng.randf_range(-0.25, 0.25), rng.randf_range(-0.03, 0.05), rng.randf_range(-0.25, 0.25))
		MU.tube(k.st(twig), PackedVector3Array([p0, p1]), PackedFloat32Array([0.008, 0.006]), 3)
	var glint := WM.flat("nest_glint", Color(0.85, 0.75, 0.4), 0.2, 1.0)
	k.box(glint, Transform3D(Basis(Vector3.UP, 0.4), Vector3(0.05, 0.06, -0.05)), Vector3(0.05, 0.005, 0.03), 1.0)
	k.box(WM.flat("foil", Color(0.8, 0.8, 0.82), 0.15, 1.0), Transform3D(Basis(Vector3.UP, 1.2), Vector3(-0.08, 0.07, 0.04)), Vector3(0.06, 0.004, 0.05), 1.0)
	k.col(&"wood", Transform3D(Basis(), Vector3(0, 0.05, 0)), Vector3(0.7, 0.12, 0.7))
	k.finish("Nest")


func _build_knockables() -> void:
	var spots: Array = []
	# Every spot is snapped onto the surface below it by the post pass (meta snap_from = ray start y).
	# tea stall counter & tables (kit-relative)
	var ts := tea_stall
	if ts != null:
		spots.append(["glass", ts.transform * Vector3(-0.9, 1.5, -1.75), "glass"])
		spots.append(["cup", ts.transform * Vector3(-0.3, 1.5, -1.8), "ceramic"])
		spots.append(["cup", ts.transform * Vector3(1.2, 1.5, -0.6), "ceramic"])
	# café terrace tables
	if cafe != null:
		spots.append(["cup", cafe.transform * Vector3(-1.6, 1.4, 1.3), "ceramic"])
		spots.append(["glass", cafe.transform * Vector3(1.6, 1.4, 1.3), "glass"])
	# market produce platforms (kit nap spots sit on them)
	var mpts := lm_points(market_hall, "nap_spots")
	for i in mini(4, mpts.size()):
		spots.append(["can", (mpts[i] as Vector3) + Vector3(0.4, 0.8, 0.0), "metal"])
	# temple garden wall coping: offering bowl & pot
	spots.append(["bowl", Vector3(-34.0, 3.4, 76.0), "ceramic"])
	spots.append(["pot", Vector3(34.0, 3.4, 84.0), "ceramic"])
	# flower pots on rooftop parapets (from module nap spots high up)
	var roofs := _roof_points(["main_south_w", "main_north", "hem_a_w_n", "hem_a_e_s", "pho_ho_w"], 6.0)
	_shuffle(roofs)
	for i in mini(10, roofs.size()):
		spots.append(["pot", roofs[i] + Vector3(-0.35, 0.0, 0.0), "ceramic"])
	# bins & bottles on the street
	for i in 4:
		spots.append(["bottle", _ground_spot(false) + Vector3(0, 0.0, 0), "glass"])
	var n := 0
	for s: Array in spots:
		var node := _knockable(str(s[0]), str(s[2]), n)
		if node == null:
			continue
		node.position = s[1]
		node.set_meta(&"snap_from", (s[1] as Vector3).y + 0.2)
		grp("Interactables").add_child(node)
		n += 1
	# household bins (catalog prop) stand in the alleys
	for p: Vector3 in [Vector3(-90.4, 0, -12.0), Vector3(-89.6, 0, 26.0), Vector3(-108.5, 0, -8.0)]:
		_prop("trash_bin_household", p, rng.randf() * TAU)
	report["counts"]["knockables"] = n


func _knockable(kind: String, material_kind: String, idx: int) -> Node3D:
	var path := "res://scenes/props/knock_%s.tscn" % kind
	if not ResourceLoader.exists(path):
		return null
	var n := (load(path) as PackedScene).instantiate() as Node3D
	n.name = "Knock_%s_%02d" % [kind, idx]
	n.set(&"object_id", StringName("knock_%s_%02d" % [kind, idx]))
	n.set(&"material_kind", StringName(material_kind))
	return n


# =================================================================================================
# zones: area ids (ambience/reverb), shelters
# =================================================================================================

func _zone(id: String, center: Vector3, size: Vector3, reverb: String = "", amount: float = 0.0, fallback: String = "") -> void:
	var a := Area3D.new()
	a.name = "Zone_" + id
	a.set_script(load("res://scripts/world/area_zone.gd"))
	a.set(&"area_id", StringName(id))
	a.set(&"fallback_area_id", StringName(fallback))
	if reverb != "":
		a.reverb_bus_enabled = true
		a.reverb_bus_name = StringName(reverb)
		a.reverb_bus_amount = amount
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	a.add_child(cs)
	a.position = center
	grp("Zones").add_child(a)


func _build_zones() -> void:
	_zone("pho_hang_may", Vector3(0, 4, -70), Vector3(250, 8, 14))
	_zone("pho_dinh", Vector3(0, 4, 62), Vector3(250, 8, 14))
	_zone("pho_ho", Vector3(-55, 4, -4), Vector3(12, 8, 118))
	_zone("pho_cho", Vector3(50, 4, -4), Vector3(12, 8, 118))
	_zone("hem_maze", Vector3(-90, 4, -4), Vector3(58, 8, 116), "Alley", 0.45)
	_zone("ho_guong", Vector3(-2, 4, 4), Vector3(92, 8, 100))
	_zone("cho_hang_may", Vector3(88, 4, -4), Vector3(62, 8, 116), "Market", 0.4)
	_zone("dinh_hang_may", Vector3(0, 6, 89.5), Vector3(68, 12, 41), "Temple", 0.35)
	_zone("mai_nha_rooftops", Vector3(0, 20, 0), Vector3(250, 16, 210), "", 0.0)
	# shelters under awnings: one per shop module (front strip, ~1.2 m deep, below 3.2 m)
	var sg := grp("Zones")
	var count := 0
	for m: Dictionary in placed:
		if str((m["entry"] as Dictionary).get("kind", "")) != "shop":
			continue
		var xf: Transform3D = m["xf"]
		var a := Area3D.new()
		a.name = "Shelter_%d" % count
		a.add_to_group(&"shelter")
		a.collision_layer = 1 << 9
		a.collision_mask = 0
		a.monitoring = false
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(float(m["w"]) - 0.2, 3.0, 1.6)
		cs.shape = bs
		a.add_child(cs)
		a.transform = Transform3D(xf.basis, xf.origin + xf.basis.z * 0.5 + Vector3(0, 1.5, 0))
		sg.add_child(a)
		count += 1
	# dry under the big banyan crowns (vehicles-nature request)
	for t: Node3D in [temple_banyan, lake_banyan]:
		if t == null:
			continue
		var a := Area3D.new()
		a.name = "Shelter_" + String(t.name)
		a.add_to_group(&"shelter")
		a.collision_layer = 1 << 9
		a.collision_mask = 0
		a.monitoring = false
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(7.0, 5.0, 7.0)
		cs.shape = bs
		a.add_child(cs)
		a.position = t.position + Vector3(0, 2.5, 0)
		sg.add_child(a)
		count += 1
	report["counts"]["shelters"] = count


# =================================================================================================
# reflection probes & occluders
# =================================================================================================

func _build_probes_and_occluders() -> void:
	var pg := grp("Probes")
	var probes := [
		["MainStreetW", Vector3(-70, 4, -70), Vector3(60, 14, 16)], ["MainStreetE", Vector3(40, 4, -70), Vector3(80, 14, 16)],
		["HemA", Vector3(-90, 4, -4), Vector3(8, 12, 110)], ["Lake", Vector3(-2, 3, 4), Vector3(90, 14, 80)],
		["Market", Vector3(80, 4, -22), Vector3(44, 10, 44)], ["Temple", Vector3(0, 5, 89), Vector3(66, 14, 40)],
		["TempleStreet", Vector3(0, 4, 62), Vector3(200, 14, 16)],
	]
	for p: Array in probes:
		var rp := ReflectionProbe.new()
		rp.name = "Probe_" + str(p[0])
		rp.position = p[1]
		rp.size = p[2]
		rp.box_projection = true
		rp.update_mode = ReflectionProbe.UPDATE_ONCE
		rp.intensity = 0.9
		rp.max_distance = 120.0
		rp.blend_distance = 3.0
		rp.enable_shadows = false
		pg.add_child(rp)
	# occluders: one box per module, inset from the facade (party walls coincide)
	var og := grp("Occluders")
	for m: Dictionary in placed:
		var xf: Transform3D = m["xf"]
		var h: float = minf(float(m["h"]) * 0.7, 9.0)
		var occ := OccluderInstance3D.new()
		var box := BoxOccluder3D.new()
		box.size = Vector3(float(m["w"]) - 0.4, h, float(m["d"]) - 2.5)
		occ.occluder = box
		occ.transform = Transform3D(xf.basis, xf.origin - xf.basis.z * (float(m["d"]) * 0.5 + 0.5) + Vector3(0, h * 0.5, 0))
		og.add_child(occ)
