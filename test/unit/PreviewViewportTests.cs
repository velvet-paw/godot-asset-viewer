using GdUnit4;
using static GdUnit4.Assertions;
using Godot;
using TeaLeaves.UI;

[TestSuite]
public class PreviewViewportTests
{
    [TestCase]
    public void CalculateCameraPosition_SmallObject_ReasonableDistance()
    {
        var bounds = new Aabb(new Vector3(-0.5f, 0, -0.5f), new Vector3(1, 1, 1));
        var (position, target) = CameraFraming.CalculateFraming(bounds, 0, -20, 1.5f);

        // Camera should be positioned away from center
        AssertFloat(position.DistanceTo(target)).IsGreater(0.5f);
        // Target should be at center of bounds
        var center = bounds.GetCenter();
        AssertFloat(target.DistanceTo(center)).IsLess(0.01f);
    }

    [TestCase]
    public void CalculateCameraPosition_LargeObject_FartherAway()
    {
        var smallBounds = new Aabb(new Vector3(-0.5f, 0, -0.5f), new Vector3(1, 1, 1));
        var largeBounds = new Aabb(new Vector3(-5f, 0, -5f), new Vector3(10, 10, 10));

        var (smallPos, _) = CameraFraming.CalculateFraming(smallBounds, 0, -20, 1.5f);
        var (largePos, largeTarget) = CameraFraming.CalculateFraming(largeBounds, 0, -20, 1.5f);

        AssertFloat(largePos.DistanceTo(largeTarget)).IsGreater(smallPos.DistanceTo(smallBounds.GetCenter()));
    }

    [TestCase]
    public void OrbitPosition_0Yaw0Pitch_InFrontOfTarget()
    {
        var target = Vector3.Zero;
        float distance = 5f;
        var position = CameraFraming.OrbitPosition(target, 0, 0, distance);

        // At 0 yaw, 0 pitch, camera should be on +Z axis
        AssertFloat(position.Z).IsGreater(0);
        AssertFloat(Mathf.Abs(position.X)).IsLess(0.01f);
    }

    [TestCase]
    public void OrbitPosition_90Yaw_OnXAxis()
    {
        var target = Vector3.Zero;
        float distance = 5f;
        var position = CameraFraming.OrbitPosition(target, 90, 0, distance);

        // At 90 yaw, camera should be on +X axis
        AssertFloat(position.X).IsGreater(0);
        AssertFloat(Mathf.Abs(position.Z)).IsLess(0.01f);
    }
}
