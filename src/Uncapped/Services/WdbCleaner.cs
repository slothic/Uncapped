namespace Uncapped.Services;

/// <summary>
/// Clears Cache\WDB. The client caches server-sent item/creature/quest data there and will
/// happily keep serving stale entries after a data change, which reads to players as a
/// server bug.
///
/// The cache is keyed by entry id and is NOT namespaced per realm, so it is shared with every
/// other server the player connects to using this client — their item 900400 silently becomes
/// ours. That is why the caller clears it on every launch rather than only when our own payload
/// changed: the contaminating case never touches our payload at all.
/// </summary>
public static class WdbCleaner
{
    public static int Clear(string installPath)
    {
        var wdb = Path.Combine(installPath, "Cache", "WDB");
        if (!Directory.Exists(wdb)) return 0;

        var deleted = 0;
        foreach (var file in Directory.EnumerateFiles(wdb, "*", SearchOption.AllDirectories))
        {
            try { File.Delete(file); deleted++; }
            catch { /* a locked cache file is not worth failing the whole sync over */ }
        }
        return deleted;
    }
}
