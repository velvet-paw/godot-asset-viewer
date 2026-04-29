using GdUnit4;
using Godot;
using static GdUnit4.Assertions;
using TeaLeaves.UI;

[TestSuite]
public class AnimationExporterTests
{
    [TestCase]
    public void Export_CreatureWalk_CreatesAnimation()
    {
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Walk);
        AssertBool(anim != null).IsTrue();
        AssertBool(anim!.Length > 0).IsTrue();
        AssertObject(anim.LoopMode).IsEqual(Animation.LoopModeEnum.Linear);
    }

    [TestCase]
    public void Export_CreatureWalk_HasRotationTracks()
    {
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Walk);
        // Should have rotation tracks for all 12 creature bones
        int rotTracks = 0;
        for (int i = 0; i < anim.GetTrackCount(); i++)
        {
            if (anim.TrackGetType(i) == Animation.TrackType.Rotation3D)
                rotTracks++;
        }
        AssertInt(rotTracks).IsEqual(12);
    }

    [TestCase]
    public void Export_CreatureWalk_HasPositionTrackForHips()
    {
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Walk);
        int posTracks = 0;
        for (int i = 0; i < anim.GetTrackCount(); i++)
        {
            if (anim.TrackGetType(i) == Animation.TrackType.Position3D)
                posTracks++;
        }
        // Walk has hips bounce position offset
        AssertBool(posTracks >= 1).IsTrue();
    }

    [TestCase]
    public void Export_HumanoidIdle_CreatesAnimation()
    {
        var anim = AnimationExporter.Export(SkeletonType.Humanoid, AnimationType.Idle);
        AssertBool(anim != null).IsTrue();
        AssertBool(anim!.Length > 0).IsTrue();
    }

    [TestCase]
    public void Export_DurationMatchesCycle()
    {
        float expectedDuration = ProceduralAnimator.GetCycleDuration(AnimationType.Walk);
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Walk);
        AssertFloat(anim.Length).IsEqual(expectedDuration);
    }

    [TestCase]
    public void Export_TrackPathsContainSkeletonPath()
    {
        string skelPath = "Armature/Skeleton3D";
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Idle, skelPath);

        for (int i = 0; i < anim.GetTrackCount(); i++)
        {
            string path = anim.TrackGetPath(i);
            AssertBool(path.StartsWith(skelPath + ":")).IsTrue();
        }
    }

    [TestCase]
    public void Export_HasKeyframes()
    {
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Walk);
        // At 30 fps for 1.0s cycle = 30 samples + 1 = 31 keyframes
        for (int i = 0; i < anim.GetTrackCount(); i++)
        {
            if (anim.TrackGetType(i) == Animation.TrackType.Rotation3D)
            {
                AssertBool(anim.TrackGetKeyCount(i) > 20).IsTrue();
                break;
            }
        }
    }

    [TestCase]
    public void Export_CreatureIdle_NoPositionTracks()
    {
        var anim = AnimationExporter.Export(SkeletonType.Creature, AnimationType.Idle);
        int posTracks = 0;
        for (int i = 0; i < anim.GetTrackCount(); i++)
        {
            if (anim.TrackGetType(i) == Animation.TrackType.Position3D)
                posTracks++;
        }
        // Idle has no position offsets
        AssertInt(posTracks).IsEqual(0);
    }
}
