extends SceneTree
## Diagnostic audit of all saved 3D models and scenes in the project.
## Run: godot --headless --path . --script res://tools/model_audit.gd

const Catalog := preload("res://scripts/render/asset_catalog.gd")
const Understory := preload("res://scripts/render/understory_models.gd")
const Floor := preload("res://scripts/render/forest_floor.gd")

const MODEL_EXTS := ["res", "tres", "tscn", "scn", "mesh", "glb", "gltf", "obj", "fbx", "dae"]
const SCAN_DIRS := ["res://resources", "res://scenes"]
const SKIP_SUBDIRS := ["world_cache"]

const TREE_KIND_NAMES := {
	Biomes.T_OAK: "T_OAK",
	Biomes.T_PINE: "T_PINE",
	Biomes.T_PALM: "T_PALM",
	Biomes.T_JUNGLE: "T_JUNGLE",
	Biomes.T_BUSH: "T_BUSH",
	Biomes.T_CACTUS: "T_CACTUS",
	Biomes.T_ROCK: "T_ROCK",
	Biomes.T_SNOWPINE: "T_SNOWPINE",
	Biomes.T_BIRCH: "T_BIRCH",
	Biomes.T_DEAD: "T_DEAD",
	Biomes.T_REED: "T_REED",
	Biomes.T_ACACIA: "T_ACACIA",
}

const UNDERSTORY_NAMES := [
	"FERN", "MOSS", "MUSHROOM", "HERB", "GRASS", "BUSH", "SAPLING", "PINE",
	"FLOWERS", "HIGH_GRASS", "YOUNG", "YOUNG_PINE", "MEADOW", "FORBS", "SEDGE", "STIPA", "FIREWEED"
]

const FLOOR_NAMES := [
	"LEAVES", "NEEDLES", "TWIG", "ROOTS", "LOG", "MOSS_LOG", "SNAG", "STONES",
	"STUMP", "BOULDER", "BRANCH", "ROOT_SPAN", "ROOT_SPAN_B", "ROOT_SPAN_C",
	"STONE_SINGLE", "STONES_PAIR", "LOG_BROKEN", "MOSS_LOG_BROKEN"
]

# Forms where VegetationLayer enables detail_full > 0 (reads UV2.x in shader)
const UV2_USED_UNDERSTORY := [
	Understory.FERN, Understory.HERB, Understory.FLOWERS, Understory.BUSH,
	Understory.SAPLING, Understory.PINE, Understory.YOUNG, Understory.YOUNG_PINE,
	Understory.FORBS, Understory.FIREWEED
]

var _mat_fingerprints := {} # fingerprint -> {ids = {instance_id -> Array[String]}, labels = Array[String]}
var _issues := [] # Array of Dictionaries {file, model, severity, code, detail}
var _file_summaries := [] # Array of Dictionaries per inspected 3D file
var _cur_file_stat := {}
var _totals := {
	files = 0, meshes = 0, surfaces = 0, tris = 0,
	zero_idx = 0, zero_area = 0, tiny_area = 0,
	exact_dups = 0, unused_verts = 0, below_y0_tris = 0, bottom_cap_tris = 0, trimesh_cols = 0,
}


func _initialize() -> void:
	preload("res://tools/watchdog.gd").arm(self, 60)
	_run()
	quit(0)


func _run() -> void:
	print("=== 3D ASSET DIAGNOSTIC AUDIT ===")
	var files := _collect_files()
	print("Scanned directories: ", SCAN_DIRS)
	print("Candidate files found: ", files.size())
	print("")

	for path: String in files:
		_audit_file(path)

	_print_file_summary_table()
	_print_material_summary()
	_print_issues_summary()
	print("\n=== AUDIT TOTALS ===")
	print("Files inspected: %d | Mesh instances/entries: %d | Surfaces: %d | Total tris: %d" % [
		_totals.files, _totals.meshes, _totals.surfaces, _totals.tris])
	print("Zero-idx tris: %d | Zero-area tris (<1e-10): %d | Tiny tris (<1e-6): %d | Exact dup verts: %d | Unused verts: %d" % [
		_totals.zero_idx, _totals.zero_area, _totals.tiny_area, _totals.exact_dups, _totals.unused_verts])
	print("Tris below Y=0: %d | Bottom cap tris: %d | Trimesh collisions: %d" % [
		_totals.below_y0_tris, _totals.bottom_cap_tris, _totals.trimesh_cols])


func _collect_files() -> Array[String]:
	var out: Array[String] = []
	for root_dir: String in SCAN_DIRS:
		_scan_dir(root_dir, out)
	out.sort()
	return out


