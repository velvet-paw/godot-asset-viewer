using Godot;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using TeaLeaves.Systems;

namespace TeaLeaves.UI
{
    public partial class AssetViewer : Control
    {
        // Node references (resolved in _Ready)
        private LineEdit _searchInput = null!;
        private OptionButton _typeFilter = null!;
        private Button _refreshButton = null!;
        private Button _importButton = null!;
        private ItemList _assetList = null!;
        private SubViewport _previewViewport = null!;
        private SubViewportContainer _viewportContainer = null!;
        private RichTextLabel _metaPanel = null!;

        // Camera control buttons
        private Button _rotateLeft = null!;
        private Button _rotateRight = null!;
        private Button _rotateUp = null!;
        private Button _rotateDown = null!;
        private Button _zoomIn = null!;
        private Button _zoomOut = null!;
        private Button _panLeft = null!;
        private Button _panRight = null!;
        private Button _panUp = null!;
        private Button _panDown = null!;
        private Button _resetCamera = null!;

        // State
        private List<AssetEntry> _allAssets = new();
        private List<AssetEntry> _filteredAssets = new();
        private AssetEntry? _currentAsset;

        // Preview nodes (created dynamically in viewport)
        private Node? _previewRoot;
        private Camera3D? _camera3D;
        private DirectionalLight3D? _light;

        // Audio preview
        private AudioStreamPlayer? _audioPlayer;

        // Camera controller
        private OrbitCamera _orbitCamera = new();

        // Mouse drag state
        private bool _isDragging;
        private bool _isPanning;
        private Vector2 _lastMousePos;

        private const float RotateStep = 15f;
        private const float ZoomStep = 0.5f;
        private const float PanStep = 0.5f;

        private static readonly string[] TextureExtensions = { ".png", ".jpg", ".jpeg", ".webp", ".svg", ".bmp", ".tga" };
        private static readonly string[] MeshExtensions = { ".glb", ".gltf", ".obj", ".fbx" };
        private static readonly string[] AudioExtensions = { ".wav", ".ogg", ".mp3" };
        private static readonly string[] ShaderExtensions = { ".gdshader" };
        private static readonly string[] SceneExtensions = { ".tscn", ".scn" };

        public override void _Ready()
        {
            _searchInput = GetNode<LineEdit>("VBox/Toolbar/SearchInput");
            _typeFilter = GetNode<OptionButton>("VBox/Toolbar/TypeFilter");
            _refreshButton = GetNode<Button>("VBox/Toolbar/RefreshButton");
            _importButton = GetNode<Button>("VBox/Toolbar/ImportButton");
            _assetList = GetNode<ItemList>("VBox/HSplit/AssetListPanel/AssetList");
            _viewportContainer = GetNode<SubViewportContainer>("VBox/HSplit/RightSplit/ViewportContainer");
            _previewViewport = GetNode<SubViewport>("VBox/HSplit/RightSplit/ViewportContainer/PreviewViewport");
            _metaPanel = GetNode<RichTextLabel>("VBox/HSplit/RightSplit/MetaPanel");

            // Camera control buttons
            var cc = "VBox/HSplit/RightSplit/CameraControls/";
            _rotateLeft = GetNode<Button>(cc + "RotateLeft");
            _rotateRight = GetNode<Button>(cc + "RotateRight");
            _rotateUp = GetNode<Button>(cc + "RotateUp");
            _rotateDown = GetNode<Button>(cc + "RotateDown");
            _zoomIn = GetNode<Button>(cc + "ZoomIn");
            _zoomOut = GetNode<Button>(cc + "ZoomOut");
            _panLeft = GetNode<Button>(cc + "PanLeft");
            _panRight = GetNode<Button>(cc + "PanRight");
            _panUp = GetNode<Button>(cc + "PanUp");
            _panDown = GetNode<Button>(cc + "PanDown");
            _resetCamera = GetNode<Button>(cc + "ResetCamera");

            _typeFilter.AddItem("All", 0);
            _typeFilter.AddItem("Textures", 1);
            _typeFilter.AddItem("Meshes", 2);
            _typeFilter.AddItem("Audio", 3);
            _typeFilter.AddItem("Materials", 4);
            _typeFilter.AddItem("Shaders", 5);
            _typeFilter.AddItem("Scenes", 6);
            _typeFilter.AddItem("Animations", 7);

            _searchInput.TextChanged += OnSearchChanged;
            _typeFilter.ItemSelected += OnTypeFilterChanged;
            _refreshButton.Pressed += OnRefreshPressed;
            _importButton.Pressed += OnImportPressed;
            _assetList.ItemSelected += OnAssetSelected;

            // Camera button signals
            _rotateLeft.Pressed += () => { _orbitCamera.Orbit(-RotateStep, 0); ApplyCameraOrbit(); };
            _rotateRight.Pressed += () => { _orbitCamera.Orbit(RotateStep, 0); ApplyCameraOrbit(); };
            _rotateUp.Pressed += () => { _orbitCamera.Orbit(0, RotateStep); ApplyCameraOrbit(); };
            _rotateDown.Pressed += () => { _orbitCamera.Orbit(0, -RotateStep); ApplyCameraOrbit(); };
            _zoomIn.Pressed += () => { _orbitCamera.Zoom(-ZoomStep * _orbitCamera.Distance * 0.2f); ApplyCameraOrbit(); };
            _zoomOut.Pressed += () => { _orbitCamera.Zoom(ZoomStep * _orbitCamera.Distance * 0.2f); ApplyCameraOrbit(); };
            _panLeft.Pressed += () => { _orbitCamera.Pan(-PanStep, 0); ApplyCameraOrbit(); };
            _panRight.Pressed += () => { _orbitCamera.Pan(PanStep, 0); ApplyCameraOrbit(); };
            _panUp.Pressed += () => { _orbitCamera.Pan(0, PanStep); ApplyCameraOrbit(); };
            _panDown.Pressed += () => { _orbitCamera.Pan(0, -PanStep); ApplyCameraOrbit(); };
            _resetCamera.Pressed += () => { _orbitCamera.Reset(); ApplyCameraOrbit(); };

            Setup3DPreview();
            RegisterDevToolsCommands();
            ScanAssets();
        }

