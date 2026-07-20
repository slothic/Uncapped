namespace Uncapped.Services;

/// <summary>
/// Re-ticks our own addons in the client's addon list.
///
/// 3.3.5a has no .toc flag that makes an addon undisableable — nothing equivalent to a
/// "secure" or "protected" marker; only Blizzard's namespaced addons get that treatment, and
/// it is hardcoded client-side. What the client does expose is WTF\Account\&lt;ACCOUNT&gt;\AddOns.txt
/// (and a per-character copy), holding one "AddonName: enabled|disabled" line each.
///
/// So a player can still untick StatFeed mid-session, but it comes back on next launch. That
/// is as close to mandatory as this client version allows.
///
/// Only lines for addons we wrote are touched. Third-party addons keep whatever state the
/// player chose — and no addon is ever removed from the file.
/// </summary>
public static class AddOnsTxtEnforcer
{
    public static int ForceEnable(string installPath, IReadOnlyCollection<string> addonNames)
    {
        if (addonNames.Count == 0) return 0;

        var wtf = Path.Combine(installPath, "WTF");
        if (!Directory.Exists(wtf)) return 0;

        var updated = 0;
        // The file only appears after the player has logged in once. Before that there is
        // nothing to enforce — creating one ourselves risks writing a malformed list for an
        // account name we would have to guess.
        foreach (var file in Directory.EnumerateFiles(wtf, "AddOns.txt", SearchOption.AllDirectories))
        {
            try { if (EnforceInFile(file, addonNames)) updated++; }
            catch { /* one unreadable profile should not block launch */ }
        }
        return updated;
    }

    private static bool EnforceInFile(string path, IReadOnlyCollection<string> addonNames)
    {
        var lines = File.ReadAllLines(path).ToList();
        var changed = false;

        foreach (var name in addonNames)
        {
            var found = false;

            for (var i = 0; i < lines.Count; i++)
            {
                var colon = lines[i].IndexOf(':');
                if (colon < 0) continue;

                if (!lines[i][..colon].Trim().Equals(name, StringComparison.OrdinalIgnoreCase))
                    continue;

                found = true;
                if (lines[i][(colon + 1)..].Trim().Equals("enabled", StringComparison.OrdinalIgnoreCase))
                    break;

                lines[i] = $"{name}: enabled";
                changed = true;
                break;
            }

            if (!found)
            {
                lines.Add($"{name}: enabled");
                changed = true;
            }
        }

        if (changed) File.WriteAllLines(path, lines);
        return changed;
    }
}