func _scan_dir(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	while true:
		var item_name := dir.get_next()
		if item_name.is_empty():
			break
		if item_name.begins_with("."):
			continue
		var full := dir_path.path_join(item_name)
		if dir.current_is_dir():
			if not (item_name in SKIP_SUBDIRS):
				_scan_dir(full, out)
		else:
			if item_name.get_extension().to_lower() in MODEL_EXTS:
				out.append(full)
	dir.list_dir_end()


func _begin_file_stat(path: String, kind: String) -> void:
	_cur_file_stat = {
		path = path,
		kind = kind,
		meshes = 0,
		surfaces = 0,
		tris = 0,
		zero_idx = 0,
		zero_area = 0,
		tiny_area = 0,
		exact_dups = 0,
		unused_verts = 0,
		below_y0_tris = 0,
		bottom_cap_tris = 0,
		cols = 0,
		trimesh_cols = 0,
		non_unit_scale = 0,
		unused_attr_surfs = 0,
	}
	_file_summaries.append(_cur_file_stat)


func _audit_file(path: String) -> void:
	var res := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if res == null:
		print("[SKIP] %s (failed to load)" % path)
		return
	if res is Resource and res.get_script() == Catalog:
		_totals.files += 1
		_begin_file_stat(path, "AssetCatalog")
		_audit_catalog(path, res)
	elif res is PackedScene:
		_totals.files += 1
		_begin_file_stat(path, "PackedScene")
		_audit_scene(path, res)
	elif res is Mesh:
		_totals.files += 1
		_begin_file_stat(path, res.get_class())
		print("--- FILE: %s (Mesh: %s) ---" % [path, res.get_class()])
		_audit_mesh(path, path.get_file(), res, Transform3D.IDENTITY, null, [], {expect_uv2 = false, expect_color = false, expect_tangent = false, allow_below_y0 = false})
		print("  Collisions: none (standalone Mesh resource)")
	else:
		print("[NON-3D] %s (%s)" % [path, res.get_class()])


func _audit_catalog(path: String, cat: Resource) -> void:
	print("=================================================================")
	print("FILE: %s (AssetCatalog v%s, %d bytes)" % [path, str(cat.get("version")), FileAccess.get_size(path)])
	print("=================================================================")

	var tex_ids := {}
	var shared_tex_list: Array = cat.get("textures")
	for i in shared_tex_list.size():
		var t: Texture2D = shared_tex_list[i]
		if t != null:
			tex_ids[t.get_instance_id()] = "textures[%d]" % i
	print("Shared catalog.textures count: %d" % shared_tex_list.size())

	var tree_dict: Dictionary = cat.get("trees")
	var levels_dict: Dictionary = cat.get("levels")
	var tree_keys: Array = tree_dict.keys()
	tree_keys.sort()
	print("\n[1] catalog.trees (%d entries):" % tree_keys.size())
	var embedded_tex_refs := {}
	for id: int in tree_keys:
		var def: Dictionary = tree_dict[id]
		var kind := id % ForestModels.MODEL_STRIDE
		var variant := id / ForestModels.MODEL_STRIDE
		var label := _tree_label(kind, variant, id)
		var is_rock := kind == Biomes.T_ROCK
		var is_outcrop := is_rock and RockModels.is_outcrop(variant)
		var is_massif := is_rock and RockModels.is_massif(variant)
		var is_reed := kind == Biomes.T_REED

		for part: String in ["trunk", "crown"]:
			if not def.has(part):
				continue
			var msh: Mesh = def[part]
			var tex_key := part + "_texture"
			if def.has(tex_key) and def[tex_key] != null:
				var tex: Texture2D = def[tex_key]
				var tid := tex.get_instance_id()
				embedded_tex_refs[tid] = embedded_tex_refs.get(tid, 0) + 1
			var ctx := {
				expect_uv2 = is_reed,
				expect_color = (part == "crown") or bool(def.get("colored_bark", false)),
				expect_tangent = false,
				allow_below_y0 = is_outcrop or is_massif,
				is_crown = (part == "crown" and not is_rock and not is_reed),
				is_trunk = (part == "trunk"),
				shader_mode = "vegetation_trunk" if part == "trunk" else ("rock" if is_rock else "vegetation"),
			}
			var lod_key := "%d/%s" % [id, part]
			var lods: Array = levels_dict.get(lod_key, [])
			if lods.is_empty():
				lods = ForestModels.lod_meshes(msh)
			for li in lods.size():
				var lod_mesh: Mesh = lods[li]
				var lod_label := "%s/%s[LOD%d]" % [label, part, li]
				_audit_mesh(path, lod_label, lod_mesh, Transform3D.IDENTITY, null, [], ctx)

	print("\n  Catalog tree texture sharing: %d unique texture instances referenced across tree defs" % embedded_tex_refs.size())
	for tid: int in embedded_tex_refs:
		var in_shared: String = tex_ids.get(tid, "NOT in catalog.textures!")
		print("    tex instance %d: used %d times (%s)" % [tid, embedded_tex_refs[tid], in_shared])

	print("\n[2] catalog.grass:")
	var grass_mesh: Mesh = cat.get("grass")
	if grass_mesh != null:
		_audit_mesh(path, "grass", grass_mesh, Transform3D.IDENTITY, null, [], {
			expect_uv2 = false, expect_color = true, expect_tangent = false, allow_below_y0 = false, shader_mode = "vegetation"
		})

	var understory_list: Array = cat.get("understory")
	print("\n[3] catalog.understory (%d forms):" % understory_list.size())
	for i in understory_list.size():
		var uname: String = UNDERSTORY_NAMES[i] if i < UNDERSTORY_NAMES.size() else "UNDERSTORY_%d" % i
		var uses_uv2: bool = i in UV2_USED_UNDERSTORY
		_audit_mesh(path, "understory[%d:%s]" % [i, uname], understory_list[i], Transform3D.IDENTITY, null, [], {
			expect_uv2 = uses_uv2, expect_color = true, expect_tangent = false, allow_below_y0 = false, shader_mode = "vegetation"
		})

	var floor_list: Array = cat.get("floor_meshes")
	print("\n[4] catalog.floor_meshes (%d forms):" % floor_list.size())
	for i in floor_list.size():
		var fname: String = FLOOR_NAMES[i] if i < FLOOR_NAMES.size() else "FLOOR_%d" % i
		var allow_buried: bool = i in [Floor.STUMP, Floor.ROOT_SPAN, Floor.ROOT_SPAN_B, Floor.ROOT_SPAN_C]
		_audit_mesh(path, "floor[%d:%s]" % [i, fname], floor_list[i], Transform3D.IDENTITY, null, [], {
			expect_uv2 = false, expect_color = true, expect_tangent = false, allow_below_y0 = allow_buried, shader_mode = "vegetation"
		})

	var far_dict: Dictionary = cat.get("far_forms")
	var far_keys: Array = far_dict.keys()
	far_keys.sort()
	print("\n[5] catalog.far_forms (%d forms):" % far_keys.size())
	for k: int in far_keys:
		var flabel := ""
		var uses_uv2 := false
		if k < Floor.FIRST:
			var uname: String = UNDERSTORY_NAMES[k] if k < UNDERSTORY_NAMES.size() else "U_%d" % k
			flabel = "far_understory[%d:%s]" % [k, uname]
			uses_uv2 = k in UV2_USED_UNDERSTORY
		else:
			var fi := k - Floor.FIRST
			var fname: String = FLOOR_NAMES[fi] if fi < FLOOR_NAMES.size() else "F_%d" % fi
			flabel = "far_floor[%d:%s]" % [fi, fname]
		_audit_mesh(path, flabel, far_dict[k], Transform3D.IDENTITY, null, [], {
			expect_uv2 = uses_uv2, expect_color = true, expect_tangent = false, allow_below_y0 = false, shader_mode = "vegetation"
		})

	print("\n[6] Collisions in AssetCatalog:")
	print("  Embedded physics nodes/shapes: 0 (AssetCatalog stores Mesh/Texture2D resources only; world collisions are analytical circles/capsules in ForestObstacles/RoadObstacles).")


func _tree_label(kind: int, variant: int, id: int) -> String:
	var kname: String = TREE_KIND_NAMES.get(kind, "KIND_%d" % kind)
	if kind == Biomes.T_ROCK:
		if variant < RockModels.VARIANTS:
			return "ROCK_BOULDER_v%d(id=%d)" % [variant, id]
		elif variant < RockModels.VARIANTS + RockModels.OUTCROPS:
			return "ROCK_OUTCROP_f%d(id=%d)" % [variant - RockModels.VARIANTS, id]
		else:
			var m := variant - RockModels.VARIANTS - RockModels.OUTCROPS
			return "ROCK_MASSIF_m%d(id=%d)" % [m, id]
	if ForestModels.has_ages(kind):
		var age_str: String = ["adult", "young", "old"][ForestModels.age_of(variant)]
		return "%s_%s_v%d(id=%d)" % [kname, age_str, variant, id]
	return "%s_v%d(id=%d)" % [kname, variant, id]


func _scene_state_has_3d_geo(state: SceneState) -> bool:
	if state == null:
		return false
	for i in state.get_node_count():
		var t := state.get_node_type(i)
		if t in [&"MeshInstance3D", &"CollisionShape3D", &"MultiMeshInstance3D"]:
			return true
		for pi in state.get_node_property_count(i):
			var pn := state.get_node_property_name(i, pi)
			if pn in [&"mesh", &"shape"]:
				return true
	return false


func _audit_scene_state_only(path: String, state: SceneState) -> void:
	var scale_issues := []
	for i in state.get_node_count():
		var npath := String(state.get_node_path(i))
		for pi in state.get_node_property_count(i):
			var pn := state.get_node_property_name(i, pi)
			if pn == &"scale":
				var s: Variant = state.get_node_property_value(i, pi)
				if s is Vector3 and not (s as Vector3).is_equal_approx(Vector3.ONE):
					scale_issues.append({node = npath, cls = String(state.get_node_type(i)), scale = s})
			elif pn == &"transform":
				var xf: Variant = state.get_node_property_value(i, pi)
				if xf is Transform3D:
					var s := (xf as Transform3D).basis.get_scale()
					if not s.is_equal_approx(Vector3.ONE):
						scale_issues.append({node = npath, cls = String(state.get_node_type(i)), scale = s})
	if not scale_issues.is_empty():
		print("  Non-unit scales on nodes:")
		for si: Dictionary in scale_issues:
			print("    Node '%s' (%s): scale=%s" % [si.node, si.cls, str(si.scale)])
			_cur_file_stat.non_unit_scale += 1
			_add_issue(path, si.node, "WARN", "NON_UNIT_SCALE", "scale=%s" % str(si.scale))
	else:
		print("  Node scales: all (1, 1, 1)")
	print("  MeshInstance3D nodes: 0 (checked SceneState; UI/container scene not instantiated)")
	print("  CollisionShape3D nodes: 0")


func _audit_scene(path: String, packed: PackedScene) -> void:
	print("=================================================================")
	print("FILE: %s (PackedScene)" % path)
	print("=================================================================")
	var state := packed.get_state()
	if not _scene_state_has_3d_geo(state):
		_audit_scene_state_only(path, state)
		return

	var inst := packed.instantiate()
	if inst == null:
		print("  [ERROR] Failed to instantiate scene")
		return
	var mesh_nodes := []
	var col_nodes := []
	var scale_issues := []
	_walk_scene(inst, "", mesh_nodes, col_nodes, scale_issues)

	if not scale_issues.is_empty():
		print("  Non-unit scales on nodes:")
		for si: Dictionary in scale_issues:
			print("    Node '%s' (%s): scale=%s" % [si.node, si.cls, str(si.scale)])
			_cur_file_stat.non_unit_scale += 1
			_add_issue(path, si.node, "WARN", "NON_UNIT_SCALE", "scale=%s" % str(si.scale))
	else:
		print("  Node scales: all (1, 1, 1)")

	print("  MeshInstance3D nodes: %d" % mesh_nodes.size())
	for mn: Dictionary in mesh_nodes:
		var node: MeshInstance3D = mn.node
		var surf_overrides := []
		for s in node.mesh.get_surface_count():
			surf_overrides.append(node.get_surface_override_material(s))
		_audit_mesh(path, mn.node_path, node.mesh, node.transform, node.material_override, surf_overrides, {
			expect_uv2 = false,
			expect_color = false,
			expect_tangent = false,
			allow_below_y0 = true,
			is_scene_node = true,
			uses_skeleton = (node.get_parent() is Skeleton3D) or (node.skin != null),
			shader_mode = "standard",
		})

	print("  CollisionShape3D nodes: %d" % col_nodes.size())
	for cn: Dictionary in col_nodes:
		var col: CollisionShape3D = cn.node
		var shp: Shape3D = col.shape
		_cur_file_stat.cols += 1
		if shp == null:
			print("    %s: shape=null" % cn.node_path)
			continue
		var desc := shp.get_class()
		if shp is ConcavePolygonShape3D:
			var faces := (shp as ConcavePolygonShape3D).get_faces()
			desc += " (TRIMESH! faces=%d)" % (faces.size() / 3)
			_totals.trimesh_cols += 1
			_cur_file_stat.trimesh_cols += 1
			_add_issue(path, cn.node_path, "WARN", "TRIMESH_COLLISION", "ConcavePolygonShape3D with %d tris" % (faces.size() / 3))
		elif shp is ConvexPolygonShape3D:
			desc += " (points=%d)" % (shp as ConvexPolygonShape3D).points.size()
		elif shp is BoxShape3D:
			desc += " (size=%s)" % str((shp as BoxShape3D).size)
		elif shp is SphereShape3D:
			desc += " (r=%.3f)" % (shp as SphereShape3D).radius
		elif shp is CapsuleShape3D:
			desc += " (r=%.3f, h=%.3f)" % [(shp as CapsuleShape3D).radius, (shp as CapsuleShape3D).height]
		elif shp is CylinderShape3D:
			desc += " (r=%.3f, h=%.3f)" % [(shp as CylinderShape3D).radius, (shp as CylinderShape3D).height]
		print("    %s: %s (scale=%s)" % [cn.node_path, desc, str(col.scale)])
	inst.free()


func _walk_scene(node: Node, prefix: String, mesh_nodes: Array, col_nodes: Array, scale_issues: Array) -> void:
	var npath: String = String(node.name) if prefix.is_empty() else prefix + "/" + String(node.name)
	if node is Node3D:
		var s := (node as Node3D).scale
		if not s.is_equal_approx(Vector3.ONE):
			scale_issues.append({node = npath, cls = node.get_class(), scale = s})
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		mesh_nodes.append({node = node, node_path = npath})
	if node is CollisionShape3D:
		col_nodes.append({node = node, node_path = npath})
	for child in node.get_children():
		_walk_scene(child, npath, mesh_nodes, col_nodes, scale_issues)


func _audit_mesh(file_path: String, label: String, msh: Mesh, xform: Transform3D, mat_override: Material, surf_overrides: Array, ctx: Dictionary) -> void:
	if msh == null:
		print("  %s: <null mesh>" % label)
		return
	_totals.meshes += 1
	_cur_file_stat.meshes += 1
	var surf_count := msh.get_surface_count()
	_totals.surfaces += surf_count
	_cur_file_stat.surfaces += surf_count

	var total_tris := 0
	var total_verts := 0
	var total_zero_area := 0
	var total_tiny_area := 0
	var total_zero_idx := 0
	var total_exact_dups := 0
	var total_pos_dups := 0
	var total_unused_verts := 0
	var total_below_y0_tris := 0
	var total_verts_below_y0 := 0
	var total_bottom_caps := 0
	var min_y := INF
	var max_y := -INF

	var surf_reports: Array[String] = []
	for s in surf_count:
		var arrays := msh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: Variant = arrays[Mesh.ARRAY_NORMAL]
		var colors: Variant = arrays[Mesh.ARRAY_COLOR]
		var uv: Variant = arrays[Mesh.ARRAY_TEX_UV]
		var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]

		var is_array_mesh := msh is ArrayMesh
		var fmt: int = (msh as ArrayMesh).surface_get_format(s) if is_array_mesh else 0
		if not is_array_mesh:
			if normals != null: fmt |= Mesh.ARRAY_FORMAT_NORMAL
			if arrays[Mesh.ARRAY_TANGENT] != null: fmt |= Mesh.ARRAY_FORMAT_TANGENT
			if colors != null: fmt |= Mesh.ARRAY_FORMAT_COLOR
			if uv != null: fmt |= Mesh.ARRAY_FORMAT_TEX_UV
			if uv2 != null: fmt |= Mesh.ARRAY_FORMAT_TEX_UV2
			if arrays[Mesh.ARRAY_BONES] != null: fmt |= Mesh.ARRAY_FORMAT_BONES
			if arrays[Mesh.ARRAY_WEIGHTS] != null: fmt |= Mesh.ARRAY_FORMAT_WEIGHTS
		var has_idx := indices != null and (indices as PackedInt32Array).size() > 0
		var vcount := verts.size()
		total_verts += vcount
		var tri_count := 0
		var prim: int = msh.surface_get_primitive_type(s) if msh is ArrayMesh else Mesh.PRIMITIVE_TRIANGLES

		if prim == Mesh.PRIMITIVE_TRIANGLES:
			tri_count = (indices as PackedInt32Array).size() / 3 if has_idx else vcount / 3
		total_tris += tri_count

		var s_min_y := INF
		var is_scene_node := bool(ctx.get("is_scene_node", false))
		for v in verts:
			var p: Vector3 = xform * v if is_scene_node else v
			s_min_y = minf(s_min_y, p.y)
			min_y = minf(min_y, p.y)
			max_y = maxf(max_y, p.y)
			if p.y < -0.001:
				total_verts_below_y0 += 1

		var used_mask := PackedByteArray()
		if has_idx:
			used_mask.resize(vcount)
		var s_zero_area := 0
		var s_tiny_area := 0
		var s_zero_idx := 0
		var s_below_y0 := 0
		var s_bottom_cap := 0
		if prim == Mesh.PRIMITIVE_TRIANGLES:
			var idx_arr: PackedInt32Array = indices if has_idx else PackedInt32Array()
			for t in tri_count:
				var i0 := idx_arr[t * 3] if has_idx else t * 3
				var i1 := idx_arr[t * 3 + 1] if has_idx else t * 3 + 1
				var i2 := idx_arr[t * 3 + 2] if has_idx else t * 3 + 2
				if has_idx:
					if i0 >= 0 and i0 < vcount: used_mask[i0] = 1
					if i1 >= 0 and i1 < vcount: used_mask[i1] = 1
					if i2 >= 0 and i2 < vcount: used_mask[i2] = 1
				if i0 == i1 or i1 == i2 or i2 == i0:
					s_zero_idx += 1
					continue
				var a := verts[i0]
				var b := verts[i1]
				var c := verts[i2]
				var cross_v := (b - a).cross(c - a)
				var area := 0.5 * cross_v.length()
				if area < 1e-10:
					s_zero_area += 1
				elif area < 1e-6:
					s_tiny_area += 1
				var pa: Vector3 = xform * a if is_scene_node else a
				var pb: Vector3 = xform * b if is_scene_node else b
				var pc: Vector3 = xform * c if is_scene_node else c
				if pa.y < -0.001 and pb.y < -0.001 and pc.y < -0.001:
					s_below_y0 += 1
				if area >= 1e-8:
					var fn := cross_v.normalized()
					var downward_geo := absf(fn.y) > 0.85
					var downward_nrm := false
					if normals != null and (normals as PackedVector3Array).size() == vcount:
						var nrm_arr := normals as PackedVector3Array
						var n_avg: Vector3 = (nrm_arr[i0] + nrm_arr[i1] + nrm_arr[i2]) / 3.0
						if n_avg.y < -0.7:
							downward_nrm = true
					if (downward_nrm or (normals == null and downward_geo)) and maxf(pa.y, maxf(pb.y, pc.y)) <= maxf(s_min_y + 0.02, 0.02):
						s_bottom_cap += 1

		var s_unused := 0
		if has_idx:
			for u in used_mask:
				if u == 0:
					s_unused += 1

		var pos_seen := {}
		var exact_seen := {}
		var s_pos_dups := 0
		var s_exact_dups := 0
		var has_nrm := normals != null and (normals as PackedVector3Array).size() == vcount
		var has_col := colors != null and (colors as PackedColorArray).size() == vcount
		var has_uv := uv != null and (uv as PackedVector2Array).size() == vcount
		var has_uv2 := uv2 != null and (uv2 as PackedVector2Array).size() == vcount
		for vi in vcount:
			var vp := verts[vi]
			var pkey := Vector3i(roundi(vp.x * 10000.0), roundi(vp.y * 10000.0), roundi(vp.z * 10000.0))
			if pos_seen.has(pkey):
				s_pos_dups += 1
			else:
				pos_seen[pkey] = true
			var ekey := [pkey]
			if has_nrm:
				var n: Vector3 = (normals as PackedVector3Array)[vi]
				ekey.append(Vector3i(roundi(n.x * 1000.0), roundi(n.y * 1000.0), roundi(n.z * 1000.0)))
			if has_col:
				var cl: Color = (colors as PackedColorArray)[vi]
				ekey.append(Vector4i(roundi(cl.r * 255.0), roundi(cl.g * 255.0), roundi(cl.b * 255.0), roundi(cl.a * 255.0)))
			if has_uv:
				var u1: Vector2 = (uv as PackedVector2Array)[vi]
				ekey.append(Vector2i(roundi(u1.x * 1000.0), roundi(u1.y * 1000.0)))
			if has_uv2:
				var u2: Vector2 = (uv2 as PackedVector2Array)[vi]
				ekey.append(Vector2i(roundi(u2.x * 1000.0), roundi(u2.y * 1000.0)))
			if exact_seen.has(ekey):
				s_exact_dups += 1
			else:
				exact_seen[ekey] = true

		total_zero_area += s_zero_area
		total_tiny_area += s_tiny_area
		total_zero_idx += s_zero_idx
		total_exact_dups += s_exact_dups
		total_pos_dups += s_pos_dups
		total_unused_verts += s_unused
		total_below_y0_tris += s_below_y0
		total_bottom_caps += s_bottom_cap

		var eff_mat: Material = mat_override
		if eff_mat == null and s < surf_overrides.size() and surf_overrides[s] != null:
			eff_mat = surf_overrides[s]
		if eff_mat == null:
			eff_mat = msh.surface_get_material(s)
		var mat_status := _classify_material(eff_mat, "%s/surf%d" % [label, s])

		var attrs := []
		var unused_attrs := []
		if fmt & Mesh.ARRAY_FORMAT_NORMAL:
			attrs.append("NRM")
		if fmt & Mesh.ARRAY_FORMAT_TANGENT:
			attrs.append("TAN")
			# Note: Godot 4 always packs NORMAL+TANGENT into one octahedral stream when NORMAL is set.
			if (fmt & Mesh.ARRAY_FORMAT_NORMAL) == 0:
				var tan_used := false
				if eff_mat is StandardMaterial3D and (eff_mat as StandardMaterial3D).normal_enabled:
					tan_used = true
				elif eff_mat is ShaderMaterial:
					tan_used = bool(ctx.get("expect_tangent", false))
				if not tan_used:
					unused_attrs.append("TAN")
		if fmt & Mesh.ARRAY_FORMAT_COLOR:
			attrs.append("COL")
			var col_used := true
			if ctx.get("shader_mode", "") == "vegetation_trunk" and not bool(ctx.get("expect_color", false)):
				col_used = false
			elif eff_mat is StandardMaterial3D and not (eff_mat as StandardMaterial3D).vertex_color_use_as_albedo:
				col_used = false
			if not col_used:
				unused_attrs.append("COL")
		if fmt & Mesh.ARRAY_FORMAT_TEX_UV:
			attrs.append("UV")
			if eff_mat is StandardMaterial3D:
				var sm := eff_mat as StandardMaterial3D
				if sm.albedo_texture == null and sm.roughness_texture == null and sm.metallic_texture == null and sm.normal_texture == null and sm.emission_texture == null:
					unused_attrs.append("UV")
		if fmt & Mesh.ARRAY_FORMAT_TEX_UV2:
			attrs.append("UV2")
			var uv2_nonzero := false
			if has_uv2:
				for u2: Vector2 in (uv2 as PackedVector2Array):
					if u2 != Vector2.ZERO:
						uv2_nonzero = true
						break
			var uv2_used := bool(ctx.get("expect_uv2", false))
			if eff_mat is StandardMaterial3D:
				var sm := eff_mat as StandardMaterial3D
				uv2_used = sm.ao_enabled or sm.detail_enabled
			if not uv2_used:
				unused_attrs.append("UV2" + ("(all0)" if not uv2_nonzero else ""))
		if fmt & Mesh.ARRAY_FORMAT_BONES:
			attrs.append("BONES")
			if not bool(ctx.get("uses_skeleton", false)):
				unused_attrs.append("BONES")
		if fmt & Mesh.ARRAY_FORMAT_WEIGHTS:
			attrs.append("WEIGHTS")
			if not bool(ctx.get("uses_skeleton", false)):
				unused_attrs.append("WEIGHTS")
		if not has_idx:
			attrs.append("NO_INDEX")

		var s_line := "s%d: %dtri/%dv idx=%s mat=%s attrs=[%s]" % [
			s, tri_count, vcount, "Y" if has_idx else "N", mat_status, ",".join(attrs)]
		if not is_array_mesh:
			unused_attrs.clear()
		if not unused_attrs.is_empty():
			s_line += " UNUSED_ATTRS=[%s]" % ",".join(unused_attrs)
			_cur_file_stat.unused_attr_surfs += 1
			_add_issue(file_path, "%s/s%d" % [label, s], "OPT", "UNUSED_ATTRS", ",".join(unused_attrs))
		# Only flag unindexed meshes when vertices are shared (pos_dups > 0); tiny independent tris like 15v grass don't benefit from indexing.
		if not has_idx and vcount > 0 and s_pos_dups > 0:
			_add_issue(file_path, "%s/s%d" % [label, s], "WARN", "UNINDEXED", "%d verts without index buffer (pos_dups=%d)" % [vcount, s_pos_dups])
		surf_reports.append(s_line)

	_totals.tris += total_tris
	_totals.zero_idx += total_zero_idx
	_totals.zero_area += total_zero_area
	_totals.tiny_area += total_tiny_area
	_totals.exact_dups += total_exact_dups
	_totals.unused_verts += total_unused_verts
	_totals.below_y0_tris += total_below_y0_tris
	_totals.bottom_cap_tris += total_bottom_caps

	_cur_file_stat.tris += total_tris
	_cur_file_stat.zero_idx += total_zero_idx
	_cur_file_stat.zero_area += total_zero_area
	_cur_file_stat.tiny_area += total_tiny_area
	_cur_file_stat.exact_dups += total_exact_dups
	_cur_file_stat.unused_verts += total_unused_verts
	_cur_file_stat.below_y0_tris += total_below_y0_tris
	_cur_file_stat.bottom_cap_tris += total_bottom_caps

	if min_y == INF:
		min_y = 0.0
		max_y = 0.0

	var flags := []
	if surf_count > 1: flags.append("SURFACES=%d" % surf_count)
	if total_zero_idx > 0 or total_zero_area > 0:
		flags.append("DEGEN(zidx=%d,zarea=%d,tiny=%d)" % [total_zero_idx, total_zero_area, total_tiny_area])
		_add_issue(file_path, label, "BUG", "DEGEN_TRIS", "dup_idx=%d, area<1e-10=%d, area<1e-6=%d" % [total_zero_idx, total_zero_area, total_tiny_area])
	elif total_tiny_area > 0:
		flags.append("TINY_TRIS=%d(<1e-6)" % total_tiny_area)
		_add_issue(file_path, label, "INFO", "TINY_TRIS", "area<1e-6: %d (valid small geo or micro tris)" % total_tiny_area)
	if total_exact_dups > 0:
		flags.append("EXACT_DUP_V=%d" % total_exact_dups)
		_add_issue(file_path, label, "WARN", "DUP_VERTS", "%d exact duplicate verts (pos_dups=%d)" % [total_exact_dups, total_pos_dups])
	if total_unused_verts > 0:
		flags.append("UNUSED_V=%d" % total_unused_verts)
		_add_issue(file_path, label, "WARN", "UNUSED_VERTS", "%d unreferenced verts" % total_unused_verts)
	if total_below_y0_tris > 0 or total_verts_below_y0 > 0:
		flags.append("BELOW_Y0=%dtri/%dv" % [total_below_y0_tris, total_verts_below_y0])
		if not bool(ctx.get("allow_below_y0", false)):
			if bool(ctx.get("is_crown", false)) and min_y < -0.05:
				_add_issue(file_path, label, "WARN", "CROWN_BELOW_Y0", "crown clips below ground min_y=%.3f (%d verts)" % [min_y, total_verts_below_y0])
			elif not bool(ctx.get("is_crown", false)):
				_add_issue(file_path, label, "WARN", "GEOM_BELOW_Y0", "%d tris / %d verts below Y=0 (min_y=%.3f)" % [total_below_y0_tris, total_verts_below_y0, min_y])
	if total_bottom_caps > 0:
		flags.append("BOTTOM_CAP=%dtri" % total_bottom_caps)
		_add_issue(file_path, label, "OPT", "CLOSED_BOTTOM", "%d downward bottom cap tris at min_y=%.3f" % [total_bottom_caps, min_y])
	if not bool(ctx.get("is_scene_node", false)) and not bool(ctx.get("is_crown", false)) and not bool(ctx.get("allow_below_y0", false)):
		if min_y > 0.035:
			flags.append("FLOATING_MIN_Y=%.3f" % min_y)
			_add_issue(file_path, label, "WARN", "FLOATING_PIVOT", "min_y=+%.3f (floats above Y=0)" % min_y)
		elif min_y < -0.02:
			flags.append("PIVOT_MIN_Y=%.3f" % min_y)
			_add_issue(file_path, label, "WARN", "PIVOT_NOT_BOTTOM", "min_y=%.3f (expected ~0)" % min_y)

	var flag_str := (" | FLAGS: " + " ".join(flags)) if not flags.is_empty() else ""
	print("  %-30s | surf=%d tris=%5d verts=%5d | y=[%.3f..%.3f]%s" % [
		label, surf_count, total_tris, total_verts, min_y, max_y, flag_str])
	for sr: String in surf_reports:
		print("      %s" % sr)