        private void Setup3DPreview()
        {
            _previewRoot = new Node3D();
            _previewRoot.Name = "PreviewRoot";
            _previewViewport.AddChild(_previewRoot);

            _camera3D = new Camera3D();
            _camera3D.Name = "Camera3D";
            _previewViewport.AddChild(_camera3D);
            _camera3D.Position = new Vector3(0, 1, 3);
            _camera3D.LookAt(Vector3.Zero, Vector3.Up);

            _light = new DirectionalLight3D();
            _light.Name = "Light";
            _light.Rotation = new Vector3(Mathf.DegToRad(-45), Mathf.DegToRad(45), 0);
            _previewViewport.AddChild(_light);

            var env = new WorldEnvironment();
            var environment = new Godot.Environment();
            environment.BackgroundMode = Godot.Environment.BGMode.Color;
            environment.BackgroundColor = new Color(0.2f, 0.2f, 0.2f);
            environment.AmbientLightSource = Godot.Environment.AmbientSource.Color;
            environment.AmbientLightColor = Colors.White;
            environment.AmbientLightEnergy = 0.3f;
            env.Environment = environment;
            _previewViewport.AddChild(env);

            _audioPlayer = new AudioStreamPlayer();
            _audioPlayer.Name = "AudioPlayer";
            AddChild(_audioPlayer);
        }

        #region Asset Scanning

        public void ScanAssets()
        {
            _allAssets.Clear();
            ScanDirectory("res://");
            FilterAssets(_searchInput.Text, GetSelectedTypeFilter());
        }

        private void ScanDirectory(string path)
        {
            using var dir = DirAccess.Open(path);
            if (dir == null) return;

            dir.ListDirBegin();
            string fileName = dir.GetNext();
            while (fileName != "")
            {
                if (fileName.StartsWith('.'))
                {
                    fileName = dir.GetNext();
                    continue;
                }

                string fullPath = path.EndsWith("://") ? path + fileName : path.TrimEnd('/') + "/" + fileName;

                if (dir.CurrentIsDir())
                {
                    if (fileName != ".godot" && fileName != "addons" && fileName != ".import")
                    {
                        ScanDirectory(fullPath);
                    }
                }
                else
                {
                    string ext = System.IO.Path.GetExtension(fileName).ToLowerInvariant();
                    string type = ClassifyExtension(ext);
                    if (type != "unknown")
                    {
                        var entry = new AssetEntry
                        {
                            Path = fullPath,
                            Type = type,
                            TypeLabel = type.Substring(0, 1).ToUpperInvariant() + type.Substring(1),
                            SizeBytes = GetFileSize(fullPath),
                            ImportDate = GetImportDate(fullPath),
                            ImportMeta = GetImportMeta(fullPath)
                        };
                        _allAssets.Add(entry);
                    }
                }
                fileName = dir.GetNext();
            }
            dir.ListDirEnd();
        }

