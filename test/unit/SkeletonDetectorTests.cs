using GdUnit4;
using Godot;
using static GdUnit4.Assertions;
using TeaLeaves.UI;
using System.Collections.Generic;

[TestSuite]
public class SkeletonDetectorTests
{
    private static readonly List<string> CreatureBones = new()
    {
        "hips", "spine", "chest", "neck", "head",
        "tail_base", "tail_mid", "tail_tip",
        "left_front_leg", "right_front_leg",
        "left_back_leg", "right_back_leg"
    };

    private static readonly List<string> HumanoidBones = new()
    {
        "hips", "spine", "chest", "neck", "head",
        "left_shoulder", "left_upper_arm", "left_lower_arm", "left_hand",
        "right_shoulder", "right_upper_arm", "right_lower_arm", "right_hand",
        "left_upper_leg", "left_lower_leg", "left_foot", "left_toe",
        "right_upper_leg", "right_lower_leg", "right_foot", "right_toe"
    };

    [TestCase]
    public void Detect_CreatureSkeleton()
    {
        var result = SkeletonDetector.Detect(CreatureBones);
        AssertObject(result.Type).IsEqual(SkeletonType.Creature);
    }

    [TestCase]
    public void Detect_HumanoidSkeleton()
    {
        var result = SkeletonDetector.Detect(HumanoidBones);
        AssertObject(result.Type).IsEqual(SkeletonType.Humanoid);
    }

    [TestCase]
    public void Detect_UnknownSkeleton_EmptyList()
    {
        var result = SkeletonDetector.Detect(new List<string>());
        AssertObject(result.Type).IsEqual(SkeletonType.Unknown);
    }

    [TestCase]
    public void Detect_UnknownSkeleton_RandomBones()
    {
        var result = SkeletonDetector.Detect(new List<string> { "bone1", "bone2", "bone3" });
        AssertObject(result.Type).IsEqual(SkeletonType.Unknown);
    }

    [TestCase]
    public void Detect_CreatureBoneMap_HasAllExpected()
    {
        var result = SkeletonDetector.Detect(CreatureBones);
        AssertInt(result.BoneMap.Count).IsEqual(12);
        AssertInt(result.GetBoneIndex("hips")).IsEqual(0);
        AssertInt(result.GetBoneIndex("left_front_leg")).IsEqual(8);
    }

    [TestCase]
    public void Detect_HumanoidBoneMap_HasAllExpected()
    {
        var result = SkeletonDetector.Detect(HumanoidBones);
        AssertInt(result.BoneMap.Count).IsEqual(21);
        AssertInt(result.GetBoneIndex("hips")).IsEqual(0);
        AssertInt(result.GetBoneIndex("left_upper_arm")).IsEqual(6);
    }

    [TestCase]
    public void GetBoneIndex_MissingBone_ReturnsNegative()
    {
        var result = SkeletonDetector.Detect(CreatureBones);
        AssertInt(result.GetBoneIndex("nonexistent")).IsEqual(-1);
    }

    [TestCase]
    public void GetAvailableAnimations_Creature()
    {
        var result = SkeletonDetector.Detect(CreatureBones);
        var anims = result.GetAvailableAnimations();
        AssertInt(anims.Length).IsEqual(4);
        AssertObject(anims[0]).IsEqual(AnimationType.Idle);
        AssertObject(anims[1]).IsEqual(AnimationType.Walk);
        AssertObject(anims[2]).IsEqual(AnimationType.Run);
        AssertObject(anims[3]).IsEqual(AnimationType.TailWag);
    }

    [TestCase]
    public void GetAvailableAnimations_Humanoid()
    {
        var result = SkeletonDetector.Detect(HumanoidBones);
        var anims = result.GetAvailableAnimations();
        AssertInt(anims.Length).IsEqual(4);
        AssertObject(anims[0]).IsEqual(AnimationType.Idle);
        AssertObject(anims[3]).IsEqual(AnimationType.Wave);
    }

    [TestCase]
    public void GetAvailableAnimations_Unknown_Empty()
    {
        var result = SkeletonDetector.Detect(new List<string>());
        var anims = result.GetAvailableAnimations();
        AssertInt(anims.Length).IsEqual(0);
    }

    [TestCase]
    public void Detect_NormalizesBoneNames_CaseInsensitive()
    {
        var mixedCase = new List<string>
        {
            "Hips", "SPINE", "Chest", "Neck", "Head",
            "Tail_Base", "Tail_Mid", "Tail_Tip",
            "Left_Front_Leg", "Right_Front_Leg",
            "Left_Back_Leg", "Right_Back_Leg"
        };
        var result = SkeletonDetector.Detect(mixedCase);
        AssertObject(result.Type).IsEqual(SkeletonType.Creature);
    }

    [TestCase]
    public void Detect_NormalizesBoneNames_Hyphens()
    {
        var hyphenated = new List<string>
        {
            "hips", "spine", "chest", "neck", "head",
            "tail-base", "tail-mid", "tail-tip",
            "left-front-leg", "right-front-leg",
            "left-back-leg", "right-back-leg"
        };
        var result = SkeletonDetector.Detect(hyphenated);
        AssertObject(result.Type).IsEqual(SkeletonType.Creature);
    }
}
