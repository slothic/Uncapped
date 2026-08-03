using System.Text.RegularExpressions;

namespace Uncapped.Services;

/// <summary>One locale folder found under Data\, and how complete it looks.</summary>
public sealed record LocaleFolder(string Code, bool HasLocaleMpq, bool HasBaseMpq)
{
    /// <summary>
    /// A folder the client can actually boot from. locale-XX.MPQ is the archive it fails on
    /// first; base-XX.MPQ is checked too so that a folder holding one and not the other is
    /// never mistaken for a working install.
    /// </summary>
    public bool IsPlayable => HasLocaleMpq && HasBaseMpq;
}

/// <summary>
/// Which language a client actually is, and where our payload therefore belongs.
///
/// WHY THIS EXISTS
///
/// The launcher used to assume enUS everywhere: the manifest ships Data/enUS/patch-enUS-*.mpq,
/// the realmlist writer created Data\enUS\ to write into, and IsValidInstall asked only for an
/// executable and a Data folder. Point that at an enGB client — which most clean 3.3.5a copies
/// outside the private-server repack scene are — and the sync manufactures a SECOND locale
/// folder beside the real one, holding two patch MPQs and a realmlist and nothing else. The
/// client finds enUS, goes looking for base-enUS.MPQ, and dies on "Cannot stream required
/// archive data. Please check the network connection", which reads to the player as a network
/// fault and to us as a client that was working ten minutes ago.
///
/// So: detect the locale from what is on disk, put our files in that folder under that name,
/// and clear up the stray folder if a previous version of the launcher already made one.
///
/// The patch MPQs themselves are locale-agnostic — DBC and interface data, no voice — so
/// patch-enUS-4.mpq and patch-enGB-4.mpq are the same bytes under different names. Only the
/// name has to match the folder, which is why remapping is a rename rather than a rebuild.
/// </summary>
public sealed class ClientLocale
{
    /// <summary>
    /// Every locale 3.3.5a shipped in. Used to tell a locale folder apart from the other
    /// things that live under Data\ (Cache, Interface, and whatever a repack left behind),
    /// so an unrelated folder is never treated as a language.
    /// </summary>
    private static readonly string[] KnownCodes =
    {
        "enUS", "enGB", "enCN", "enTW", "deDE", "esES", "esMX", "frFR",
        "itIT", "koKR", "ptBR", "ptPT", "ruRU", "zhCN", "zhTW",
    };

    public string Code { get; }

    /// <summary>Every locale folder present, playable or not. Kept for the log line.</summary>
    public IReadOnlyList<LocaleFolder> Found { get; }

    private ClientLocale(string code, IReadOnlyList<LocaleFolder> found)
    {
        Code = code;
        Found = found;
    }

    public static bool IsLocaleCode(string name) =>
        KnownCodes.Any(c => c.Equals(name, StringComparison.OrdinalIgnoreCase));

    /// <summary>Canonical casing, so a folder named "engb" still yields patch-enGB-4.mpq.</summary>
    private static string Canonical(string name) =>
        KnownCodes.FirstOrDefault(c => c.Equals(name, StringComparison.OrdinalIgnoreCase)) ?? name;

    public static List<LocaleFolder> Scan(string installPath)
    {
        var data = Path.Combine(installPath, "Data");
        if (!Directory.Exists(data)) return new List<LocaleFolder>();

        var found = new List<LocaleFolder>();

        try
        {
            foreach (var dir in Directory.EnumerateDirectories(data))
            {
                var name = Path.GetFileName(dir);
                if (!IsLocaleCode(name)) continue;

                var code = Canonical(name);
                found.Add(new LocaleFolder(
                    code,
                    File.Exists(Path.Combine(dir, $"locale-{code}.MPQ")),
                    File.Exists(Path.Combine(dir, $"base-{code}.MPQ"))));
            }
        }
        catch { /* an unreadable Data\ is reported as "no locales", which fails the same way */ }

        return found;
    }

