using System;
using System.Collections.Generic;
using GdUnit4;
using static GdUnit4.Assertions;
using TeaLeaves.UI;

[TestSuite]
public class AssetMetaTests
{
    [TestCase]
    public void FormatFileSize_Bytes()
    {
        var result = AssetMetaHelper.FormatFileSize(500);
        AssertString(result).IsEqual("500 B");
    }

    [TestCase]
    public void FormatFileSize_Kilobytes()
    {
        var result = AssetMetaHelper.FormatFileSize(2048);
        AssertString(result).IsEqual("2.0 KB");
    }

    [TestCase]
    public void FormatFileSize_Megabytes()
    {
        var result = AssetMetaHelper.FormatFileSize(5242880);
        AssertString(result).IsEqual("5.0 MB");
    }

    [TestCase]
    public void ParseImportFile_ExtractsKeyValues()
    {
        var lines = new string[]
        {
            "[remap]",
            "importer=\"texture\"",
            "type=\"CompressedTexture2D\"",
            "",
            "[params]",
            "compress/mode=2",
            "mipmaps/generate=false"
        };

        var meta = AssetMetaHelper.ParseImportMeta(lines);
        AssertString(meta["compress/mode"]).IsEqual("2");
        AssertString(meta["mipmaps/generate"]).IsEqual("false");
    }

    [TestCase]
    public void ParseImportFile_EmptyInput_ReturnsEmpty()
    {
        var meta = AssetMetaHelper.ParseImportMeta(Array.Empty<string>());
        AssertInt(meta.Count).IsEqual(0);
    }
}