        private static string ClassifyExtension(string ext)
        {
            if (TextureExtensions.Contains(ext)) return "texture";
            if (MeshExtensions.Contains(ext)) return "mesh";
            if (AudioExtensions.Contains(ext)) return "audio";
            if (ShaderExtensions.Contains(ext)) return "shader";
            if (SceneExtensions.Contains(ext)) return "scene";
            if (ext == ".tres" || ext == ".res") return "resource";
            return "unknown";
        }

        private static long GetFileSize(string resPath)
        {
            string absPath = ProjectSettings.GlobalizePath(resPath);
            try
            {
                var info = new FileInfo(absPath);
                return info.Exists ? info.Length : 0;
            }
            catch
            {
                return 0;
            }
        }

        private static string GetImportDate(string resPath)
        {
            string absPath = ProjectSettings.GlobalizePath(resPath);
            try
            {
                var info = new FileInfo(absPath);
                return info.Exists ? info.LastWriteTimeUtc.ToString("yyyy-MM-dd HH:mm:ss") : "";
            }
            catch
            {
                return "";
            }
        }

        private static Dictionary<string, string> GetImportMeta(string resPath)
        {
            var meta = new Dictionary<string, string>();
            string importPath = resPath + ".import";
            string absImportPath = ProjectSettings.GlobalizePath(importPath);
            if (!File.Exists(absImportPath)) return meta;

            try
            {
                foreach (string line in File.ReadLines(absImportPath))
                {
                    string trimmed = line.Trim();
                    if (trimmed.StartsWith('[') || string.IsNullOrEmpty(trimmed)) continue;
                    int eqIdx = trimmed.IndexOf('=');
                    if (eqIdx > 0)
                    {
                        string key = trimmed.Substring(0, eqIdx).Trim();
                        string val = trimmed.Substring(eqIdx + 1).Trim().Trim('"');
                        meta[key] = val;
                    }
                }
            }
            catch
            {
                // Ignore parse errors
            }
            return meta;
        }

        #endregion

        #region Filtering

        private string GetSelectedTypeFilter()
        {
            int idx = _typeFilter.Selected;
            return idx switch
            {
                1 => "texture",
                2 => "mesh",
                3 => "audio",
                4 => "material",
                5 => "shader",
                6 => "scene",
                7 => "animation",
                _ => "all"
            };
        }

        public void FilterAssets(string search, string typeFilter)
        {
            _filteredAssets = _allAssets.Where(a =>
            {
                if (!string.IsNullOrEmpty(typeFilter) && typeFilter != "all" && a.Type != typeFilter)
                    return false;
                if (!string.IsNullOrEmpty(search) &&
                    !a.Path.Contains(search, StringComparison.OrdinalIgnoreCase))
                    return false;
                return true;
            }).OrderBy(a => a.Path).ToList();

            RefreshAssetList();
        }

        private void RefreshAssetList()
        {
            _assetList.Clear();
            foreach (var entry in _filteredAssets)
            {
                string label = $"[{entry.TypeLabel}] {entry.Path.GetFile()}";
                _assetList.AddItem(label);
            }
        }

        #endregion

        #region Signal Handlers

        private void OnSearchChanged(string newText)
        {
            FilterAssets(newText, GetSelectedTypeFilter());
        }

        private void OnTypeFilterChanged(long index)
        {
            FilterAssets(_searchInput.Text, GetSelectedTypeFilter());
        }

        private void OnRefreshPressed()
        {
            ScanAssets();
        }

        private void OnImportPressed()
        {
            ImportFromPipeline();
        }

        private void OnAssetSelected(long index)
        {
            if (index < 0 || index >= _filteredAssets.Count) return;
            var entry = _filteredAssets[(int)index];
            LoadAsset(entry.Path);
        }

