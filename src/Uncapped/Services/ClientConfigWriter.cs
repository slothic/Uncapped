using System.Text;

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

    /// <param name="locale">
    /// The client's real language folder. This used to be hardcoded to enUS, and the
    /// CreateDirectory below then brought that folder into existence on clients that had no
    /// business having one — half the reason an enGB client stopped booting once the launcher
    /// had touched it. Null skips the per-locale copy rather than guessing.
    /// </param>
    public static Result WriteRealmlist(string installPath, string address, string? realmName, ClientLocale? locale)
    {
        var written = new List<string>();
        var failed = new List<string>();
        var line = $"set realmlist {address}";

        // Which of these the client honours varies by build, so write both rather than
        // guess. The root file often does not exist yet on a fresh ChromieCraft client.
        var targets = new List<string> { "realmlist.wtf" };
        if (locale is not null) targets.Add(Path.Combine("Data", locale.Code, "realmlist.wtf"));

        foreach (var rel in targets)
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
            var values = new Dictionary<string, string> { ["realmList"] = address };
            if (!string.IsNullOrWhiteSpace(realmName)) values["realmName"] = realmName!;

            if (ConfigWtf.Update(installPath, values)) written.Add(@"WTF\Config.wtf");
        }
        catch (Exception ex) { failed.Add($@"WTF\Config.wtf: {ex.Message}"); }

        return new Result(written, failed);
    }
}
