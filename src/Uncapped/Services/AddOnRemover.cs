using Uncapped.Model;

namespace Uncapped.Services;

public sealed record AddOnRemoval(List<string> Removed, List<string> Errors);

/// <summary>
/// Deletes addon folders the manifest names in <see cref="Manifest.RemoveAddOns"/>, together
/// with the saved variables they leave behind.
///
/// ★★ WHY THIS EXISTS, WHEN forceDisableAddOns ALREADY DID SOMETHING
///
/// Unticking an addon in AddOns.txt stops it loading. It does not stop it EXISTING, and every
/// consequence of it existing survived:
///
///   * the folder is still there, so a player who ticks the box back on — or any third-party
///     addon manager that rewrites AddOns.txt — brings it straight back,
///   * <see cref="ForeignAddOnScanner"/> keeps counting it, so the integrity summary keeps
///     telling people their install has files that are not ours,
///   * its SavedVariables keep being loaded and rewritten by the client.
///
/// QuestHelper is the case that proved it. Pulled from the payload on 2026-07-20 for throwing
/// Lua errors, named in forceDisableAddOns from that day, and still installed and still being
/// complained about on 2026-09-06 — seven weeks in which the launcher was, as far as anyone
/// could tell, doing something about it.
///
/// ★ THE GUARD IS THE POINT.
///
/// This is the only code in the launcher that deletes software we did not write during a
/// normal sync, with no dialog in front of it. So it refuses to touch anything the manifest is
/// also shipping, force-enabling or installing as an archive: a name that appears on both
/// lists is a mistake in the manifest, and the safe reading of a mistake is "do nothing".
/// Blizzard_* is refused outright, and every path is checked to be genuinely under
/// Interface\AddOns before a single file goes.
///
/// A player's own addons are NOT in scope here — those come out only through
/// <see cref="FactoryReset"/>, which is behind a REPAIR press and a confirmation naming them.
/// </summary>
public static class AddOnRemover
{
    /// <summary>
    /// Removes every folder named in <see cref="Manifest.RemoveAddOns"/> that is still
    /// present. Returns the names actually removed — an addon that was never installed is not
    /// an error and is not reported.
    /// </summary>
    public static AddOnRemoval Apply(string installPath, Manifest manifest)
    {
        var removed = new List<string>();
        var errors = new List<string>();

        if (manifest.RemoveAddOns.Count == 0) return new AddOnRemoval(removed, errors);

        var protectedNames = ForeignAddOnScanner.ShippedFolders(manifest);

        foreach (var name in manifest.RemoveAddOns)
        {
            if (string.IsNullOrWhiteSpace(name)) continue;

            if (name.StartsWith("Blizzard_", StringComparison.OrdinalIgnoreCase))
            {
                errors.Add($"{name}: refusing to remove a Blizzard addon.");
                continue;
            }

            if (protectedNames.Contains(name))
            {
                // Loud, because it means the manifest contradicts itself and the addon is
                // being reinstalled by the sync in the same pass that tries to delete it.
                errors.Add($"{name}: the manifest both installs and removes this addon; left alone.");
                continue;
            }

            if (Remove(installPath, name, errors)) removed.Add(name);
        }

        return new AddOnRemoval(removed, errors);
    }

    /// <summary>
    /// Deletes one addon folder and its saved variables. Returns true only if the folder was
    /// there and is now gone.
    /// </summary>
    public static bool Remove(string installPath, string name, List<string> errors)
    {
        var addOns = Path.Combine(installPath, "Interface", "AddOns");
        var folder = Path.Combine(addOns, name);

        // A name with a separator or a .. in it would resolve somewhere else entirely. The
        // list is ours, but it arrives over the network like the rest of the manifest.
        if (!SafePath.IsInside(addOns, folder))
        {
            errors.Add($"{name}: not a plain addon folder name; refused.");
            return false;
        }

        var gone = false;

        if (Directory.Exists(folder))
        {
            try
            {
                Directory.Delete(folder, recursive: true);
                gone = true;
                Log.Write($"addons: removed {name}");
            }
            catch (Exception ex)
            {
                errors.Add($"{name}: {ex.Message}");
                return false;
            }
        }

        // Saved variables go whether or not the folder was there. An addon removed by hand
        // leaves its .lua behind, and that file is the one that survives a reinstall and
        // restores the settings that made it broken in the first place.
        RemoveSavedVariables(installPath, name, errors);

        return gone;
    }

    /// <summary>
    /// Deletes WTF\...\SavedVariables\&lt;name&gt;.lua and its .bak, at both the account and the
    /// per-character level.
    ///
    /// Walked rather than composed from a known path: the account folder is named after the
    /// account, the character folders after realm and character, and none of those are
    /// something the launcher can know. Only files whose stem is exactly the addon name are
    /// touched, so "UncappedQuests.lua" is never caught by a rule about "Uncapped".
    /// </summary>
    private static void RemoveSavedVariables(string installPath, string name, List<string> errors)
    {
        var wtf = Path.Combine(installPath, "WTF");
        if (!Directory.Exists(wtf)) return;

        try
        {
            foreach (var dir in Directory.EnumerateDirectories(wtf, "SavedVariables", SearchOption.AllDirectories))
            {
                foreach (var extension in new[] { ".lua", ".lua.bak", ".bak" })
                {
                    var file = Path.Combine(dir, name + extension);
                    if (!File.Exists(file)) continue;

                    try
                    {
                        File.Delete(file);
                        Log.Write($"addons: removed saved settings {Path.GetFileName(file)}");
                    }
                    catch (Exception ex) { errors.Add($"{name}{extension}: {ex.Message}"); }
                }
            }
        }
        catch (Exception ex)
        {
            // An unreadable WTF tree must not stop the folder deletion above from counting.
            errors.Add($"{name}: could not search WTF for saved settings — {ex.Message}");
        }
    }
}