        #endregion

        #region Asset Loading & Preview

        public void LoadAsset(string path)
        {
            var entry = _allAssets.FirstOrDefault(a => a.Path == path);
            if (entry == null)
            {
                entry = new AssetEntry { Path = path, Type = ClassifyExtension(System.IO.Path.GetExtension(path).ToLowerInvariant()) };
            }
            _currentAsset = entry;

            ClearPreview();

            var resource = ResourceLoader.Load(path);
            if (resource == null)
            {
                GD.PushError($"AssetViewer: Failed to load resource at {path}");
                _metaPanel.Text = $"[color=red]Failed to load: {path}[/color]";
                return;
            }

            if (resource is Texture2D tex)
            {
                ShowTexturePreview(tex);
            }
            else if (resource is PackedScene scene)
            {
                ShowScenePreview(scene);
            }
            else if (resource is Mesh mesh)
            {
                ShowMeshPreview(mesh);
            }
            else if (resource is AudioStream audio)
            {
                ShowAudioPreview(audio, path);
            }
            else if (resource is Material mat)
            {
                ShowMaterialPreview(mat);
                entry.Type = "material";
                entry.TypeLabel = "Material";
            }
            else if (resource is Animation anim)
            {
                ShowAnimationInfo(anim, path);
                entry.Type = "animation";
                entry.TypeLabel = "Animation";
            }
            else if (resource is Shader shader)
            {
                ShowShaderInfo(shader, path);
            }
            else
            {
                _metaPanel.Text = $"[b]{path}[/b]\nResource type: {resource.GetClass()}\n[i]No preview available[/i]";
                return;
            }

            UpdateMetaPanel(entry, resource);
        }

        private void ClearPreview()
        {
            if (_previewRoot == null) return;
            foreach (var child in _previewRoot.GetChildren())
            {
                child.QueueFree();
            }
            _audioPlayer?.Stop();
        }

        private void ShowTexturePreview(Texture2D tex)
        {
            if (_previewRoot == null) return;
            // Display as a 3D sprite for viewport consistency
            var sprite = new Sprite3D();
            sprite.Texture = tex;
            float maxDim = Mathf.Max(tex.GetWidth(), tex.GetHeight());
            if (maxDim > 0) sprite.PixelSize = 2f / maxDim;
            _previewRoot.AddChild(sprite);
            SetCameraOrbit(0, 0, 2.5f, Vector3.Zero);
        }

        private void ShowMeshPreview(Mesh mesh)
        {
            if (_previewRoot == null) return;
            var instance = new MeshInstance3D();
            instance.Mesh = mesh;
            _previewRoot.AddChild(instance);
            FitCameraToAabb(mesh.GetAabb());
        }

        private void ShowScenePreview(PackedScene scene)
        {
            if (_previewRoot == null) return;
            try
            {
                var instance = scene.Instantiate();
                _previewRoot.AddChild(instance);

                if (instance is Node3D node3D)
                {
                    var aabb = CalculateNode3DAabb(node3D);
                    FitCameraToAabb(aabb);
                }
                else
                {
                    SetCameraOrbit(0, -20, 3f, Vector3.Zero);
                }
            }
            catch (Exception e)
            {
                GD.PushError($"AssetViewer: Failed to instantiate scene: {e.Message}");
                _metaPanel.Text = $"[color=red]Failed to instantiate scene[/color]\n{e.Message}";
            }
        }

        private void ShowAudioPreview(AudioStream audio, string path)
        {
            if (_audioPlayer == null) return;
            _audioPlayer.Stream = audio;
            _audioPlayer.Play();
        }

        private void ShowMaterialPreview(Material mat)
        {
            if (_previewRoot == null) return;
            var sphere = new MeshInstance3D();
            var sphereMesh = new SphereMesh();
            sphereMesh.Radius = 0.5f;
            sphereMesh.Height = 1.0f;
            sphere.Mesh = sphereMesh;
            sphere.MaterialOverride = mat;
            _previewRoot.AddChild(sphere);
            SetCameraOrbit(30, -20, 2f, Vector3.Zero);
        }

        private void ShowAnimationInfo(Animation anim, string path)
        {
            // No 3D preview for animations; metadata panel shows info
        }

