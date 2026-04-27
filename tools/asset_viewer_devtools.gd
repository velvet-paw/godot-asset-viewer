## Asset Viewer DevTools loader.
## The C# AssetViewer registers its own commands with DevTools in _Ready().
## This script provides a helper to instantiate the viewer at runtime.
extends Node

const ASSET_VIEWER_SCENE := "res://ui/asset_viewer/AssetViewer.tscn"

static func open_asset_viewer(parent: Node) -> Control:
	var scene := load(ASSET_VIEWER_SCENE) as PackedScene
	if scene == null:
		push_error("AssetViewer: Failed to load scene at %s" % ASSET_VIEWER_SCENE)
		return null
	var viewer := scene.instantiate() as Control
	parent.add_child(viewer)
	return viewer
