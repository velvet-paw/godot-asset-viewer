# Lint shader files for compilation errors.
# Usage:
#   godot --headless -s lint_shaders.gd                    # Lint all shaders
#   godot --headless -s lint_shaders.gd -- res://path.gdshader  # Lint single shader
extends SceneTree

var _viewport: SubViewport
var _has_errors := false


func _init() -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_MINIMIZED)
	
	var args := OS.get_cmdline_user_args()
	
	if args.size() == 0:
		# Lint all shaders
		_lint_all_shaders()
	elif args.size() == 1:
		# Lint single shader
		if not _lint_shader(args[0]):
			_has_errors = true
	else:
		print("Usage: godot --headless -s lint_shaders.gd [-- path/to/shader.gdshader]")
		quit(1)
		return
	
	quit(1 if _has_errors else 0)


func _lint_all_shaders() -> void:
	print("Linting all shader files...")
	var shader_files: Array[String] = []
	_find_shaders("res://", shader_files)
	
	if shader_files.is_empty():
		print("No shader files found")
		return
	
	print("Found %d shader files" % shader_files.size())
	
	for shader_path in shader_files:
		if not _lint_shader(shader_path):
			_has_errors = true
	
	if _has_errors:
		print("Shader linting failed - see errors above")
	else:
		print("All shaders linted successfully")


func _find_shaders(path: String, result: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	
	dir.list_dir_begin()
	var file_name := dir.get_next()
	
	while file_name != "":
		var full_path := path.path_join(file_name)
		if dir.current_is_dir() and not file_name.begins_with("."):
			_find_shaders(full_path, result)
		elif file_name.ends_with(".gdshader"):
			result.append(full_path)
		file_name = dir.get_next()


func _lint_shader(shader_path: String) -> bool:
	print("Checking: %s" % shader_path)
	
	var file := FileAccess.open(shader_path, FileAccess.READ)
	if not file:
		print("  ERROR: Cannot open file")
		return false
	
	var code := file.get_as_text()
	file.close()
	
	# Parse shader type
	var shader_type := "canvas_item"
	if code.contains("shader_type spatial"):
		shader_type = "spatial"
	elif code.contains("shader_type particles"):
		shader_type = "particles"
	elif code.contains("shader_type sky"):
		shader_type = "sky"
	elif code.contains("shader_type fog"):
		shader_type = "fog"
	
	# Append dummy uniform for compilation detection
	code += "\nuniform float _lint_dummy : hint_range(0, 1);"
	
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	
	# Set up viewport and node for proper shader compilation
	var viewport := SubViewport.new()
	viewport.size = Vector2i(64, 64)
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.transparent_bg = true
	
	var node: Node
	match shader_type:
		"canvas_item":
			node = Sprite2D.new()
			var tex := Image.create(64, 64, false, Image.FORMAT_RGBA8)
			(node as Sprite2D).texture = ImageTexture.create_from_image(tex)
			(node as Sprite2D).material = material
		"spatial":
			viewport.world_3d = World3D.new()
			var camera := Camera3D.new()
			camera.current = true
			viewport.add_child(camera)
			node = MeshInstance3D.new()
			(node as MeshInstance3D).mesh = BoxMesh.new()
			(node as MeshInstance3D).material_override = material
		"particles":
			node = GPUParticles2D.new()
			(node as GPUParticles2D).process_material = material
			(node as GPUParticles2D).amount = 1
			(node as GPUParticles2D).emitting = true
		"sky":
			viewport.world_3d = World3D.new()
			var env := Environment.new()
			env.background_mode = Environment.BG_SKY
			env.sky = Sky.new()
			env.sky.sky_material = material
			viewport.environment = env
			node = Node3D.new()
		"fog":
			viewport.world_3d = World3D.new()
			var env := Environment.new()
			env.volumetric_fog_enabled = true
			viewport.environment = env
			node = Node3D.new()
		_:
			print("  ERROR: Unsupported shader type: %s" % shader_type)
			return false
	
	viewport.add_child(node)
	root.add_child(viewport)
	
	# Force render to trigger compilation
	var vp_tex := viewport.get_texture()
	vp_tex.get_image()
	
	# Check if compiled successfully via dummy uniform
	var params := RenderingServer.get_shader_parameter_list(shader.get_rid())
	var success := false
	for p in params:
		if p.name == "_lint_dummy":
			success = true
			break
	
	# Cleanup
	viewport.queue_free()
	
	if success:
		print("  OK")
		return true
	else:
		print("  FAILED - Compilation error (see errors above)")
		return false
