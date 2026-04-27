using Godot;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TeaLeaves.Systems
{
    /// <summary>
    /// DevTools autoload - provides a file-based command interface for Claude Code.
    /// Add as autoload in Project Settings > Autoload with name "DevTools"
    ///
    /// Commands are sent via user://devtools_commands.json and results written to
    /// user://devtools_results.json. This enables agentic coding tools to:
    /// - Take screenshots for visual verification
    /// - Validate scenes at runtime
    /// - Inspect/modify node state
    /// - Monitor performance
    /// - Simulate input for automated testing
    /// </summary>
    public partial class DevTools : Node
    {
        private const string CommandsPath = "user://devtools_commands.json";
        private const string ResultsPath = "user://devtools_results.json";
        private const string LogPath = "user://devtools_log.jsonl";

        private string _commandsAbsPath = "";
        private string _resultsAbsPath = "";
        private string _logAbsPath = "";
        private DateTime _lastCommandCheck;
        private bool _headlessMode;

        private Dictionary<string, Func<JsonElement, CommandResult>> _handlers = new();

        // Input simulation state tracking
        private HashSet<string> _activeSimulatedInputs = new();

        public static DevTools? Instance { get; private set; }

        public override void _Ready()
        {
            Instance = this;
            _headlessMode = DisplayServer.GetName() == "headless";

            _commandsAbsPath = ProjectSettings.GlobalizePath(CommandsPath);
            _resultsAbsPath = ProjectSettings.GlobalizePath(ResultsPath);
            _logAbsPath = ProjectSettings.GlobalizePath(LogPath);

            InitializeHandlers();
            ClearStaleFiles();

            Log("system", "DevTools initialized", new { headless = _headlessMode, pid = OS.GetProcessId() });

            ProcessCommandLineArgs();
        }

        public override void _Process(double delta)
        {
            // Poll for commands every 100ms
            if ((DateTime.Now - _lastCommandCheck).TotalMilliseconds > 100)
            {
                _lastCommandCheck = DateTime.Now;
                CheckForCommands();
            }
        }

        private void InitializeHandlers()
        {
            _handlers = new Dictionary<string, Func<JsonElement, CommandResult>>
            {
                ["screenshot"] = CmdScreenshot,
                ["scene_tree"] = CmdSceneTree,
                ["validate_scene"] = CmdValidateScene,
                ["validate_all_scenes"] = CmdValidateAllScenes,
                ["get_state"] = CmdGetState,
                ["set_state"] = CmdSetState,
                ["run_method"] = CmdRunMethod,
                ["performance"] = CmdPerformance,
                ["quit"] = CmdQuit,
                ["ping"] = _ => new CommandResult(true, "pong", new { timestamp = Time.GetUnixTimeFromSystem() }),
                // Input simulation
                ["input_press"] = CmdInputPress,
                ["input_release"] = CmdInputRelease,
                ["input_tap"] = CmdInputTap,
                ["input_clear"] = CmdInputClear,
                ["input_actions"] = CmdInputActions,
                ["input_sequence"] = CmdInputSequence,
            };
        }

        public override void _ExitTree()
        {
            // Release all simulated inputs on exit
            ClearAllSimulatedInputs();
        }

        private void ProcessCommandLineArgs()
        {
            var args = OS.GetCmdlineArgs();

            for (int i = 0; i < args.Length; i++)
            {
                switch (args[i])
                {
                    case "--devtools-screenshot":
                        GetTree().CreateTimer(0.5).Timeout += () =>
                        {
                            var result = CmdScreenshot(default);
                            WriteResult("screenshot", result);
                            GetTree().Quit();
                        };
                        break;

                    case "--devtools-validate":
                        GetTree().CreateTimer(0.1).Timeout += () =>
                        {
                            var result = CmdValidateAllScenes(default);
                            WriteResult("validate_all_scenes", result);
                            GetTree().Quit(result.Success ? 0 : 1);
                        };
                        break;
                }
            }
        }

        private void CheckForCommands()
        {
            if (!File.Exists(_commandsAbsPath)) return;

            try
            {
                var json = File.ReadAllText(_commandsAbsPath);
                File.Delete(_commandsAbsPath);

                var command = JsonSerializer.Deserialize<DevToolsCommand>(json);
                if (command == null || command.Action == null) return;

                Log("command", $"Received command: {command.Action}", command);

                CommandResult result;
                if (_handlers.TryGetValue(command.Action, out var handler))
                {
                    try
                    {
                        result = handler(command.Args);
                    }
                    catch (Exception ex)
                    {
                        result = new CommandResult(false, ex.Message, new { exception = ex.ToString() });
                    }
                }
                else
                {
                    result = new CommandResult(false, $"Unknown command: {command.Action}");
                }

                WriteResult(command.Action, result);
            }
            catch (Exception ex)
            {
                Log("error", "Failed to process command", new { error = ex.Message });
            }
        }

        private void WriteResult(string action, CommandResult result)
        {
            var response = new
            {
                action,
                success = result.Success,
                message = result.Message,
                data = result.Data,
                timestamp = Time.GetUnixTimeFromSystem()
            };

            File.WriteAllText(_resultsAbsPath, JsonSerializer.Serialize(response, new JsonSerializerOptions { WriteIndented = true }));
            Log("result", $"Command {action} completed", new { success = result.Success });
        }

        private void ClearStaleFiles()
        {
            if (File.Exists(_commandsAbsPath)) File.Delete(_commandsAbsPath);
            if (File.Exists(_resultsAbsPath)) File.Delete(_resultsAbsPath);
        }

        // ==================== COMMAND HANDLERS ====================

        private CommandResult CmdScreenshot(JsonElement args)
        {
            var filename = args.ValueKind != JsonValueKind.Undefined && args.TryGetProperty("filename", out var fn)
                ? fn.GetString() ?? $"screenshot_{DateTime.Now:yyyyMMdd_HHmmss}.png"
                : $"screenshot_{DateTime.Now:yyyyMMdd_HHmmss}.png";

            var dir = "user://screenshots";
            DirAccess.MakeDirRecursiveAbsolute(ProjectSettings.GlobalizePath(dir));

            var path = $"{dir}/{filename}";
            var absPath = ProjectSettings.GlobalizePath(path);

            var image = GetViewport().GetTexture().GetImage();
            var error = image.SavePng(absPath);

            if (error != Error.Ok)
                return new CommandResult(false, $"Failed to save screenshot: {error}");

            return new CommandResult(true, "Screenshot captured", new {
                path = absPath,
                size = new { width = image.GetWidth(), height = image.GetHeight() }
            });
        }

        private CommandResult CmdSceneTree(JsonElement args)
        {
            var root = GetTree().CurrentScene;
            if (root == null)
                return new CommandResult(false, "No current scene");

            var depth = args.ValueKind != JsonValueKind.Undefined && args.TryGetProperty("depth", out var d) ? d.GetInt32() : 10;
            var tree = SerializeNode(root, depth);
            return new CommandResult(true, "Scene tree captured", tree);
        }

        private object SerializeNode(Node node, int maxDepth, int currentDepth = 0)
        {
            var data = new Dictionary<string, object?>
            {
                ["name"] = node.Name.ToString(),
                ["type"] = node.GetClass(),
                ["path"] = node.GetPath().ToString()
            };

            if (node is Node2D n2d)
            {
                data["position"] = new { x = n2d.Position.X, y = n2d.Position.Y };
                data["rotation"] = n2d.Rotation;
                data["visible"] = n2d.Visible;
            }
            else if (node is Node3D n3d)
            {
                data["position"] = new { x = n3d.Position.X, y = n3d.Position.Y, z = n3d.Position.Z };
                data["rotation"] = new { x = n3d.Rotation.X, y = n3d.Rotation.Y, z = n3d.Rotation.Z };
                data["visible"] = n3d.Visible;
            }
            else if (node is Control ctrl)
            {
                data["position"] = new { x = ctrl.Position.X, y = ctrl.Position.Y };
                data["size"] = new { x = ctrl.Size.X, y = ctrl.Size.Y };
                data["visible"] = ctrl.Visible;
            }

            if (currentDepth < maxDepth && node.GetChildCount() > 0)
            {
                var children = new List<object>();
                foreach (var child in node.GetChildren())
                {
                    children.Add(SerializeNode(child, maxDepth, currentDepth + 1));
                }
                data["children"] = children;
            }

            return data;
        }

        private CommandResult CmdValidateScene(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("path", out var pathEl))
                return new CommandResult(false, "Missing 'path' argument");

            var scenePath = pathEl.GetString();
            if (string.IsNullOrEmpty(scenePath))
                return new CommandResult(false, "Invalid 'path' argument");

            var issues = SceneValidator.ValidateScene(scenePath);

            return new CommandResult(
                issues.Count == 0,
                issues.Count == 0 ? "Scene valid" : $"Found {issues.Count} issues",
                new { scene = scenePath, issues }
            );
        }

        private CommandResult CmdValidateAllScenes(JsonElement args)
        {
            var allIssues = new Dictionary<string, List<ValidationIssue>>();
            var sceneFiles = FindAllScenes("res://");

            foreach (var scenePath in sceneFiles)
            {
                var issues = SceneValidator.ValidateScene(scenePath);
                if (issues.Count > 0)
                    allIssues[scenePath] = issues;
            }

            return new CommandResult(
                allIssues.Count == 0,
                allIssues.Count == 0 ? "All scenes valid" : $"Found issues in {allIssues.Count} scenes",
                new { total_scenes = sceneFiles.Count, scenes_with_issues = allIssues.Count, issues = allIssues }
            );
        }

        private List<string> FindAllScenes(string path)
        {
            var scenes = new List<string>();
            var dir = DirAccess.Open(path);
            if (dir == null) return scenes;

            dir.ListDirBegin();
            var fileName = dir.GetNext();

            while (!string.IsNullOrEmpty(fileName))
            {
                if (dir.CurrentIsDir() && !fileName.StartsWith(".") && fileName != "addons")
                {
                    scenes.AddRange(FindAllScenes($"{path}/{fileName}".Replace("//", "/")));
                }
                else if (fileName.EndsWith(".tscn") || fileName.EndsWith(".scn"))
                {
                    scenes.Add($"{path}/{fileName}".Replace("//", "/"));
                }
                fileName = dir.GetNext();
            }

            return scenes;
        }

        private CommandResult CmdGetState(JsonElement args)
        {
            var path = args.ValueKind != JsonValueKind.Undefined && args.TryGetProperty("node_path", out var p) ? p.GetString() : null;

            var currentScene = GetTree().CurrentScene;
            if (currentScene == null)
                return new CommandResult(false, "No current scene");

            Node target = string.IsNullOrEmpty(path)
                ? currentScene
                : currentScene.GetNodeOrNull(path);

            if (target == null)
                return new CommandResult(false, $"Node not found: {path}");

            var state = new Dictionary<string, object?>
            {
                ["node_class"] = target.GetClass(),
                ["node_path"] = target.GetPath().ToString()
            };

            foreach (var prop in target.GetPropertyList())
            {
                var name = prop["name"].AsString();
                var usage = (PropertyUsageFlags)prop["usage"].AsInt32();

                if ((usage & PropertyUsageFlags.ScriptVariable) != 0 ||
                    (usage & PropertyUsageFlags.Storage) != 0)
                {
                    var value = target.Get(name);
                    state[name] = SerializeVariant(value);
                }
            }

            return new CommandResult(true, "State retrieved", state);
        }

        private CommandResult CmdSetState(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("node_path", out var pathEl))
                return new CommandResult(false, "Missing 'node_path' argument");
            if (!args.TryGetProperty("property", out var propEl))
                return new CommandResult(false, "Missing 'property' argument");
            if (!args.TryGetProperty("value", out var valueEl))
                return new CommandResult(false, "Missing 'value' argument");

            var nodePath = pathEl.GetString();
            var propName = propEl.GetString();
            if (string.IsNullOrEmpty(nodePath) || string.IsNullOrEmpty(propName))
                return new CommandResult(false, "Invalid arguments");

            var currentScene = GetTree().CurrentScene;
            if (currentScene == null)
                return new CommandResult(false, "No current scene");

            var target = currentScene.GetNodeOrNull(nodePath);
            if (target == null)
                return new CommandResult(false, $"Node not found: {nodePath}");

            target.Set(propName, JsonToVariant(valueEl));
            return new CommandResult(true, "State updated");
        }

        private CommandResult CmdRunMethod(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("node_path", out var pathEl))
                return new CommandResult(false, "Missing 'node_path' argument");
            if (!args.TryGetProperty("method", out var methodEl))
                return new CommandResult(false, "Missing 'method' argument");

            var nodePath = pathEl.GetString();
            var methodName = methodEl.GetString();
            if (string.IsNullOrEmpty(nodePath) || string.IsNullOrEmpty(methodName))
                return new CommandResult(false, "Invalid arguments");

            var currentScene = GetTree().CurrentScene;
            if (currentScene == null)
                return new CommandResult(false, "No current scene");

            var target = currentScene.GetNodeOrNull(nodePath);
            if (target == null)
                return new CommandResult(false, $"Node not found: {nodePath}");

            var methodArgs = new Godot.Collections.Array();
            if (args.TryGetProperty("args", out var argsEl) && argsEl.ValueKind == JsonValueKind.Array)
            {
                foreach (var arg in argsEl.EnumerateArray())
                    methodArgs.Add(JsonToVariant(arg));
            }

            var result = target.Callv(methodName, methodArgs);
            return new CommandResult(true, "Method called", new { result = SerializeVariant(result) });
        }

        private CommandResult CmdPerformance(JsonElement args)
        {
            var data = new Dictionary<string, object>
            {
                ["fps"] = Engine.GetFramesPerSecond(),
                ["frame_time_ms"] = 1000.0 / Math.Max(1, Engine.GetFramesPerSecond()),
                ["physics_fps"] = Engine.PhysicsTicksPerSecond,
                ["static_memory_mb"] = OS.GetStaticMemoryUsage() / (1024.0 * 1024.0),
                ["video_memory_mb"] = Performance.GetMonitor(Performance.Monitor.RenderVideoMemUsed) / (1024.0 * 1024.0),
                ["draw_calls"] = Performance.GetMonitor(Performance.Monitor.RenderTotalDrawCallsInFrame),
                ["objects"] = Performance.GetMonitor(Performance.Monitor.ObjectCount),
                ["nodes"] = Performance.GetMonitor(Performance.Monitor.ObjectNodeCount),
                ["orphan_nodes"] = Performance.GetMonitor(Performance.Monitor.ObjectOrphanNodeCount),
                ["physics_2d_active_objects"] = Performance.GetMonitor(Performance.Monitor.Physics2DActiveObjects),
                ["physics_3d_active_objects"] = Performance.GetMonitor(Performance.Monitor.Physics3DActiveObjects),
            };

            return new CommandResult(true, "Performance data captured", data);
        }

        private CommandResult CmdQuit(JsonElement args)
        {
            var exitCode = args.ValueKind != JsonValueKind.Undefined && args.TryGetProperty("exit_code", out var ec) ? ec.GetInt32() : 0;
            GetTree().Quit(exitCode);
            return new CommandResult(true, "Quitting");
        }

        // ==================== INPUT SIMULATION ====================

        private CommandResult CmdInputPress(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("action", out var actionEl))
                return new CommandResult(false, "Missing 'action' argument");

            var action = actionEl.GetString();
            if (string.IsNullOrEmpty(action))
                return new CommandResult(false, "Invalid 'action' argument");

            if (!InputMap.HasAction(action))
                return new CommandResult(false, $"Unknown action: {action}. Use 'input_actions' to list available actions.");

            var strength = args.TryGetProperty("strength", out var strengthEl) ? (float)strengthEl.GetDouble() : 1.0f;
            strength = Mathf.Clamp(strength, 0.0f, 1.0f);

            Input.ActionPress(action, strength);
            _activeSimulatedInputs.Add(action);

            Log("input", $"Pressed action: {action}", new { action, strength });
            return new CommandResult(true, $"Pressed: {action}", new { action, strength, active_inputs = _activeSimulatedInputs.ToArray() });
        }

        private CommandResult CmdInputRelease(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("action", out var actionEl))
                return new CommandResult(false, "Missing 'action' argument");

            var action = actionEl.GetString();
            if (string.IsNullOrEmpty(action))
                return new CommandResult(false, "Invalid 'action' argument");

            if (!InputMap.HasAction(action))
                return new CommandResult(false, $"Unknown action: {action}. Use 'input_actions' to list available actions.");

            Input.ActionRelease(action);
            _activeSimulatedInputs.Remove(action);

            Log("input", $"Released action: {action}", new { action });
            return new CommandResult(true, $"Released: {action}", new { action, active_inputs = _activeSimulatedInputs.ToArray() });
        }

        private CommandResult CmdInputTap(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("action", out var actionEl))
                return new CommandResult(false, "Missing 'action' argument");

            var action = actionEl.GetString();
            if (string.IsNullOrEmpty(action))
                return new CommandResult(false, "Invalid 'action' argument");

            if (!InputMap.HasAction(action))
                return new CommandResult(false, $"Unknown action: {action}. Use 'input_actions' to list available actions.");

            var holdSeconds = args.TryGetProperty("hold_seconds", out var holdEl) ? holdEl.GetDouble() : 0.0;
            var strength = args.TryGetProperty("strength", out var strengthEl) ? (float)strengthEl.GetDouble() : 1.0f;
            strength = Mathf.Clamp(strength, 0.0f, 1.0f);

            Input.ActionPress(action, strength);
            _activeSimulatedInputs.Add(action);

            if (holdSeconds > 0)
            {
                // Schedule release after hold duration
                GetTree().CreateTimer(holdSeconds).Timeout += () =>
                {
                    Input.ActionRelease(action);
                    _activeSimulatedInputs.Remove(action);
                    Log("input", $"Released action after hold: {action}", new { action, hold_seconds = holdSeconds });
                };
            }
            else
            {
                // Release on next frame for a single-frame tap
                GetTree().CreateTimer(0.0).Timeout += () =>
                {
                    Input.ActionRelease(action);
                    _activeSimulatedInputs.Remove(action);
                    Log("input", $"Released action (tap): {action}", new { action });
                };
            }

            Log("input", $"Tapped action: {action}", new { action, hold_seconds = holdSeconds, strength });
            return new CommandResult(true, $"Tapped: {action}", new { action, hold_seconds = holdSeconds, strength });
        }

        private CommandResult CmdInputClear(JsonElement args)
        {
            var cleared = ClearAllSimulatedInputs();
            return new CommandResult(true, $"Cleared {cleared.Length} inputs", new { cleared_actions = cleared });
        }

        private string[] ClearAllSimulatedInputs()
        {
            var cleared = _activeSimulatedInputs.ToArray();
            foreach (var action in cleared)
            {
                Input.ActionRelease(action);
            }
            _activeSimulatedInputs.Clear();
            if (cleared.Length > 0)
            {
                Log("input", $"Cleared all simulated inputs", new { count = cleared.Length, actions = cleared });
            }
            return cleared;
        }

        private CommandResult CmdInputActions(JsonElement args)
        {
            var actions = InputMap.GetActions();
            var actionList = new List<object>();

            foreach (var action in actions)
            {
                var actionName = action.ToString();
                // Skip built-in UI actions by default unless requested
                var includeBuiltin = args.TryGetProperty("include_builtin", out var builtinEl) && builtinEl.GetBoolean();
                if (!includeBuiltin && actionName.StartsWith("ui_"))
                    continue;

                var events = InputMap.ActionGetEvents(action);
                var eventDescriptions = new List<string>();
                foreach (var evt in events)
                {
                    eventDescriptions.Add(evt.AsText());
                }

                actionList.Add(new
                {
                    name = actionName,
                    events = eventDescriptions,
                    is_pressed = Input.IsActionPressed(action)
                });
            }

            return new CommandResult(true, $"Found {actionList.Count} actions", new { actions = actionList });
        }

        private CommandResult CmdInputSequence(JsonElement args)
        {
            if (args.ValueKind == JsonValueKind.Undefined || !args.TryGetProperty("steps", out var stepsEl))
                return new CommandResult(false, "Missing 'steps' argument");

            if (stepsEl.ValueKind != JsonValueKind.Array)
                return new CommandResult(false, "'steps' must be an array");

            var steps = new List<SequenceStep>();
            int stepIndex = 0;

            foreach (var stepEl in stepsEl.EnumerateArray())
            {
                if (!stepEl.TryGetProperty("type", out var typeEl))
                    return new CommandResult(false, $"Step {stepIndex}: missing 'type'");

                var stepType = typeEl.GetString();
                var step = new SequenceStep { Type = stepType ?? "", Index = stepIndex };

                switch (stepType)
                {
                    case "press":
                    case "release":
                    case "tap":
                    case "hold":
                        if (!stepEl.TryGetProperty("action", out var actionEl))
                            return new CommandResult(false, $"Step {stepIndex}: '{stepType}' requires 'action'");
                        step.Action = actionEl.GetString() ?? "";
                        if (!InputMap.HasAction(step.Action))
                            return new CommandResult(false, $"Step {stepIndex}: unknown action '{step.Action}'");
                        if (stepEl.TryGetProperty("seconds", out var secEl))
                            step.Seconds = secEl.GetDouble();
                        if (stepEl.TryGetProperty("strength", out var strEl))
                            step.Strength = (float)strEl.GetDouble();
                        break;

                    case "wait":
                        if (!stepEl.TryGetProperty("seconds", out var waitEl))
                            return new CommandResult(false, $"Step {stepIndex}: 'wait' requires 'seconds'");
                        step.Seconds = waitEl.GetDouble();
                        break;

                    case "screenshot":
                        if (stepEl.TryGetProperty("filename", out var fnEl))
                            step.Filename = fnEl.GetString();
                        break;

                    case "assert":
                        if (!stepEl.TryGetProperty("node", out var nodeEl))
                            return new CommandResult(false, $"Step {stepIndex}: 'assert' requires 'node'");
                        if (!stepEl.TryGetProperty("property", out var propEl))
                            return new CommandResult(false, $"Step {stepIndex}: 'assert' requires 'property'");
                        if (!stepEl.TryGetProperty("equals", out var equalsEl))
                            return new CommandResult(false, $"Step {stepIndex}: 'assert' requires 'equals'");
                        step.NodePath = nodeEl.GetString() ?? "";
                        step.Property = propEl.GetString() ?? "";
                        step.ExpectedValue = equalsEl;
                        break;

                    case "clear":
                        // No additional args needed
                        break;

                    default:
                        return new CommandResult(false, $"Step {stepIndex}: unknown step type '{stepType}'");
                }

                steps.Add(step);
                stepIndex++;
            }

            // Execute sequence asynchronously
            var sequenceId = Guid.NewGuid().ToString("N")[..8];
            var timeout = args.TryGetProperty("timeout", out var timeoutEl) ? timeoutEl.GetDouble() : 60.0;

            Log("input", $"Starting sequence {sequenceId}", new { step_count = steps.Count, timeout });
            ExecuteSequenceAsync(sequenceId, steps, timeout);

            return new CommandResult(true, $"Sequence {sequenceId} started with {steps.Count} steps",
                new { sequence_id = sequenceId, step_count = steps.Count });
        }

        private async void ExecuteSequenceAsync(string sequenceId, List<SequenceStep> steps, double timeout)
        {
            var results = new List<object>();
            var startTime = Time.GetUnixTimeFromSystem();

            foreach (var step in steps)
            {
                // Check timeout
                if (Time.GetUnixTimeFromSystem() - startTime > timeout)
                {
                    Log("input", $"Sequence {sequenceId} timed out at step {step.Index}", null);
                    results.Add(new { step = step.Index, type = step.Type, status = "timeout" });
                    break;
                }

                try
                {
                    var stepResult = await ExecuteStepAsync(step);
                    results.Add(new { step = step.Index, type = step.Type, status = "ok", result = stepResult });
                    Log("input", $"Sequence {sequenceId} step {step.Index} ({step.Type}) completed", stepResult);
                }
                catch (Exception ex)
                {
                    results.Add(new { step = step.Index, type = step.Type, status = "error", error = ex.Message });
                    Log("input", $"Sequence {sequenceId} step {step.Index} failed: {ex.Message}", null);
                    break;
                }
            }

            Log("input", $"Sequence {sequenceId} completed", new { step_count = results.Count });
        }

        private async System.Threading.Tasks.Task<object?> ExecuteStepAsync(SequenceStep step)
        {
            switch (step.Type)
            {
                case "press":
                    Input.ActionPress(step.Action, step.Strength);
                    _activeSimulatedInputs.Add(step.Action);
                    return new { action = step.Action };

                case "release":
                    Input.ActionRelease(step.Action);
                    _activeSimulatedInputs.Remove(step.Action);
                    return new { action = step.Action };

                case "tap":
                    Input.ActionPress(step.Action, step.Strength);
                    _activeSimulatedInputs.Add(step.Action);
                    await ToSignal(GetTree().CreateTimer(step.Seconds > 0 ? step.Seconds : GetPhysicsProcessDeltaTime()), SceneTreeTimer.SignalName.Timeout);
                    Input.ActionRelease(step.Action);
                    _activeSimulatedInputs.Remove(step.Action);
                    return new { action = step.Action, hold_seconds = step.Seconds };

                case "hold":
                    Input.ActionPress(step.Action, step.Strength);
                    _activeSimulatedInputs.Add(step.Action);
                    await ToSignal(GetTree().CreateTimer(step.Seconds), SceneTreeTimer.SignalName.Timeout);
                    Input.ActionRelease(step.Action);
                    _activeSimulatedInputs.Remove(step.Action);
                    return new { action = step.Action, hold_seconds = step.Seconds };

                case "wait":
                    await ToSignal(GetTree().CreateTimer(step.Seconds), SceneTreeTimer.SignalName.Timeout);
                    return new { waited_seconds = step.Seconds };

                case "screenshot":
                    var filename = step.Filename ?? $"sequence_{DateTime.Now:yyyyMMdd_HHmmss}.png";
                    var ssResult = CmdScreenshot(JsonDocument.Parse($"{{\"filename\":\"{filename}\"}}").RootElement);
                    return ssResult.Data;

                case "assert":
                    var currentScene = GetTree().CurrentScene;
                    if (currentScene == null)
                        throw new InvalidOperationException("No current scene");

                    var target = currentScene.GetNodeOrNull(step.NodePath);
                    if (target == null)
                        throw new InvalidOperationException($"Node not found: {step.NodePath}");

                    var actualValue = target.Get(step.Property);
                    var expectedVariant = JsonToVariant(step.ExpectedValue);

                    if (!actualValue.Equals(expectedVariant))
                        throw new InvalidOperationException($"Assertion failed: {step.NodePath}.{step.Property} = {actualValue}, expected {expectedVariant}");

                    return new { node = step.NodePath, property = step.Property, value = SerializeVariant(actualValue) };

                case "clear":
                    var cleared = ClearAllSimulatedInputs();
                    return new { cleared_actions = cleared };

                default:
                    throw new InvalidOperationException($"Unknown step type: {step.Type}");
            }
        }

        private class SequenceStep
        {
            public string Type { get; set; } = "";
            public int Index { get; set; }
            public string Action { get; set; } = "";
            public double Seconds { get; set; }
            public float Strength { get; set; } = 1.0f;
            public string? Filename { get; set; }
            public string NodePath { get; set; } = "";
            public string Property { get; set; } = "";
            public JsonElement ExpectedValue { get; set; }
        }

        // ==================== UTILITIES ====================

        private object? SerializeVariant(Variant value)
        {
            return value.VariantType switch
            {
                Variant.Type.Nil => null,
                Variant.Type.Bool => value.AsBool(),
                Variant.Type.Int => value.AsInt64(),
                Variant.Type.Float => value.AsDouble(),
                Variant.Type.String => value.AsString(),
                Variant.Type.Vector2 => new { x = value.AsVector2().X, y = value.AsVector2().Y },
                Variant.Type.Vector3 => new { x = value.AsVector3().X, y = value.AsVector3().Y, z = value.AsVector3().Z },
                Variant.Type.Color => new { r = value.AsColor().R, g = value.AsColor().G, b = value.AsColor().B, a = value.AsColor().A },
                _ => value.ToString()
            };
        }

        private Variant JsonToVariant(JsonElement el)
        {
            return el.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                JsonValueKind.Number => el.TryGetInt64(out var i) ? i : el.GetDouble(),
                JsonValueKind.String => el.GetString() ?? "",
                _ => el.ToString()
            };
        }

        // ==================== PUBLIC LOGGING API ====================

        /// <summary>
        /// Log a structured message to the DevTools log file.
        /// Use for debugging and tracing during development.
        /// </summary>
        public static void Log(string category, string message, object? data = null)
        {
            Instance?.WriteLog(category, message, data);
        }

        private void WriteLog(string category, string message, object? data)
        {
            var entry = new
            {
                timestamp = Time.GetUnixTimeFromSystem(),
                frame = Engine.GetProcessFrames(),
                category,
                message,
                data
            };

            var json = JsonSerializer.Serialize(entry);

            using var file = new StreamWriter(_logAbsPath, append: true);
            file.WriteLine(json);

            if (OS.IsDebugBuild())
                GD.Print($"[{category}] {message}");
        }
    }

    // ==================== DATA CLASSES ====================

    internal class DevToolsCommand
    {
        [JsonPropertyName("action")]
        public string? Action { get; set; }

        [JsonPropertyName("args")]
        public JsonElement Args { get; set; }
    }

    internal record CommandResult(bool Success, string Message, object? Data = null);
}
