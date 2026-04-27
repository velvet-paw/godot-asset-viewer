using Godot;
using System.Collections.Generic;
using System.Text.Json.Serialization;

namespace TeaLeaves.Systems
{
    /// <summary>
    /// Validates Godot scenes for common issues at runtime.
    /// Complements lint_project.gd (build-time UID/NodePath checks) with
    /// instantiation-based validation (missing textures, meshes, shaders, etc.).
    /// </summary>
    public static class SceneValidator
    {
        public static List<ValidationIssue> ValidateScene(string scenePath)
        {
            var issues = new List<ValidationIssue>();

            if (!FileAccess.FileExists(scenePath))
            {
                issues.Add(new ValidationIssue("error", "file_not_found", $"Scene file does not exist: {scenePath}"));
                return issues;
            }

            var packedScene = GD.Load<PackedScene>(scenePath);
            if (packedScene == null)
            {
                issues.Add(new ValidationIssue("error", "load_failed", $"Failed to load scene: {scenePath}"));
                return issues;
            }

            var sceneState = packedScene.GetState();
            if (sceneState == null)
            {
                issues.Add(new ValidationIssue("error", "invalid_state", "Scene has no valid state"));
                return issues;
            }

            ValidateNodeStructure(sceneState, issues, scenePath);
            ValidateConnections(sceneState, issues);

            Node? instance = null;
            try
            {
                instance = packedScene.Instantiate();
                ValidateInstantiatedScene(instance, issues);
            }
            catch (System.Exception ex)
            {
                issues.Add(new ValidationIssue("error", "instantiate_failed", $"Failed to instantiate: {ex.Message}"));
            }
            finally
            {
                instance?.QueueFree();
            }

            return issues;
        }

        private static void ValidateNodeStructure(SceneState state, List<ValidationIssue> issues, string scenePath)
        {
            var nodeCount = state.GetNodeCount();

            for (int i = 0; i < nodeCount; i++)
            {
                var nodePath = state.GetNodePath(i);

                for (int p = 0; p < state.GetNodePropertyCount(i); p++)
                {
                    var propName = state.GetNodePropertyName(i, p);
                    var propValue = state.GetNodePropertyValue(i, p);

                    if (propName == "script" && propValue.VariantType == Variant.Type.Object)
                    {
                        var script = propValue.As<Script>();
                        if (script == null)
                        {
                            issues.Add(new ValidationIssue("error", "missing_script",
                                $"Node '{nodePath}' has a missing or invalid script reference"));
                        }
                    }

                    if (propValue.VariantType == Variant.Type.Object)
                    {
                        var resource = propValue.As<Resource>();
                        if (resource == null && propValue.Obj != null)
                        {
                            issues.Add(new ValidationIssue("warning", "missing_resource",
                                $"Node '{nodePath}' property '{propName}' references a missing resource"));
                        }
                    }

                    if (propValue.VariantType == Variant.Type.NodePath)
                    {
                        var np = propValue.AsNodePath();
                        if (!np.IsEmpty && np.ToString().Contains(".."))
                        {
                            issues.Add(new ValidationIssue("info", "relative_nodepath",
                                $"Node '{nodePath}' property '{propName}' uses relative path: {np}"));
                        }
                    }
                }
            }
        }

        private static void ValidateConnections(SceneState state, List<ValidationIssue> issues)
        {
            var connectionCount = state.GetConnectionCount();

            for (int i = 0; i < connectionCount; i++)
            {
                var signal = state.GetConnectionSignal(i);
                var source = state.GetConnectionSource(i);
                var method = state.GetConnectionMethod(i);

                if (string.IsNullOrEmpty(method.ToString()))
                {
                    issues.Add(new ValidationIssue("error", "invalid_connection",
                        $"Connection from '{source}' signal '{signal}' has no target method"));
                }
            }
        }

        private static void ValidateInstantiatedScene(Node root, List<ValidationIssue> issues)
        {
            ValidateNodeRecursive(root, issues);
        }

