using Godot;
using System;
using System.Collections.Generic;

namespace TeaLeaves.UI
{
    /// <summary>
    /// Bone pose data: rotation (local space) and optional position offset.
    /// </summary>
    public struct BonePose
    {
        public string BoneName;
        public Quaternion Rotation;
        public Vector3? PositionOffset;
    }

    /// <summary>
    /// Generates procedural animation poses for creature and humanoid skeletons.
    /// Pure math — no scene tree dependency. Testable with dotnet test.
    /// </summary>
    public class ProceduralAnimator
    {
        private readonly SkeletonType _type;
        private readonly BonePose[] _poseBuffer;
        private readonly Dictionary<string, int> _bufferIndex = new();

        // Cycle duration in seconds for each animation type
        public static float GetCycleDuration(AnimationType anim) => anim switch
        {
            AnimationType.Idle => 3.0f,
            AnimationType.Walk => 1.0f,
            AnimationType.Run => 0.6f,
            AnimationType.TailWag => 0.8f,
            AnimationType.Wave => 1.5f,
            _ => 1.0f
        };

        public ProceduralAnimator(SkeletonType type)
        {
            _type = type;
            var bones = GetAnimatedBones(type);
            _poseBuffer = new BonePose[bones.Length];
            for (int i = 0; i < bones.Length; i++)
            {
                _poseBuffer[i].BoneName = bones[i];
                _bufferIndex[bones[i]] = i;
            }
        }

        /// <summary>
        /// Computes bone poses for the given animation at the specified time.
        /// Returns a read-only span of BonePose structs (zero allocation after init).
        /// </summary>
        public ReadOnlySpan<BonePose> GetPoses(AnimationType anim, float time, float speed = 1.0f)
        {
            float t = time * speed;
            float cycle = GetCycleDuration(anim);
            float phase = (t % cycle) / cycle * Mathf.Tau;

            // Reset all to identity
            for (int i = 0; i < _poseBuffer.Length; i++)
            {
                _poseBuffer[i].Rotation = Quaternion.Identity;
                _poseBuffer[i].PositionOffset = null;
            }

            switch (_type)
            {
                case SkeletonType.Creature:
                    ApplyCreatureAnim(anim, phase);
                    break;
                case SkeletonType.Humanoid:
                    ApplyHumanoidAnim(anim, phase);
                    break;
            }

            return _poseBuffer.AsSpan();
        }

        /// <summary>
        /// Returns bone names that this animator will drive.
        /// </summary>
        public static string[] GetAnimatedBones(SkeletonType type) => type switch
        {
            SkeletonType.Creature => new[]
            {
                "hips", "spine", "chest", "neck", "head",
                "tail_base", "tail_mid", "tail_tip",
                "left_front_leg", "right_front_leg",
                "left_back_leg", "right_back_leg"
            },
            SkeletonType.Humanoid => new[]
            {
                "hips", "spine", "chest", "neck", "head",
                "left_upper_arm", "right_upper_arm",
                "left_lower_arm", "right_lower_arm",
                "left_upper_leg", "right_upper_leg",
                "left_lower_leg", "right_lower_leg"
            },
            _ => Array.Empty<string>()
        };

        #region Creature Animations

        private void ApplyCreatureAnim(AnimationType anim, float phase)
        {
            switch (anim)
            {
                case AnimationType.Idle:
                    ApplyCreatureIdle(phase);
                    break;
                case AnimationType.Walk:
                    ApplyCreatureWalk(phase, 1.0f);
                    break;
                case AnimationType.Run:
                    ApplyCreatureWalk(phase, 1.6f);
                    break;
                case AnimationType.TailWag:
                    ApplyCreatureTailWag(phase);
                    break;
            }
        }

        private void ApplyCreatureIdle(float phase)
        {
            // Breathing: very subtle spine expansion
            float breath = Mathf.Sin(phase) * 0.008f;
            SetRotation("spine", new Vector3(breath, 0, 0));

            // Weight shift: barely perceptible lateral sway
            float sway = Mathf.Sin(phase * 0.5f) * 0.005f;
            SetRotation("hips", new Vector3(0, 0, sway));

            // Subtle tail sway
            float tailSway = Mathf.Sin(phase * 0.6f) * 0.025f;
            SetRotation("tail_base", new Vector3(0, tailSway, 0));
            SetRotation("tail_mid", new Vector3(0, tailSway * 1.2f, 0));
            SetRotation("tail_tip", new Vector3(0, tailSway * 1.5f, 0));
        }

