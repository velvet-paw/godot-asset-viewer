using Godot;

/// <summary>
/// AutoLoad that forces window placement on the correct monitor at startup.
/// Runs before any game scene loads. Configured via project.godot [autoload].
/// </summary>
public partial class WindowSetup : Node
{
    /// <summary>Target monitor index (0-based). 2 = third monitor.</summary>
    private const int TargetScreen = 2;

    public override void _Ready()
    {
        if (TargetScreen < DisplayServer.GetScreenCount())
        {
            DisplayServer.WindowSetCurrentScreen(TargetScreen);
            var usable = DisplayServer.ScreenGetUsableRect(TargetScreen);
            var winSize = DisplayServer.WindowGetSize();
            DisplayServer.WindowSetPosition(usable.Position + (usable.Size - winSize) / 2);
        }

        DisplayServer.WindowSetFlag(DisplayServer.WindowFlags.AlwaysOnTop, true);
    }
}