        private void ShowShaderInfo(Shader shader, string path)
        {
            // No 3D preview for raw shaders; metadata panel shows code snippet
        }

        private static Aabb CalculateNode3DAabb(Node3D root)
        {
            var aabb = new Aabb();
            bool first = true;

            void Collect(Node node)
            {
                if (node is VisualInstance3D vis)
                {
                    var nodeAabb = vis.GetAabb();
                    if (node is Node3D n3d)
                    {
                        nodeAabb.Position += n3d.GlobalPosition;
                    }
                    if (first) { aabb = nodeAabb; first = false; }
                    else { aabb = aabb.Merge(nodeAabb); }
                }
                foreach (var child in node.GetChildren())
                {
                    Collect(child);
                }
            }

            Collect(root);
            if (first) aabb = new Aabb(Vector3.Zero, Vector3.One);
            return aabb;
        }

        #endregion

        #region Camera Orbit

        private void SetCameraOrbit(float yaw, float pitch, float distance, Vector3 target)
        {
            _orbitCamera.SetState(yaw, pitch, distance, target);
            _orbitCamera.SaveDefaults();
            ApplyCameraOrbit();
        }

        private void FitCameraToAabb(Aabb aabb)
        {
            var center = aabb.GetCenter();
            float size = aabb.Size.Length();
            float distance = Mathf.Max(size * 1.5f, 1f);
            _orbitCamera.SetState(30f, -25f, distance, center);
            _orbitCamera.SaveDefaults();
            ApplyCameraOrbit();
        }

        private void ApplyCameraOrbit()
        {
            if (_camera3D == null) return;
            var (position, lookAt) = _orbitCamera.ComputeTransform();
            _camera3D.Position = position;
            _camera3D.LookAt(lookAt, Vector3.Up);
        }

        public override void _UnhandledInput(InputEvent @event)
        {
            if (@event is InputEventMouseButton mb)
            {
                HandleMouseButton(mb);
            }
            else if (@event is InputEventMouseMotion mm)
            {
                HandleMouseMotion(mm);
            }
            else if (@event is InputEventKey key && key.Pressed && !key.Echo)
            {
                HandleKeyInput(key);
            }
        }

        private void HandleMouseButton(InputEventMouseButton mb)
        {
            if (mb.ButtonIndex == MouseButton.Middle)
            {
                if (mb.Pressed)
                {
                    _isDragging = true;
                    _isPanning = mb.ShiftPressed;
                    _lastMousePos = mb.Position;
                }
                else
                {
                    _isDragging = false;
                    _isPanning = false;
                }
            }
            else if (mb.ButtonIndex == MouseButton.WheelUp && mb.Pressed)
            {
                _orbitCamera.Zoom(-_orbitCamera.Distance * 0.1f);
                ApplyCameraOrbit();
            }
            else if (mb.ButtonIndex == MouseButton.WheelDown && mb.Pressed)
            {
                _orbitCamera.Zoom(_orbitCamera.Distance * 0.1f);
                ApplyCameraOrbit();
            }
        }

        private void HandleMouseMotion(InputEventMouseMotion mm)
        {
            if (!_isDragging) return;

            var delta = mm.Position - _lastMousePos;
            _lastMousePos = mm.Position;

            if (_isPanning)
            {
                _orbitCamera.Pan(-delta.X * 0.01f, delta.Y * 0.01f);
            }
            else
            {
                _orbitCamera.Orbit(delta.X * 0.5f, -delta.Y * 0.5f);
            }
            ApplyCameraOrbit();
        }

        private void HandleKeyInput(InputEventKey key)
        {
            if (key.Keycode == Key.R)
            {
                _orbitCamera.Reset();
                ApplyCameraOrbit();
            }
        }

        #endregion

        #region Metadata Panel

