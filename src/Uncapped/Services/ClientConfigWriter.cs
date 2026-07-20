using System.Text;
using System.Text.RegularExpressions;

namespace Uncapped.Services;

/// <summary>
/// Points the client at the realm. This is the part players have historically got wrong, and
/// the reason is subtle: editing realmlist.wtf alone is not enough. The client persists
/// SET realmList into WTF\Config.wtf and honours that on many 3.3.5a builds, so a stale
/// Config.wtf silently overrides a correct realmlist.wtf. We write all three locations.
/// </summary>
public static class ClientConfigWriter
{
    public sealed record Result(List<string> Written, List<string> Failed);

    public static Result WriteRealmlist(string installPath, string address, string? realmName)
    {
        var written = new List<string>();
        var failed = new List<string>();
        var line = $"set realmlist {address}";

        // Which of these the client honours varies by build, so write both rather than
        // guess. The root file often does not exist yet on a fresh ChromieCraft client.
        foreach (var rel in new[] { "realmlist.wtf", Path.Combine("Data", "enUS", "realmlist.wtf") })
        {
            var path = Path.Combine(installPath, rel);
            try
            {
                var dir = Path.GetDirectoryName(path);
                if (dir is not null) Directory.CreateDirectory(dir);
                File.WriteAllText(path, line + Environment.NewLine, new UTF8Encoding(false));
                written.Add(rel);
            }
            catch (Exception ex) { failed.Add($"{rel}: {ex.Message}"); }
        }

        try
        {
            if (UpdateConfigWtf(installPath, address, realmName)) written.Add(@"WTF\Config.wtf");
        }
        catch (Exception ex) { failed.Add($@"WTF\Config.wtf: {ex.Message}"); }

        return new Result(written, failed);
    }

    /// <summary>
    /// Rewrites only the realmList (and realmName) lines, preserving every other setting —
    /// resolution, volumes, account name. Clobbering the whole file would reset the player's
    /// graphics settings on every launch.
    /// </summary>
    private static bool UpdateConfigWtf(string installPath, string address, string? realmName)
    {
        var path = Path.Combine(installPath, "WTF", "Config.wtf");
        if (!File.Exists(path)) return false; // client writes it on first run; nothing to fix yet

        var lines = File.ReadAllLines(path).ToList();
        var changed = false;

        changed |= SetLine(lines, "realmList", address);
        if (!string.IsNullOrWhiteSpace(realmName))
            changed |= SetLine(lines, "realmName", realmName!);

        if (changed) File.WriteAllLines(path, lines, new UTF8Encoding(false));
        return changed;
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