func _classify_material(mat: Material, user_label: String) -> String:
	if mat == null:
		return "null(runtime)"
	var rp := mat.resource_path
	if not rp.is_empty() and not ("::" in rp):
		return "EXT(%s)" % rp
	var fp := _material_fingerprint(mat)
	var mid := mat.get_instance_id()
	if not _mat_fingerprints.has(fp):
		_mat_fingerprints[fp] = {ids = {}, labels = []}
	var entry: Dictionary = _mat_fingerprints[fp]
	var ids: Dictionary = entry.ids
	if not ids.has(mid):
		ids[mid] = []
	(ids[mid] as Array).append(user_label)
	(entry.labels as Array).append(user_label)
	return "EMBED(%s#%s)" % [mat.get_class(), fp.substr(0, 8)]


func _material_fingerprint(mat: Material) -> String:
	if mat is StandardMaterial3D:
		var m := mat as StandardMaterial3D
		return str([
			"StdMat", m.albedo_color, m.metallic, m.roughness, m.metallic_specular,
			m.cull_mode, m.transparency, m.vertex_color_use_as_albedo,
			m.clearcoat_enabled, m.clearcoat, m.rim_enabled, m.rim,
			m.emission_enabled, m.emission, m.emission_energy_multiplier,
			m.albedo_texture.resource_path if m.albedo_texture else ""
		]).sha256_text()
	elif mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		return str(["ShaderMat", sm.shader.resource_path if sm.shader else ""]).sha256_text()
	return str([mat.get_class(), mat.get_instance_id()]).sha256_text()


