using GdUnit4;
using Godot;
using static GdUnit4.Assertions;
using TeaLeaves.UI;
using System;

[TestSuite]
public class ProceduralAnimatorTests
{
    [TestCase]
    public void CreatureAnimator_WalkPoses_ReturnsAllBones()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);
        var poses = animator.GetPoses(AnimationType.Walk, 0.5f);
        AssertInt(poses.Length).IsEqual(12);
    }

    [TestCase]
    public void HumanoidAnimator_WalkPoses_ReturnsAllBones()
    {
        var animator = new ProceduralAnimator(SkeletonType.Humanoid);
        var poses = animator.GetPoses(AnimationType.Walk, 0.5f);
        AssertInt(poses.Length).IsEqual(13);
    }

    [TestCase]
    public void CreatureWalk_LegsAreOppositePhase()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);
        var poses = animator.GetPoses(AnimationType.Walk, 0.25f);

        Quaternion? leftFront = null, rightFront = null;
        foreach (var pose in poses)
        {
            if (pose.BoneName == "left_front_leg") leftFront = pose.Rotation;
            if (pose.BoneName == "right_front_leg") rightFront = pose.Rotation;
        }

        AssertBool(leftFront.HasValue).IsTrue();
        AssertBool(rightFront.HasValue).IsTrue();

        // At any non-zero time, diagonal legs should rotate differently
        var lf = leftFront!.Value.GetEuler();
        var rf = rightFront!.Value.GetEuler();
        // They swing in opposite directions on X axis
        AssertBool(Math.Sign(lf.X) != Math.Sign(rf.X) || (lf.X == 0 && rf.X == 0)).IsTrue();
    }

    [TestCase]
    public void HumanoidWalk_ArmsOppositeToLegs()
    {
        var animator = new ProceduralAnimator(SkeletonType.Humanoid);
        // At t=0.25 in a 1s cycle, phase = pi/2. sin(pi/2)=1, sin(pi/2+pi)=-1
        var poses = animator.GetPoses(AnimationType.Walk, 0.25f);

        Quaternion? leftArm = null, leftLeg = null;
        foreach (var pose in poses)
        {
            if (pose.BoneName == "left_upper_arm") leftArm = pose.Rotation;
            if (pose.BoneName == "left_upper_leg") leftLeg = pose.Rotation;
        }

        AssertBool(leftArm.HasValue).IsTrue();
        AssertBool(leftLeg.HasValue).IsTrue();

        // Arm should swing opposite to leg on X
        var armEuler = leftArm!.Value.GetEuler();
        var legEuler = leftLeg!.Value.GetEuler();
        AssertBool(Math.Sign(armEuler.X) != Math.Sign(legEuler.X) || armEuler.X == 0).IsTrue();
    }

    [TestCase]
    public void IdlePoses_AreSubtle()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);
        var poses = animator.GetPoses(AnimationType.Idle, 0.5f);

        foreach (var pose in poses)
        {
            var euler = pose.Rotation.GetEuler();
            // Idle rotations should be small (< 5 degrees = ~0.087 rad)
            AssertBool(Math.Abs(euler.X) < 0.1f).IsTrue();
            AssertBool(Math.Abs(euler.Y) < 0.1f).IsTrue();
            AssertBool(Math.Abs(euler.Z) < 0.1f).IsTrue();
        }
    }

    [TestCase]
    public void RunAmplitude_GreaterThanWalk()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);

        // Sample across the full cycle and find peak amplitude for each
        float walkMax = 0, runMax = 0;
        for (int s = 0; s < 30; s++)
        {
            float t = s / 30.0f;

            var walkPoses = animator.GetPoses(AnimationType.Walk, t);
            foreach (var pose in walkPoses)
            {
                var e = pose.Rotation.GetEuler();
                walkMax = Math.Max(walkMax, Math.Max(Math.Abs(e.X), Math.Max(Math.Abs(e.Y), Math.Abs(e.Z))));
            }

            var runPoses = animator.GetPoses(AnimationType.Run, t);
            foreach (var pose in runPoses)
            {
                var e = pose.Rotation.GetEuler();
                runMax = Math.Max(runMax, Math.Max(Math.Abs(e.X), Math.Max(Math.Abs(e.Y), Math.Abs(e.Z))));
            }
        }

        AssertBool(runMax > walkMax).IsTrue();
    }

    [TestCase]
    public void WalkCycle_HipsBounce_HasPositionOffset()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);
        var poses = animator.GetPoses(AnimationType.Walk, 0.25f);

        bool hipsHasOffset = false;
        foreach (var pose in poses)
        {
            if (pose.BoneName == "hips" && pose.PositionOffset.HasValue)
            {
                hipsHasOffset = true;
                AssertBool(pose.PositionOffset!.Value.Y >= 0).IsTrue();
            }
        }
        AssertBool(hipsHasOffset).IsTrue();
    }

    [TestCase]
    public void TailWag_OnlyAffectsTailAndHips()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);
        var poses = animator.GetPoses(AnimationType.TailWag, 0.2f);

        foreach (var pose in poses)
        {
            if (!pose.BoneName.StartsWith("tail") && pose.BoneName != "hips")
            {
                AssertObject(pose.Rotation).IsEqual(Quaternion.Identity);
            }
        }
    }

    [TestCase]
    public void GetCycleDuration_WalkIsShorterThanIdle()
    {
        float walk = ProceduralAnimator.GetCycleDuration(AnimationType.Walk);
        float idle = ProceduralAnimator.GetCycleDuration(AnimationType.Idle);
        AssertBool(walk < idle).IsTrue();
    }

    [TestCase]
    public void GetCycleDuration_RunIsShorterThanWalk()
    {
        float run = ProceduralAnimator.GetCycleDuration(AnimationType.Run);
        float walk = ProceduralAnimator.GetCycleDuration(AnimationType.Walk);
        AssertBool(run < walk).IsTrue();
    }

    [TestCase]
    public void Speed_ScalesAnimation()
    {
        var animator = new ProceduralAnimator(SkeletonType.Creature);
        // At speed 2x, poses at t=0.5 should match speed 1x at t=1.0
        var fastPoses = animator.GetPoses(AnimationType.Walk, 0.5f, 2.0f);
        var normalPoses = animator.GetPoses(AnimationType.Walk, 1.0f, 1.0f);

        // Both should produce same poses since 0.5*2 == 1.0*1
        for (int i = 0; i < fastPoses.Length; i++)
        {
            var diff = (fastPoses[i].Rotation * normalPoses[i].Rotation.Inverse()).GetEuler();
            AssertBool(diff.Length() < 0.001f).IsTrue();
        }
    }

    [TestCase]
    public void UnknownSkeleton_ReturnsEmptyPoses()
    {
        var animator = new ProceduralAnimator(SkeletonType.Unknown);
        var poses = animator.GetPoses(AnimationType.Walk, 0.5f);
        AssertInt(poses.Length).IsEqual(0);
    }

    [TestCase]
    public void GetAnimatedBones_Creature_Returns12()
    {
        var bones = ProceduralAnimator.GetAnimatedBones(SkeletonType.Creature);
        AssertInt(bones.Length).IsEqual(12);
    }

    [TestCase]
    public void GetAnimatedBones_Humanoid_Returns13()
    {
        var bones = ProceduralAnimator.GetAnimatedBones(SkeletonType.Humanoid);
        AssertInt(bones.Length).IsEqual(13);
    }
}
