using System.Collections.Generic;
using System.Linq;

namespace TeaLeaves.UI
{
    public static class AssetTypeHelper
    {
        private static readonly Dictionary<string, string> ExtensionMap = new()
        {
            [".png"] = "texture", [".jpg"] = "texture", [".jpeg"] = "texture",
            [".webp"] = "texture", [".svg"] = "texture", [".bmp"] = "texture", [".tga"] = "texture",
            [".glb"] = "mesh", [".gltf"] = "mesh", [".obj"] = "mesh", [".fbx"] = "mesh",
            [".wav"] = "audio", [".ogg"] = "audio", [".mp3"] = "audio",
            [".gdshader"] = "shader",
            [".tscn"] = "scene", [".scn"] = "scene",
        };

        public static string ClassifyByExtension(string extension)
        {
            return ExtensionMap.TryGetValue(extension.ToLowerInvariant(), out var type) ? type : "";
        }

        public static List<AssetEntry> FilterAssets(List<AssetEntry> assets, string search, string typeFilter)
        {
            var query = assets.AsEnumerable();

            if (!string.IsNullOrWhiteSpace(search))
            {
                var searchLower = search.ToLowerInvariant();
                query = query.Where(a => a.Path.ToLowerInvariant().Contains(searchLower));
            }

            if (!string.IsNullOrWhiteSpace(typeFilter) && typeFilter.ToLowerInvariant() != "all")
            {
                var filterLower = typeFilter.ToLowerInvariant();
                query = query.Where(a => a.TypeLabel.ToLowerInvariant() == filterLower);
            }

            return query.ToList();
        }
    }
}
