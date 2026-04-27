using System;
using System.Collections.Generic;

namespace TeaLeaves.UI
{
    public static class AssetMetaHelper
    {
        public static string FormatFileSize(long bytes)
        {
            if (bytes < 1024) return $"{bytes} B";
            if (bytes < 1024 * 1024) return $"{bytes / 1024.0:F1} KB";
            if (bytes < 1024L * 1024 * 1024) return $"{bytes / (1024.0 * 1024.0):F1} MB";
            return $"{bytes / (1024.0 * 1024.0 * 1024.0):F1} GB";
        }

        public static Dictionary<string, string> ParseImportMeta(string[] lines)
        {
            var meta = new Dictionary<string, string>();
            bool inParams = false;

            foreach (var line in lines)
            {
                var trimmed = line.Trim();
                if (trimmed == "[params]")
                {
                    inParams = true;
                    continue;
                }
                if (trimmed.StartsWith("[") && trimmed != "[params]")
                {
                    inParams = false;
                    continue;
                }
                if (inParams && trimmed.Contains('='))
                {
                    var eqIdx = trimmed.IndexOf('=');
                    var key = trimmed[..eqIdx].Trim();
                    var value = trimmed[(eqIdx + 1)..].Trim().Trim('"');
                    meta[key] = value;
                }
            }

            return meta;
        }
    }
}
