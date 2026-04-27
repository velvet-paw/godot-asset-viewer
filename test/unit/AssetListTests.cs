using GdUnit4;
using static GdUnit4.Assertions;
using TeaLeaves.UI;

[TestSuite]
public class AssetListTests
{
    [TestCase]
    public void ClassifyExtension_Png_ReturnsTexture()
    {
        var result = AssetTypeHelper.ClassifyByExtension(".png");
        AssertString(result).IsEqual("texture");
    }

    [TestCase]
    public void ClassifyExtension_Glb_ReturnsMesh()
    {
        var result = AssetTypeHelper.ClassifyByExtension(".glb");
        AssertString(result).IsEqual("mesh");
    }

    [TestCase]
    public void ClassifyExtension_Wav_ReturnsAudio()
    {
        var result = AssetTypeHelper.ClassifyByExtension(".wav");
        AssertString(result).IsEqual("audio");
    }

    [TestCase]
    public void ClassifyExtension_GdShader_ReturnsShader()
    {
        var result = AssetTypeHelper.ClassifyByExtension(".gdshader");
        AssertString(result).IsEqual("shader");
    }

    [TestCase]
    public void ClassifyExtension_Tscn_ReturnsScene()
    {
        var result = AssetTypeHelper.ClassifyByExtension(".tscn");
        AssertString(result).IsEqual("scene");
    }

    [TestCase]
    public void ClassifyExtension_Unknown_ReturnsEmpty()
    {
        var result = AssetTypeHelper.ClassifyByExtension(".xyz");
        AssertString(result).IsEqual("");
    }

    [TestCase]
    public void FilterBySearch_MatchesSubstring()
    {
        var assets = new List<AssetEntry>
        {
            new() { Path = "res://actors/enemy/sprite.png", TypeLabel = "texture" },
            new() { Path = "res://actors/player/mesh.glb", TypeLabel = "mesh" },
            new() { Path = "res://ui/button.png", TypeLabel = "texture" },
        };

        var result = AssetTypeHelper.FilterAssets(assets, "enemy", "all");
        AssertInt(result.Count).IsEqual(1);
        AssertString(result[0].Path).Contains("enemy");
    }

    [TestCase]
    public void FilterByType_ReturnsOnlyMatchingType()
    {
        var assets = new List<AssetEntry>
        {
            new() { Path = "res://actors/enemy/sprite.png", TypeLabel = "texture" },
            new() { Path = "res://actors/player/mesh.glb", TypeLabel = "mesh" },
            new() { Path = "res://ui/button.png", TypeLabel = "texture" },
        };

        var result = AssetTypeHelper.FilterAssets(assets, "", "texture");
        AssertInt(result.Count).IsEqual(2);
    }

    [TestCase]
    public void FilterCombined_SearchAndType()
    {
        var assets = new List<AssetEntry>
        {
            new() { Path = "res://actors/enemy/sprite.png", TypeLabel = "texture" },
            new() { Path = "res://actors/enemy/mesh.glb", TypeLabel = "mesh" },
            new() { Path = "res://ui/button.png", TypeLabel = "texture" },
        };

        var result = AssetTypeHelper.FilterAssets(assets, "enemy", "texture");
        AssertInt(result.Count).IsEqual(1);
        AssertString(result[0].Path).Contains("enemy/sprite");
    }
}
