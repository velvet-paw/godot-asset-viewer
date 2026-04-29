using Godot;
using System.Collections.Generic;

namespace TeaLeaves.UI
{
    /// <summary>
    /// Drives a Skeleton3D with procedural animations.
    /// Add as a child of the scene containing the skeleton.
    /// Finds Skeleton3D in sibling/parent tree automatically.
    /// </summary>
    public partial class AnimationController : Node
    {
        private Skeleton3D? _skeleton;
        private SkeletonDetector? _detector;
        private ProceduralAnimator? _animator;

        private AnimationType _currentAnim = AnimationType.Idle;
        private float _speed = 1.0f;
        private float _time;
        private bool _playing;

        public SkeletonType SkeletonType => _detector?.Type ?? SkeletonType.Unknown;
        public AnimationType CurrentAnimation => _currentAnim;
        public float Speed => _speed;
        public bool IsPlaying => _playing;

        /// <summary>
        /// Initializes the controller with an existing Skeleton3D node.
        /// Call this after adding the controller to the scene tree.
        /// </summary>
        public bool Initialize(Skeleton3D skeleton)
        {
            _skeleton = skeleton;

            var boneNames = new List<string>();
            for (int i = 0; i < skeleton.GetBoneCount(); i++)
            {
                boneNames.Add(skeleton.GetBoneName(i));
            }

            _detector = SkeletonDetector.Detect(boneNames);
            if (_detector.Type == SkeletonType.Unknown)
            {
                GD.PushWarning("AnimationController: Unknown skeleton type, no animations available");
                return false;
            }

            _animator = new ProceduralAnimator(_detector.Type);
            return true;
        }

        /// <summary>
        /// Returns the list of animations available for the detected skeleton.
        /// </summary>
        public AnimationType[] GetAvailableAnimations()
        {
            return _detector?.GetAvailableAnimations() ?? System.Array.Empty<AnimationType>();
        }

        public void Play(AnimationType anim)
        {
            _currentAnim = anim;
            _time = 0;
            _playing = true;
        }

        public void Stop()
        {
            _playing = false;
            _time = 0;
            ResetPoses();
        }

        public void Pause()
        {
            _playing = false;
        }

        public void Resume()
        {
            _playing = true;
        }

        public void SetSpeed(float speed)
        {
            _speed = Mathf.Clamp(speed, 0.1f, 3.0f);
        }

        public override void _Process(double delta)
        {
            if (!_playing || _animator == null || _skeleton == null || _detector == null)
                return;

            _time += (float)delta;

            var poses = _animator.GetPoses(_currentAnim, _time, _speed);
            foreach (var pose in poses)
            {
                int boneIdx = _detector.GetBoneIndex(pose.BoneName);
                if (boneIdx < 0) continue;

                _skeleton.SetBonePoseRotation(boneIdx, pose.Rotation);

                if (pose.PositionOffset.HasValue)
                {
                    var restPos = _skeleton.GetBoneRest(boneIdx).Origin;
                    _skeleton.SetBonePosePosition(boneIdx, restPos + pose.PositionOffset.Value);
                }
            }
        }

        /// <summary>
        /// Resets all animated bones to their rest pose.
        /// </summary>
        public void ResetPoses()
        {
            if (_skeleton == null || _detector == null) return;

            foreach (var kvp in _detector.BoneMap)
            {
                int boneIdx = kvp.Value;
                _skeleton.SetBonePoseRotation(boneIdx, Quaternion.Identity);
                var restPos = _skeleton.GetBoneRest(boneIdx).Origin;
                _skeleton.SetBonePosePosition(boneIdx, restPos);
            }
        }

        public override void _ExitTree()
        {
            ResetPoses();
        }
    }
}
