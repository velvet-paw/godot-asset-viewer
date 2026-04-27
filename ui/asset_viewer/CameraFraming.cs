using Godot;

namespace TeaLeaves.UI
{
    public static class CameraFraming
    {
        public static (Vector3 position, Vector3 target) CalculateFraming(Aabb bounds, float yawDeg, float pitchDeg, float paddingFactor)
        {
            var center = bounds.GetCenter();
            float radius = bounds.Size.Length() * 0.5f * paddingFactor;
            float distance = radius / Mathf.Tan(Mathf.DegToRad(35f)); // assuming ~70deg FOV

            var position = OrbitPosition(center, yawDeg, pitchDeg, distance);
            return (position, center);
        }

        public static Vector3 OrbitPosition(Vector3 target, float yawDeg, float pitchDeg, float distance)
        {
            float yawRad = Mathf.DegToRad(yawDeg);
            float pitchRad = Mathf.DegToRad(pitchDeg);

            float x = distance * Mathf.Cos(pitchRad) * Mathf.Sin(yawRad);
            float y = distance * Mathf.Sin(pitchRad);
            float z = distance * Mathf.Cos(pitchRad) * Mathf.Cos(yawRad);

            return target + new Vector3(x, y, z);
        }
    }
}