        private void UpdateMetaPanel(AssetEntry entry, Resource? resource = null)
        {
            string sizeStr = FormatFileSize(entry.SizeBytes);
            string text = $"[b]{entry.Path.GetFile()}[/b]\n";
            text += $"Path: {entry.Path}\n";
            text += $"Type: {entry.TypeLabel}\n";
            text += $"Size: {sizeStr}\n";
            if (!string.IsNullOrEmpty(entry.ImportDate))
                text += $"Modified: {entry.ImportDate}\n";

            if (resource is Texture2D tex)
            {
                text += $"Dimensions: {tex.GetWidth()}x{tex.GetHeight()}\n";
                text += $"Format: {tex.GetClass()}\n";
            }
            else if (resource is Mesh mesh)
            {
                int totalVerts = 0;
                for (int i = 0; i < mesh.GetSurfaceCount(); i++)
                {
                    var arrays = mesh.SurfaceGetArrays(i);
                    if (arrays.Count > 0 && arrays[0].Obj is Vector3[] verts)
                    {
                        totalVerts += verts.Length;
                    }
                }
                text += $"Surfaces: {mesh.GetSurfaceCount()}\n";
                text += $"Vertices: ~{totalVerts}\n";
                var aabb = mesh.GetAabb();
                text += $"Bounds: {aabb.Size}\n";
            }
            else if (resource is AudioStream audio)
            {
                text += $"Length: {audio.GetLength():F2}s\n";
                text += $"Class: {audio.GetClass()}\n";
            }
            else if (resource is Animation anim)
            {
                text += $"Length: {anim.Length:F2}s\n";
                text += $"Tracks: {anim.GetTrackCount()}\n";
                text += $"Loop: {anim.LoopMode}\n";
            }

            if (entry.ImportMeta.Count > 0)
            {
                text += "\n[b]Import Settings:[/b]\n";
                foreach (var kv in entry.ImportMeta.Take(10))
                {
                    text += $"  {kv.Key}: {kv.Value}\n";
                }
            }

            _metaPanel.Text = text;
        }

        private static string FormatFileSize(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            return $"{bytes / (1024.0 * 1024.0):F1} MB";
        }

        #endregion

        #region Import Pipeline

        private void ImportFromPipeline()
        {
            string scriptPath = ProjectSettings.GlobalizePath("res://tools/import-asset.sh");
            if (!File.Exists(scriptPath))
            {
                GD.PushError("AssetViewer: import-asset.sh not found at " + scriptPath);
                _metaPanel.Text = "[color=red]Import script not found: tools/import-asset.sh[/color]";
                return;
            }

            try
            {
                var output = new Godot.Collections.Array();
                int exitCode = OS.Execute("bash", new string[] { scriptPath }, output, true);
                string result = string.Join("\n", output);

                if (exitCode == 0)
                {
                    _metaPanel.Text = $"[color=green]Import complete[/color]\n{result}";
                    ScanAssets();
                }
                else
                {
                    _metaPanel.Text = $"[color=red]Import failed (exit {exitCode})[/color]\n{result}";
                }
            }
            catch (Exception e)
            {
                GD.PushError($"AssetViewer: Import failed: {e.Message}");
                _metaPanel.Text = $"[color=red]Import error: {e.Message}[/color]";
            }
        }

        #endregion

        #region DevTools Commands

        private void RegisterDevToolsCommands()
        {
            var devtools = DevTools.Instance;
            if (devtools == null)
            {
                GD.PushWarning("AssetViewer: DevTools not available, commands not registered");
                return;
            }

            devtools.RegisterHandler("asset_viewer_list", CmdList);
            devtools.RegisterHandler("asset_viewer_load", CmdLoad);
            devtools.RegisterHandler("asset_viewer_screenshot", CmdScreenshot);
            devtools.RegisterHandler("asset_viewer_camera", CmdCamera);
            devtools.RegisterHandler("asset_viewer_audio", CmdAudio);
            devtools.RegisterHandler("asset_viewer_get_meta", CmdGetMeta);
            devtools.RegisterHandler("asset_viewer_validate", CmdValidate);
        }

        private CommandResult CmdList(JsonElement args)
        {
            string? typeFilter = null;
            string? search = null;

            if (args.ValueKind == JsonValueKind.Object)
            {
                if (args.TryGetProperty("type_filter", out var tfProp))
                    typeFilter = tfProp.GetString();
                else if (args.TryGetProperty("type", out var typeProp))
                    typeFilter = typeProp.GetString();
                if (args.TryGetProperty("search", out var searchProp))
                    search = searchProp.GetString();
            }

            var results = _allAssets.Where(a =>
            {
                if (!string.IsNullOrEmpty(typeFilter) && a.Type != typeFilter) return false;
                if (!string.IsNullOrEmpty(search) && !a.Path.Contains(search, StringComparison.OrdinalIgnoreCase)) return false;
                return true;
            }).Select(a => new { path = a.Path, type = a.Type, type_label = a.TypeLabel, size_bytes = a.SizeBytes }).ToList();

            return new CommandResult(true, $"Found {results.Count} assets", new { count = results.Count, assets = results });
        }