func _add_issue(file_path: String, model: String, severity: String, code: String, detail: String) -> void:
	_issues.append({file = file_path, model = model, severity = severity, code = code, detail = detail})


func _print_file_summary_table() -> void:
	print("\n=== PER-FILE SUMMARY TABLE ===")
	print("%-34s | %6s | %5s | %6s | %5s | %5s | %6s | %5s | %7s | %6s" % [
		"File", "Meshes", "Surfs", "Tris", "ZIdx", "ZArea", "TinyA", "DupV", "CapTris", "Cols"])
	print("-".repeat(108))
	for fs: Dictionary in _file_summaries:
		print("%-34s | %6d | %5d | %6d | %5d | %5d | %6d | %5d | %7d | %3d/%d" % [
			fs.path.get_file(), fs.meshes, fs.surfaces, fs.tris,
			fs.zero_idx, fs.zero_area, fs.tiny_area, fs.exact_dups,
			fs.bottom_cap_tris, fs.trimesh_cols, fs.cols])


func _print_material_summary() -> void:
	print("\n=== EMBEDDED MATERIAL SHARING & DUPLICATES SUMMARY ===")
	if _mat_fingerprints.is_empty():
		print("No embedded materials found on saved meshes.")
		return
	var dup_groups := 0
	var shared_groups := 0
	for fp: String in _mat_fingerprints:
		var entry: Dictionary = _mat_fingerprints[fp]
		var ids: Dictionary = entry.ids
		var labels: Array = entry.labels
		if ids.size() > 1:
			dup_groups += 1
			print("  [EMBED_DUP] (%s...) %d distinct Resource instances across %d surfaces: %s" % [
				fp.substr(0, 8), ids.size(), labels.size(), ", ".join(labels.slice(0, 6)) + ("..." if labels.size() > 6 else "")])
		elif labels.size() > 1:
			shared_groups += 1
			print("  [SUBRES_SHARED] (%s...) 1 shared SubResource reused across %d surfaces" % [fp.substr(0, 8), labels.size()])
	print("Total unique material signatures: %d | Shared SubResource groups: %d | True duplicate instance groups: %d" % [
		_mat_fingerprints.size(), shared_groups, dup_groups])


func _print_issues_summary() -> void:
	print("\n=== ISSUES BY CODE ===")
	var by_code := {}
	for iss: Dictionary in _issues:
		if not by_code.has(iss.code):
			by_code[iss.code] = []
		by_code[iss.code].append(iss)
	for code: String in by_code:
		var list: Array = by_code[code]
		print("  [%s] count=%d" % [code, list.size()])
		for iss: Dictionary in list.slice(0, 15):
			print("    - %s :: %s (%s)" % [iss.file.get_file(), iss.model, iss.detail])
		if list.size() > 15:
			print("    ... and %d more" % (list.size() - 15))