    /// <summary>
    /// The locale to install into, or null when no folder on disk can actually be played.
    ///
    /// Config.wtf gets the first say when it names a playable folder: on a client with two
    /// real locales installed, that is the one the player is running. Otherwise the single
    /// playable folder wins. Two playable folders and no usable Config.wtf is genuinely
    /// ambiguous, so it takes the first in KnownCodes order — arbitrary, but stable across
    /// runs, which matters more than which one it picks.
    /// </summary>
    public static ClientLocale? Detect(string installPath)
    {
        var found = Scan(installPath);
        var playable = found.Where(f => f.IsPlayable).ToList();
        if (playable.Count == 0) return null;

        var configured = ConfigWtf.Read(installPath, "locale");
        var preferred = playable.FirstOrDefault(
            f => f.Code.Equals(configured, StringComparison.OrdinalIgnoreCase));

        var chosen = preferred ?? playable
            .OrderBy(f => Array.FindIndex(KnownCodes, c => c.Equals(f.Code, StringComparison.OrdinalIgnoreCase)))
            .First();

        return new ClientLocale(chosen.Code, found);
    }

    /// <summary>One line for launcher.log — the question a broken-client report always needs.</summary>
    public string Describe()
    {
        var others = Found
            .Where(f => !f.Code.Equals(Code, StringComparison.OrdinalIgnoreCase))
            .Select(f => f.IsPlayable ? f.Code : $"{f.Code} (incomplete)")
            .ToList();

        return others.Count == 0
            ? Code
            : $"{Code}; also present: {string.Join(", ", others)}";
    }

    /// <summary>
    /// Moves a manifest path onto this client's locale. Data\enUS\patch-enUS-4.mpq becomes
    /// Data\enGB\patch-enGB-4.mpq; anything outside Data\&lt;locale&gt;\ is returned untouched,
    /// so the ~720 addon files are unaffected.
    /// </summary>
    public string Remap(string relative)
    {
        var parts = relative.Split(Path.DirectorySeparatorChar);
        if (parts.Length < 3) return relative;
        if (!parts[0].Equals("Data", StringComparison.OrdinalIgnoreCase)) return relative;
        if (!IsLocaleCode(parts[1])) return relative;

        var from = parts[1];
        if (from.Equals(Code, StringComparison.OrdinalIgnoreCase)) return relative;

        parts[1] = Code;

        // Only the file name is rewritten, not the intermediate folders: a locale code
        // appearing mid-path would be somebody else's layout, not ours to reinterpret.
        parts[^1] = Regex.Replace(parts[^1], Regex.Escape(from), Code, RegexOptions.IgnoreCase);

        return string.Join(Path.DirectorySeparatorChar, parts);
    }

    /// <summary>
    /// Removes a locale folder that a previous launcher version invented — the enUS folder
    /// created next to a real enGB one, holding only files we put there.
    ///
    /// Deliberately narrow, because this deletes from inside someone's game folder. A folder
    /// only qualifies when it holds no locale-XX.MPQ and no base-XX.MPQ (so no real client
    /// data can be in it), only files the launcher itself recorded installing are removed,
    /// and the folder goes only if that leaves it empty. Anything the player put there keeps
    /// the folder alive, and the worst case is a leftover directory rather than a deletion we
    /// cannot take back.
    /// </summary>
    public List<string> RemoveStrayFolders(string installPath, IEnumerable<string> installedFiles)
    {
        var removed = new List<string>();

        var strays = Found
            .Where(f => !f.Code.Equals(Code, StringComparison.OrdinalIgnoreCase))
            .Where(f => !f.HasLocaleMpq && !f.HasBaseMpq)
            .Select(f => f.Code)
            .ToList();

        if (strays.Count == 0) return removed;

        foreach (var stray in strays)
        {
            var folder = Path.Combine(installPath, "Data", stray);
            var prefix = Path.Combine("Data", stray) + Path.DirectorySeparatorChar;

            foreach (var tracked in installedFiles)
            {
                if (!tracked.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;

                var path = Path.Combine(installPath, tracked);
                try
                {
                    if (File.Exists(path)) { File.Delete(path); removed.Add(tracked); }
                }
                catch { /* a locked file leaves the folder standing; harmless */ }
            }

            // realmlist.wtf is ours too — earlier versions wrote it here unconditionally — but
            // it is not in InstalledFiles, so it is named rather than pattern-matched.
            var realmlist = Path.Combine(folder, "realmlist.wtf");
            try
            {
                if (File.Exists(realmlist)) { File.Delete(realmlist); removed.Add(Path.Combine("Data", stray, "realmlist.wtf")); }
            }
            catch { /* same */ }

            try
            {
                if (Directory.Exists(folder) && !Directory.EnumerateFileSystemEntries(folder).Any())
                    Directory.Delete(folder);
            }
            catch { /* leave it; an empty folder breaks nothing once the MPQs are gone */ }
        }

        return removed;
    }
}