        private CommandResult CmdLoad(JsonElement args)
        {
            if (args.ValueKind != JsonValueKind.Object ||
                !args.TryGetProperty("path", out var pathProp))
            {
                return new CommandResult(false, "Missing 'path' argument");
            }

            string path = pathProp.GetString() ?? "";
            if (string.IsNullOrEmpty(path))
                return new CommandResult(false, "Empty path");

            try
            {
                LoadAsset(path);
                return new CommandResult(true, $"Loaded asset: {path}", new { path, type = _currentAsset?.Type });
            }
            catch (Exception e)
            {
                return new CommandResult(false, $"Failed to load: {e.Message}");
            }
        }

        private CommandResult CmdScreenshot(JsonElement args)
        {
            string outputPath = "user://asset_viewer_screenshot.png";

            if (args.ValueKind == JsonValueKind.Object &&
                args.TryGetProperty("output", out var outputProp))
            {
                outputPath = outputProp.GetString() ?? outputPath;
            }

            var image = _previewViewport.GetTexture().GetImage();
            if (image == null)
                return new CommandResult(false, "Failed to capture viewport");

            string absPath = ProjectSettings.GlobalizePath(outputPath);
            var error = image.SavePng(absPath);
            if (error != Error.Ok)
                return new CommandResult(false, $"Failed to save screenshot: {error}");

            return new CommandResult(true, "Screenshot saved", new { path = absPath, width = image.GetWidth(), height = image.GetHeight() });
        }

        private CommandResult CmdCamera(JsonElement args)
        {
            if (args.ValueKind != JsonValueKind.Object)
                return new CommandResult(false, "Expected object with camera parameters");

            string action = "set";
            if (args.TryGetProperty("action", out var actionProp))
                action = actionProp.GetString() ?? "set";

            switch (action)
            {
                case "orbit":
                {
                    float dy = 0, dp = 0;
                    if (args.TryGetProperty("delta_yaw", out var dyProp))
                        dy = (float)dyProp.GetDouble();
                    if (args.TryGetProperty("delta_pitch", out var dpProp))
                        dp = (float)dpProp.GetDouble();
                    _orbitCamera.Orbit(dy, dp);
                    ApplyCameraOrbit();
                    return CameraStateResult("Orbit applied");
                }
                case "zoom":
                {
                    float delta = 0;
                    if (args.TryGetProperty("delta", out var dProp))
                        delta = (float)dProp.GetDouble();
                    else if (args.TryGetProperty("delta_zoom", out var dzProp))
                        delta = (float)dzProp.GetDouble();
                    _orbitCamera.Zoom(delta);
                    ApplyCameraOrbit();
                    return CameraStateResult("Zoom applied");
                }
                case "pan":
                {
                    float dx = 0, dy = 0;
                    if (args.TryGetProperty("delta_x", out var dxProp))
                        dx = (float)dxProp.GetDouble();
                    if (args.TryGetProperty("delta_y", out var dyProp))
                        dy = (float)dyProp.GetDouble();
                    _orbitCamera.Pan(dx, dy);
                    ApplyCameraOrbit();
                    return CameraStateResult("Pan applied");
                }
                case "reset":
                {
                    _orbitCamera.Reset();
                    ApplyCameraOrbit();
                    return CameraStateResult("Camera reset");
                }
                case "get_state":
                {
                    return CameraStateResult("Camera state");
                }
                case "set":
                default:
                {
                    // Backward-compatible: set absolute values
                    if (args.TryGetProperty("yaw", out var yawProp))
                        _orbitCamera.SetState((float)yawProp.GetDouble(), _orbitCamera.Pitch, _orbitCamera.Distance, _orbitCamera.Target);
                    if (args.TryGetProperty("pitch", out var pitchProp))
                        _orbitCamera.SetState(_orbitCamera.Yaw, (float)pitchProp.GetDouble(), _orbitCamera.Distance, _orbitCamera.Target);
                    if (args.TryGetProperty("distance", out var distProp))
                        _orbitCamera.SetState(_orbitCamera.Yaw, _orbitCamera.Pitch, (float)distProp.GetDouble(), _orbitCamera.Target);
                    if (args.TryGetProperty("target", out var targetProp) && targetProp.ValueKind == JsonValueKind.Array)
                    {
                        var arr = targetProp.EnumerateArray().ToArray();
                        if (arr.Length == 3)
                        {
                            var target = new Vector3((float)arr[0].GetDouble(), (float)arr[1].GetDouble(), (float)arr[2].GetDouble());
                            _orbitCamera.SetState(_orbitCamera.Yaw, _orbitCamera.Pitch, _orbitCamera.Distance, target);
                        }
                    }
                    ApplyCameraOrbit();
                    return CameraStateResult("Camera updated");
                }
            }
        }

