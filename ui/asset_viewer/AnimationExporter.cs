using Godot;
using System.Collections.Generic;

namespace TeaLeaves.UI
{
    /// <summary>
    /// Exports procedural animations to Godot Animation resources.
    /// Samples the ProceduralAnimator at regular intervals and builds
    /// rotation/position tracks for each bone.
    /// </summary>
    public static class AnimationExporter
    {
        private const int SamplesPerSecond = 30;

        /// <summary>
        /// Creates a Godot Animation resource by sampling the procedural animator.
        /// The animation loops and covers one full cycle.
        /// </summary>
        public static Animation Export(
            SkeletonType skeletonType,
            AnimationType animType,
            string skeletonNodePath = "Armature/Skeleton3D")
        {
            var animator = new ProceduralAnimator(skeletonType);
            float cycleDuration = ProceduralAnimator.GetCycleDuration(animType);
            int sampleCount = (int)(cycleDuration * SamplesPerSecond);
            float dt = cycleDuration / sampleCount;

            var animation = new Animation();
            animation.Length = cycleDuration;
            animation.LoopMode = Animation.LoopModeEnum.Linear;

            // Track indices per bone (rotation track, optional position track)
            var rotationTracks = new Dictionary<string, int>();
            var positionTracks = new Dictionary<string, int>();

            // First pass: determine which bones need tracks
            var bones = ProceduralAnimator.GetAnimatedBones(skeletonType);
            foreach (string bone in bones)
            {
                int rotTrack = animation.AddTrack(Animation.TrackType.Rotation3D);
                animation.TrackSetPath(rotTrack, $"{skeletonNodePath}:{bone}");
                animation.TrackSetInterpolationType(rotTrack, Animation.InterpolationType.Linear);
                rotationTracks[bone] = rotTrack;
            }

            // Sample the animation and check if any bone uses position offsets
            bool needsPositionTracks = false;
            for (int s = 0; s <= sampleCount; s++)
            {
                float t = s * dt;
                var poses = animator.GetPoses(animType, t, 1.0f);
                foreach (var pose in poses)
                {
                    if (pose.PositionOffset.HasValue)
                    {
                        needsPositionTracks = true;
                        if (!positionTracks.ContainsKey(pose.BoneName))
                        {
                            int posTrack = animation.AddTrack(Animation.TrackType.Position3D);
                            animation.TrackSetPath(posTrack, $"{skeletonNodePath}:{pose.BoneName}");
                            animation.TrackSetInterpolationType(posTrack, Animation.InterpolationType.Linear);
                            positionTracks[pose.BoneName] = posTrack;
                        }
                    }
                }
                if (needsPositionTracks) break;
            }

            // Second pass: insert all keyframes
            for (int s = 0; s <= sampleCount; s++)
            {
                float t = s * dt;
                var poses = animator.GetPoses(animType, t, 1.0f);

                foreach (var pose in poses)
                {
                    if (rotationTracks.TryGetValue(pose.BoneName, out int rotTrack))
                    {
                        animation.RotationTrackInsertKey(rotTrack, t, pose.Rotation);
                    }

                    if (pose.PositionOffset.HasValue &&
                        positionTracks.TryGetValue(pose.BoneName, out int posTrack))
                    {
                        animation.PositionTrackInsertKey(posTrack, t, pose.PositionOffset.Value);
                    }
                }
            }

            return animation;
        }

        /// <summary>
        /// Exports and saves an animation to a .tres file.
        /// </summary>
        public static Error SaveToFile(
            SkeletonType skeletonType,
            AnimationType animType,
            string filePath,
            string skeletonNodePath = "Armature/Skeleton3D")
        {
            var animation = Export(skeletonType, animType, skeletonNodePath);
            animation.ResourceName = $"{skeletonType}_{animType}".ToLowerInvariant();
            return ResourceSaver.Save(animation, filePath);
        }
    }
}
