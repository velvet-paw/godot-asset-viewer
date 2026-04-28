using Godot;
using System;

namespace TeaLeaves.UI
{
    /// <summary>
    /// Pure-math orbital camera controller. No Node dependency — testable via dotnet test.
    /// Manages yaw/pitch/distance orbit around a target point, with pan offset support.
    /// </summary>
    public class OrbitCamera
    {
        public const float MinPitch = -89f;
        public const float MaxPitch = 89f;
        public const float MinDistance = 0.1f;
        public const float MaxDistance = 100f;

        private float _defaultYaw;
        private float _defaultPitch;
        private float _defaultDistance;
        private Vector3 _defaultTarget;

        public float Yaw { get; private set; }
        public float Pitch { get; private set; }
        public float Distance { get; private set; }
        public Vector3 Target { get; private set; }
        public Vector3 PanOffset { get; private set; }

        public OrbitCamera(float yaw = 30f, float pitch = -25f, float distance = 3f, Vector3 target = default)
        {
            SetState(yaw, pitch, distance, target);
            SaveDefaults();
        }

        public void SetState(float yaw, float pitch, float distance, Vector3 target)
        {
            Yaw = NormalizeYaw(yaw);
            Pitch = ClampPitch(pitch);
            Distance = ClampDistance(distance);
            Target = target;
            PanOffset = Vector3.Zero;
        }

        public void SaveDefaults()
        {
            _defaultYaw = Yaw;
            _defaultPitch = Pitch;
            _defaultDistance = Distance;
            _defaultTarget = Target;
        }

        public void Orbit(float deltaYaw, float deltaPitch)
        {
            Yaw = NormalizeYaw(Yaw + deltaYaw);
            Pitch = ClampPitch(Pitch + deltaPitch);
        }

        public void Zoom(float delta)
        {
            Distance = ClampDistance(Distance + delta);
        }

        /// <summary>
        /// Pan the orbit target in camera-local XY plane.
        /// deltaX = right (+) / left (-), deltaY = up (+) / down (-).
        /// Movement is scaled by current distance for consistent feel.
        /// </summary>
        public void Pan(float deltaX, float deltaY)
        {
            float scale = Distance * 0.1f;
            var (right, up) = GetCameraAxes();
            PanOffset += right * (deltaX * scale) + up * (deltaY * scale);
        }

        public void Reset()
        {
            Yaw = _defaultYaw;
            Pitch = _defaultPitch;
            Distance = _defaultDistance;
            Target = _defaultTarget;
            PanOffset = Vector3.Zero;
        }

        /// <summary>
        /// Compute camera world position and look-at target.
        /// </summary>
        public (Vector3 position, Vector3 lookAt) ComputeTransform()
        {
            var effectiveTarget = Target + PanOffset;

            float yawRad = Mathf.DegToRad(Yaw);
            float pitchRad = Mathf.DegToRad(Pitch);

            float x = Distance * Mathf.Cos(pitchRad) * Mathf.Sin(yawRad);
            float y = Distance * Mathf.Sin(-pitchRad);
            float z = Distance * Mathf.Cos(pitchRad) * Mathf.Cos(yawRad);

            var position = effectiveTarget + new Vector3(x, y, z);
            return (position, effectiveTarget);
        }

        private (Vector3 right, Vector3 up) GetCameraAxes()
        {
            var (position, lookAt) = ComputeTransform();
            var forward = (lookAt - position).Normalized();
            var worldUp = Vector3.Up;
            var right = forward.Cross(worldUp).Normalized();
            var up = right.Cross(forward).Normalized();
            return (right, up);
        }

        private static float NormalizeYaw(float yaw)
        {
            yaw %= 360f;
            if (yaw < 0f) yaw += 360f;
            return yaw;
        }

        private static float ClampPitch(float pitch)
        {
            return Mathf.Clamp(pitch, MinPitch, MaxPitch);
        }

        private static float ClampDistance(float distance)
        {
            return Mathf.Clamp(distance, MinDistance, MaxDistance);
        }
    }
}