        private CommandResult CameraStateResult(string message)
        {
            var t = _orbitCamera.Target + _orbitCamera.PanOffset;
            return new CommandResult(true, message, new
            {
                yaw = _orbitCamera.Yaw,
                pitch = _orbitCamera.Pitch,
                distance = _orbitCamera.Distance,
                target = new[] { t.X, t.Y, t.Z },
                pan_offset = new[] { _orbitCamera.PanOffset.X, _orbitCamera.PanOffset.Y, _orbitCamera.PanOffset.Z }
            });
        }

        private CommandResult CmdAudio(JsonElement args)
        {
            if (_audioPlayer == null)
                return new CommandResult(false, "Audio player not available");

            string action = "status";
            if (args.ValueKind == JsonValueKind.Object &&
                args.TryGetProperty("action", out var actionProp))
            {
                action = actionProp.GetString() ?? "status";
            }

            switch (action)
            {
                case "play":
                    _audioPlayer.Play();
                    return new CommandResult(true, "Playing audio");
                case "stop":
                    _audioPlayer.Stop();
                    return new CommandResult(true, "Stopped audio");
                case "pause":
                    _audioPlayer.StreamPaused = !_audioPlayer.StreamPaused;
                    return new CommandResult(true, _audioPlayer.StreamPaused ? "Paused" : "Resumed");
                case "status":
                    return new CommandResult(true, "Audio status", new
                    {
                        playing = _audioPlayer.Playing,
                        paused = _audioPlayer.StreamPaused,
                        position = _audioPlayer.GetPlaybackPosition(),
                        stream = _audioPlayer.Stream?.GetClass() ?? "none"
                    });
                default:
                    return new CommandResult(false, $"Unknown audio action: {action}");
            }
        }

        private CommandResult CmdGetMeta(JsonElement args)
        {
            string? path = null;
            if (args.ValueKind == JsonValueKind.Object &&
                args.TryGetProperty("path", out var pathProp))
            {
                path = pathProp.GetString();
            }

            AssetEntry? entry;
            if (!string.IsNullOrEmpty(path))
            {
                entry = _allAssets.FirstOrDefault(a => a.Path == path);
                if (entry == null)
                    return new CommandResult(false, $"Asset not found: {path}");
            }
            else
            {
                entry = _currentAsset;
                if (entry == null)
                    return new CommandResult(false, "No asset currently loaded");
            }

            return new CommandResult(true, "Asset metadata", new
            {
                entry.Path,
                entry.Type,
                entry.TypeLabel,
                entry.SizeBytes,
                sizeFormatted = FormatFileSize(entry.SizeBytes),
                entry.ImportDate,
                entry.ImportMeta
            });
        }

        private CommandResult CmdValidate(JsonElement args)
        {
            var issues = new List<object>();
            int scanned = 0;

            foreach (var entry in _allAssets)
            {
                scanned++;
                try
                {
                    var resource = ResourceLoader.Load(entry.Path);
                    if (resource == null)
                    {
                        issues.Add(new { entry.Path, issue = "Failed to load" });
                    }
                }
                catch (Exception e)
                {
                    issues.Add(new { entry.Path, issue = e.Message });
                }
            }

            bool allValid = issues.Count == 0;
            return new CommandResult(allValid,
                allValid ? $"All {scanned} assets valid" : $"{issues.Count} issues found in {scanned} assets",
                new { scanned, issueCount = issues.Count, issues });
        }

        #endregion
    }
}
