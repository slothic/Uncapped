using System.Text;
using System.Text.RegularExpressions;

namespace Uncapped.Services;

/// <summary>
/// Reads and writes individual settings in WTF\Config.wtf.
///
/// Always edits line-by-line rather than rewriting the file. Config.wtf holds the player's
/// resolution, volumes, account name and much else; clobbering it wholesale would reset their
/// settings every launch.
/// </summary>
public static class ConfigWtf
{
    public static string PathFor(string installPath) =>
        Path.Combine(installPath, "WTF", "Config.wtf");

    public static bool Exists(string installPath) => File.Exists(PathFor(installPath));

    /// <summary>
    /// Applies the given SET values. Returns true if the file changed.
    /// When <paramref name="createIfMissing"/> is false and the file does not exist, this is
    /// a no-op — the client writes Config.wtf itself on first run, and inventing one before
    /// then risks fighting it.
    /// </summary>
    public static bool Update(
        string installPath,
        IReadOnlyDictionary<string, string> values,
        bool createIfMissing = false)
    {
        var path = PathFor(installPath);

        if (!File.Exists(path))
        {
            if (!createIfMissing) return false;

            var dir = Path.GetDirectoryName(path);
            if (dir is not null) Directory.CreateDirectory(dir);
            File.WriteAllText(path, "", new UTF8Encoding(false));
        }

        var lines = File.ReadAllLines(path).ToList();
        var changed = false;

        foreach (var (key, value) in values)
            changed |= SetLine(lines, key, value);

        if (changed) File.WriteAllLines(path, lines, new UTF8Encoding(false));
        return changed;
    }

    public static string? Read(string installPath, string key)
    {
        var path = PathFor(installPath);
        if (!File.Exists(path)) return null;

        var rx = new Regex($@"^\s*SET\s+{Regex.Escape(key)}\s+""?([^""]*)""?\s*$", RegexOptions.IgnoreCase);
        foreach (var line in File.ReadAllLines(path))
        {
            var m = rx.Match(line);
            if (m.Success) return m.Groups[1].Value;
        }
        return null;
    }

    private static bool SetLine(List<string> lines, string key, string value)
    {
        var wanted = $"SET {key} \"{value}\"";
        var rx = new Regex($@"^\s*SET\s+{Regex.Escape(key)}\s+", RegexOptions.IgnoreCase);

        for (var i = 0; i < lines.Count; i++)
        {
            if (!rx.IsMatch(lines[i])) continue;
            if (lines[i].Trim() == wanted) return false;
            lines[i] = wanted;
            return true;
        }

        lines.Add(wanted);
        return true;
    }
}
