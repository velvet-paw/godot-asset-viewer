using System.Collections.Generic;

namespace TeaLeaves.UI
{
    public class AssetEntry
    {
        public string Path { get; set; } = "";
        public string Type { get; set; } = "";
        public string TypeLabel { get; set; } = "";
        public long SizeBytes { get; set; }
        public string ImportDate { get; set; } = "";
        public Dictionary<string, string> ImportMeta { get; set; } = new();
    }
}