        private void ApplyCreatureWalk(float phase, float amplitude)
        {
            // Only animate legs and hips — torso/head/tail stay still to avoid
            // weight-tearing artifacts on auto-weighted meshes.
            float legSwing = amplitude * 0.18f;

            // Diagonal gait: LF+RB in phase, RF+LB opposite
            float lfPhase = Mathf.Sin(phase);
            float rfPhase = Mathf.Sin(phase + Mathf.Pi);

            SetRotation("left_front_leg", new Vector3(lfPhase * legSwing, 0, 0));
            SetRotation("right_front_leg", new Vector3(rfPhase * legSwing, 0, 0));
            SetRotation("left_back_leg", new Vector3(-lfPhase * legSwing * 0.8f, 0, 0));
            SetRotation("right_back_leg", new Vector3(-rfPhase * legSwing * 0.8f, 0, 0));

            // Hips bounce (vertical translation, double frequency)
            float bounce = Mathf.Abs(Mathf.Sin(phase)) * 0.005f * amplitude;
            SetPositionOffset("hips", new Vector3(0, bounce, 0));
        }

        private void ApplyCreatureTailWag(float phase)
        {
            // Tail wag — tail chain is safe for larger motion
            float wag = Mathf.Sin(phase) * 0.10f;
            SetRotation("tail_base", new Vector3(0, wag, 0));
            SetRotation("tail_mid", new Vector3(0, wag * 1.5f, 0));
            SetRotation("tail_tip", new Vector3(0, wag * 2.0f, 0));

            // Slight hip wiggle
            SetRotation("hips", new Vector3(0, 0, Mathf.Sin(phase) * 0.015f));
        }

        #endregion

        #region Humanoid Animations

        private void ApplyHumanoidAnim(AnimationType anim, float phase)
        {
            switch (anim)
            {
                case AnimationType.Idle:
                    ApplyHumanoidIdle(phase);
                    break;
                case AnimationType.Walk:
                    ApplyHumanoidWalk(phase, 1.0f);
                    break;
                case AnimationType.Run:
                    ApplyHumanoidWalk(phase, 1.5f);
                    break;
                case AnimationType.Wave:
                    ApplyHumanoidWave(phase);
                    break;
            }
        }

        private void ApplyHumanoidIdle(float phase)
        {
            // Breathing: very subtle
            float breath = Mathf.Sin(phase) * 0.008f;
            SetRotation("spine", new Vector3(breath, 0, 0));

            // Weight shift
            float shift = Mathf.Sin(phase * 0.5f) * 0.005f;
            SetRotation("hips", new Vector3(0, 0, shift));
        }

        private void ApplyHumanoidWalk(float phase, float amplitude)
        {
            float legSwing = amplitude * 0.20f;
            float armSwing = amplitude * 0.12f;

            float leftPhase = Mathf.Sin(phase);
            float rightPhase = Mathf.Sin(phase + Mathf.Pi);

            // Legs swing on X (forward/back)
            SetRotation("left_upper_leg", new Vector3(leftPhase * legSwing, 0, 0));
            SetRotation("right_upper_leg", new Vector3(rightPhase * legSwing, 0, 0));

            // Lower legs bend forward slightly when upper swings back
            float lKneeBend = Mathf.Max(0, -leftPhase) * legSwing * 0.4f;
            float rKneeBend = Mathf.Max(0, -rightPhase) * legSwing * 0.4f;
            SetRotation("left_lower_leg", new Vector3(lKneeBend, 0, 0));
            SetRotation("right_lower_leg", new Vector3(rKneeBend, 0, 0));

            // Arms swing opposite to legs
            SetRotation("left_upper_arm", new Vector3(-leftPhase * armSwing, 0, 0));
            SetRotation("right_upper_arm", new Vector3(-rightPhase * armSwing, 0, 0));

            // Spine: very subtle to avoid tearing
            float spineRot = Mathf.Sin(phase) * 0.01f * amplitude;
            SetRotation("spine", new Vector3(0, spineRot, 0));

            // Hips bounce
            float bounce = Mathf.Abs(Mathf.Sin(phase)) * 0.004f * amplitude;
            SetPositionOffset("hips", new Vector3(0, bounce, 0));
        }

        private void ApplyHumanoidWave(float phase)
        {
            // Right arm waves — limb bones are safe for larger motion
            SetRotation("right_upper_arm", new Vector3(0, 0, -0.8f));
            float waveAngle = Mathf.Sin(phase) * 0.2f;
            SetRotation("right_lower_arm", new Vector3(waveAngle, 0, 0));
        }

        #endregion

        #region Helpers

        private void SetRotation(string bone, Vector3 euler)
        {
            if (_bufferIndex.TryGetValue(bone, out int idx))
            {
                _poseBuffer[idx].Rotation = Quaternion.FromEuler(euler);
            }
        }

        private void SetPositionOffset(string bone, Vector3 offset)
        {
            if (_bufferIndex.TryGetValue(bone, out int idx))
            {
                _poseBuffer[idx].PositionOffset = offset;
            }
        }

        #endregion
    }
}
