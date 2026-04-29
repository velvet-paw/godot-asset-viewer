using System.Collections.Generic;
using System.Linq;

namespace TeaLeaves.UI
{
    public enum SkeletonType
    {
        Unknown,
        Creature,
        Humanoid
    }

    public enum AnimationType
    {
        Idle,
        Walk,
        Run,
        TailWag,
        Wave
    }

    /// <summary>
    /// Detects skeleton type from bone names and maps bone roles to indices.
    /// Supports creature (quadruped) and humanoid rigs from the Stage 6 pipeline.
    /// </summary>
    public class SkeletonDetector
    {
        // Creature-required bones (quadruped gait needs all four legs)
        private static readonly string[] CreatureMarkers =
        {
            "left_front_leg", "right_front_leg", "left_back_leg", "right_back_leg"
        };

        // Humanoid-required bones (biped gait needs arms and legs)
        private static readonly string[] HumanoidMarkers =
        {
            "left_upper_arm", "right_upper_arm", "left_upper_leg", "right_upper_leg"
        };

        // All known creature bones from Stage 6 pipeline
        private static readonly string[] CreatureBones =
        {
            "hips", "spine", "chest", "neck", "head",
            "tail_base", "tail_mid", "tail_tip",
            "left_front_leg", "right_front_leg",
            "left_back_leg", "right_back_leg"
        };

        // All known humanoid bones from Stage 6 pipeline
        private static readonly string[] HumanoidBones =
        {
            "hips", "spine", "chest", "neck", "head",
            "left_shoulder", "left_upper_arm", "left_lower_arm", "left_hand",
            "right_shoulder", "right_upper_arm", "right_lower_arm", "right_hand",
            "left_upper_leg", "left_lower_leg", "left_foot", "left_toe",
            "right_upper_leg", "right_lower_leg", "right_foot", "right_toe"
        };

        public SkeletonType Type { get; private set; }
        public Dictionary<string, int> BoneMap { get; private set; } = new();

        /// <summary>
        /// Analyzes bone names and determines skeleton type.
        /// Returns the detected type and populates BoneMap with role→index mappings.
        /// </summary>
        public static SkeletonDetector Detect(IReadOnlyList<string> boneNames)
        {
            var detector = new SkeletonDetector();
            var nameSet = new HashSet<string>(boneNames.Select(NormalizeBoneName));

            // Check creature markers first (more specific than humanoid shared bones)
            bool isCreature = CreatureMarkers.All(m => nameSet.Contains(m));
            bool isHumanoid = HumanoidMarkers.All(m => nameSet.Contains(m));

            if (isCreature)
            {
                detector.Type = SkeletonType.Creature;
                detector.BuildBoneMap(boneNames, CreatureBones);
            }
            else if (isHumanoid)
            {
                detector.Type = SkeletonType.Humanoid;
                detector.BuildBoneMap(boneNames, HumanoidBones);
            }
            else
            {
                detector.Type = SkeletonType.Unknown;
            }

            return detector;
        }

        /// <summary>
        /// Returns animation types available for the detected skeleton type.
        /// </summary>
        public AnimationType[] GetAvailableAnimations()
        {
            return Type switch
            {
                SkeletonType.Creature => new[] { AnimationType.Idle, AnimationType.Walk, AnimationType.Run, AnimationType.TailWag },
                SkeletonType.Humanoid => new[] { AnimationType.Idle, AnimationType.Walk, AnimationType.Run, AnimationType.Wave },
                _ => System.Array.Empty<AnimationType>()
            };
        }

        /// <summary>
        /// Gets the bone index for a known role, or -1 if not found.
        /// </summary>
        public int GetBoneIndex(string role)
        {
            return BoneMap.TryGetValue(role, out int idx) ? idx : -1;
        }

        private void BuildBoneMap(IReadOnlyList<string> boneNames, string[] knownRoles)
        {
            var normalized = new Dictionary<string, int>();
            for (int i = 0; i < boneNames.Count; i++)
            {
                normalized[NormalizeBoneName(boneNames[i])] = i;
            }

            foreach (var role in knownRoles)
            {
                if (normalized.TryGetValue(role, out int idx))
                {
                    BoneMap[role] = idx;
                }
            }
        }

        private static string NormalizeBoneName(string name)
        {
            return name.Trim().ToLowerInvariant().Replace('-', '_').Replace(' ', '_');
        }
    }
}
