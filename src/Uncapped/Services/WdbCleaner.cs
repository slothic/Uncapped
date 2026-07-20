namespace Uncapped.Services;

/// <summary>
/// Clears Cache\WDB. The client caches server-sent item/creature/quest data there and will
/// happily keep serving stale entries after a data change, which reads to players as a
/// server bug. Cheap to do, so we do it after every sync that touched anything.
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
