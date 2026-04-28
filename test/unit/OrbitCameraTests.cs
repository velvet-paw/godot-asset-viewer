using GdUnit4;
using Godot;
using static GdUnit4.Assertions;
using TeaLeaves.UI;

[TestSuite]
public class OrbitCameraTests
{
    [TestCase]
    public void Constructor_SetsDefaults()
    {
        var cam = new OrbitCamera(30f, -25f, 3f, Vector3.Zero);
        AssertFloat(cam.Yaw).IsEqual(30f);
        AssertFloat(cam.Pitch).IsEqual(-25f);
        AssertFloat(cam.Distance).IsEqual(3f);
        AssertObject(cam.Target).IsEqual(Vector3.Zero);
        AssertObject(cam.PanOffset).IsEqual(Vector3.Zero);
    }

    [TestCase]
    public void Orbit_AdjustsYawAndPitch()
    {
        var cam = new OrbitCamera(0f, 0f, 3f);
        cam.Orbit(45f, -10f);
        AssertFloat(cam.Yaw).IsEqual(45f);
        AssertFloat(cam.Pitch).IsEqual(-10f);
    }

    [TestCase]
    public void Orbit_YawWrapsAround()
    {
        var cam = new OrbitCamera(350f, 0f, 3f);
        cam.Orbit(20f, 0f);
        AssertFloat(cam.Yaw).IsEqual(10f);
    }

    [TestCase]
    public void Orbit_YawWrapsNegative()
    {
        var cam = new OrbitCamera(10f, 0f, 3f);
        cam.Orbit(-20f, 0f);
        AssertFloat(cam.Yaw).IsEqual(350f);
    }

    [TestCase]
    public void Orbit_PitchClampedToMin()
    {
        var cam = new OrbitCamera(0f, -80f, 3f);
        cam.Orbit(0f, -20f);
        AssertFloat(cam.Pitch).IsEqual(OrbitCamera.MinPitch);
    }

    [TestCase]
    public void Orbit_PitchClampedToMax()
    {
        var cam = new OrbitCamera(0f, 80f, 3f);
        cam.Orbit(0f, 20f);
        AssertFloat(cam.Pitch).IsEqual(OrbitCamera.MaxPitch);
    }

    [TestCase]
    public void Zoom_AdjustsDistance()
    {
        var cam = new OrbitCamera(0f, 0f, 5f);
        cam.Zoom(-2f);
        AssertFloat(cam.Distance).IsEqual(3f);
    }

    [TestCase]
    public void Zoom_ClampedToMin()
    {
        var cam = new OrbitCamera(0f, 0f, 0.5f);
        cam.Zoom(-1f);
        AssertFloat(cam.Distance).IsEqual(OrbitCamera.MinDistance);
    }

    [TestCase]
    public void Zoom_ClampedToMax()
    {
        var cam = new OrbitCamera(0f, 0f, 99f);
        cam.Zoom(5f);
        AssertFloat(cam.Distance).IsEqual(OrbitCamera.MaxDistance);
    }

    [TestCase]
    public void Pan_ShiftsPanOffset()
    {
        var cam = new OrbitCamera(0f, 0f, 3f);
        cam.Pan(1f, 0f);
        AssertObject(cam.PanOffset).IsNotEqual(Vector3.Zero);
    }

    [TestCase]
    public void Pan_ScalesWithDistance()
    {
        var near = new OrbitCamera(0f, 0f, 1f);
        var far = new OrbitCamera(0f, 0f, 10f);
        near.Pan(1f, 0f);
        far.Pan(1f, 0f);
        // Farther camera should produce larger pan offset
        AssertFloat(far.PanOffset.Length()).IsGreater(near.PanOffset.Length());
    }

    [TestCase]
    public void Reset_RestoresDefaults()
    {
        var cam = new OrbitCamera(30f, -25f, 3f, Vector3.Zero);
        cam.Orbit(45f, 10f);
        cam.Zoom(2f);
        cam.Pan(1f, 1f);
        cam.Reset();
        AssertFloat(cam.Yaw).IsEqual(30f);
        AssertFloat(cam.Pitch).IsEqual(-25f);
        AssertFloat(cam.Distance).IsEqual(3f);
        AssertObject(cam.PanOffset).IsEqual(Vector3.Zero);
    }

    [TestCase]
    public void ComputeTransform_ReturnsPositionAndLookAt()
    {
        var cam = new OrbitCamera(0f, 0f, 5f, Vector3.Zero);
        var (position, lookAt) = cam.ComputeTransform();
        // At yaw=0, pitch=0: camera should be along +Z axis
        AssertFloat(position.Z).IsGreater(0f);
        AssertObject(lookAt).IsEqual(Vector3.Zero);
    }

    [TestCase]
    public void ComputeTransform_WithPanOffset_ShiftsLookAt()
    {
        var cam = new OrbitCamera(0f, 0f, 5f, Vector3.Zero);
        cam.Pan(1f, 0f);
        var (_, lookAt) = cam.ComputeTransform();
        // lookAt should no longer be at origin
        AssertObject(lookAt).IsNotEqual(Vector3.Zero);
    }

    [TestCase]
    public void SetState_UpdatesAllFields()
    {
        var cam = new OrbitCamera();
        cam.SetState(90f, -45f, 10f, new Vector3(1, 2, 3));
        AssertFloat(cam.Yaw).IsEqual(90f);
        AssertFloat(cam.Pitch).IsEqual(-45f);
        AssertFloat(cam.Distance).IsEqual(10f);
        AssertObject(cam.Target).IsEqual(new Vector3(1, 2, 3));
        AssertObject(cam.PanOffset).IsEqual(Vector3.Zero);
    }
}
