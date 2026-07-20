namespace Uncapped.Services;

/// <summary>
/// Sets the tick state of specific addons in the client's addon list.
///
/// 3.3.5a has no .toc flag that makes an addon undisableable — nothing equivalent to a
/// "secure" or "protected" marker; only Blizzard's namespaced addons get that treatment, and
/// it is hardcoded client-side. What the client does expose is WTF\Account\&lt;ACCOUNT&gt;\AddOns.txt
/// (and a per-character copy), holding one "AddonName: enabled|disabled" line each.
///
/// So a player can still untick StatFeed mid-session, but it comes back on next launch. That
/// is as close to mandatory as this client version allows.
///
/// Only lines for addons we name are touched. Everything else keeps whatever state the player
/// chose — and no addon is ever removed from the file.
/// </summary>
public static class AddOnsTxtEnforcer
{
    public static int Apply(
        string installPath,
        IReadOnlyCollection<string> enable,
        IReadOnlyCollection<string> disable)
    {
        if (enable.Count == 0 && disable.Count == 0) return 0;

        var wtf = Path.Combine(installPath, "WTF");
        if (!Directory.Exists(wtf)) return 0;

        // Only force-disable addons that are actually installed. Writing a line for an addon
        // the player has never had would leave a stale entry for no benefit.
        var addOnsDir = Path.Combine(installPath, "Interface", "AddOns");
        var present = disable
            .Where(name => Directory.Exists(Path.Combine(addOnsDir, name)))
            .ToList();

        var wanted = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in enable) wanted[name] = true;
        // Disable wins if an addon somehow appears in both, so a broken addon cannot be
        // force-enabled by a stale entry.
        foreach (var name in present) wanted[name] = false;

        if (wanted.Count == 0) return 0;

        var updated = 0;
        // The file only appears after the player has logged in once. Before that there is
        // nothing to enforce — creating one ourselves risks writing a malformed list for an
        // account name we would have to guess.
        foreach (var file in Directory.EnumerateFiles(wtf, "AddOns.txt", SearchOption.AllDirectories))
        {
            try { if (EnforceInFile(file, wanted)) updated++; }
            catch { /* one unreadable profile should not block launch */ }
        }
        return updated;
    }

    private static bool EnforceInFile(string path, Dictionary<string, bool> wanted)
    {
        var lines = File.ReadAllLines(path).ToList();
        var changed = false;

        foreach (var (name, shouldEnable) in wanted)
        {
            var state = shouldEnable ? "enabled" : "disabled";
            var found = false;

            for (var i = 0; i < lines.Count; i++)
            {
                var colon = lines[i].IndexOf(':');
                if (colon < 0) continue;

                if (!lines[i][..colon].Trim().Equals(name, StringComparison.OrdinalIgnoreCase))
                    continue;

                found = true;
                if (lines[i][(colon + 1)..].Trim().Equals(state, StringComparison.OrdinalIgnoreCase))
                    break;

                lines[i] = $"{name}: {state}";
                changed = true;
                break;
            }

            // Only add a missing line when enabling. A disable entry for an addon the client
            // has not listed yet is noise.
            if (!found && shouldEnable)
            {
                lines.Add($"{name}: {state}");
                changed = true;
            }
        }

        if (changed) File.WriteAllLines(path, lines);
        return changed;
    }
}