        private static void ValidateNodeRecursive(Node node, List<ValidationIssue> issues)
        {
            var nodePath = node.GetPath().ToString();

            if (node is MeshInstance3D meshInstance)
            {
                ValidateMeshInstance(meshInstance, issues, nodePath);
            }
            else if (node is Sprite2D sprite)
            {
                if (sprite.Texture == null)
                {
                    issues.Add(new ValidationIssue("warning", "missing_texture",
                        $"Sprite2D '{nodePath}' has no texture assigned"));
                }
            }
            else if (node is Sprite3D sprite3d)
            {
                if (sprite3d.Texture == null)
                {
                    issues.Add(new ValidationIssue("warning", "missing_texture",
                        $"Sprite3D '{nodePath}' has no texture assigned"));
                }
            }
            else if (node is AnimationPlayer animPlayer)
            {
                ValidateAnimationPlayer(animPlayer, issues, nodePath);
            }
            else if (node is AudioStreamPlayer asp)
            {
                if (asp.Stream == null)
                {
                    issues.Add(new ValidationIssue("info", "missing_audio",
                        $"AudioStreamPlayer '{nodePath}' has no stream assigned"));
                }
            }
            else if (node is CollisionShape2D cs2d)
            {
                if (cs2d.Shape == null)
                {
                    issues.Add(new ValidationIssue("warning", "missing_collision_shape",
                        $"CollisionShape2D '{nodePath}' has no shape assigned"));
                }
            }
            else if (node is CollisionShape3D cs3d)
            {
                if (cs3d.Shape == null)
                {
                    issues.Add(new ValidationIssue("warning", "missing_collision_shape",
                        $"CollisionShape3D '{nodePath}' has no shape assigned"));
                }
            }

            foreach (var child in node.GetChildren())
            {
                ValidateNodeRecursive(child, issues);
            }
        }

        private static void ValidateMeshInstance(MeshInstance3D meshInstance, List<ValidationIssue> issues, string nodePath)
        {
            if (meshInstance.Mesh == null)
            {
                issues.Add(new ValidationIssue("warning", "missing_mesh",
                    $"MeshInstance3D '{nodePath}' has no mesh assigned"));
                return;
            }

            var surfaceCount = meshInstance.Mesh.GetSurfaceCount();
            for (int s = 0; s < surfaceCount; s++)
            {
                var material = meshInstance.GetActiveMaterial(s);
                if (material is ShaderMaterial shaderMat)
                {
                    if (shaderMat.Shader == null)
                    {
                        issues.Add(new ValidationIssue("error", "missing_shader",
                            $"MeshInstance3D '{nodePath}' surface {s} has ShaderMaterial with no shader"));
                    }
                }
            }
        }

        private static void ValidateAnimationPlayer(AnimationPlayer animPlayer, List<ValidationIssue> issues, string nodePath)
        {
            var animList = animPlayer.GetAnimationList();

            foreach (var animName in animList)
            {
                var animation = animPlayer.GetAnimation(animName);
                if (animation == null) continue;

                for (int t = 0; t < animation.GetTrackCount(); t++)
                {
                    var trackPath = animation.TrackGetPath(t);
                    var rootNode = animPlayer.GetNode(animPlayer.RootNode);
                    var targetNode = rootNode?.GetNodeOrNull(trackPath.ToString().Split(':')[0]);

                    if (targetNode == null)
                    {
                        issues.Add(new ValidationIssue("warning", "invalid_animation_path",
                            $"AnimationPlayer '{nodePath}' animation '{animName}' track {t} targets missing node: {trackPath}"));
                    }
                }
            }
        }
    }

    public class ValidationIssue
    {
        [JsonPropertyName("severity")]
        public string Severity { get; set; }

        [JsonPropertyName("code")]
        public string Code { get; set; }

        [JsonPropertyName("message")]
        public string Message { get; set; }

        public ValidationIssue(string severity, string code, string message)
        {
            Severity = severity;
            Code = code;
            Message = message;
        }
    }
}
