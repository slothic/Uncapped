using System.Text.Json;
using Uncapped;
using Uncapped.Model;
using Uncapped.Services;

namespace Uncapped.Tests;

/// <summary>
/// Exercises IntegrityVerifier against synthetic clients, one deliberate fault at a time.
///
/// Synthetic rather than a copy of a real 17 GB install: the verifier's logic is about which
/// files are expected, tolerated or unaccounted for, and none of that cares how big an MPQ is.
/// Building the tree here means every case is set up in milliseconds and the fault under test
/// is the only difference between runs.
///
/// ⚠ IntegrityVerifier calls state.Save(), which writes the REAL %LOCALAPPDATA%\Uncapped\state.json
/// — AppPaths uses GetFolderPath, which ignores the LOCALAPPDATA environment variable, so it
/// cannot be redirected. A harness run has wiped a live installPath and 553 tracked files before.
/// The backup below is not optional.
/// </summary>
public static class Program
{
    private static int _passed;
    private static int _failed;

    public static async Task<int> Main(string[] args)
    {
        var backup = BackUpLiveState();

        try
        {
            if (args.Length > 0 && args[0] == "--dialog")
                RenderDialogs();
            else if (args.Length > 0)
                await VerifyRealClientAsync(args[0]);
            else
                await RunAllAsync();
        }
        finally
        {
            RestoreLiveState(backup);
        }

        Console.WriteLine();
        Console.WriteLine($"{_passed} passed, {_failed} failed");
        return _failed == 0 ? 0 : 1;
    }

    /// <summary>
    /// Runs the PUBLISHED baseline and manifest against a real install.
    ///
    /// This is the one that decides whether the release is safe to ship. The synthetic cases
    /// prove the logic; this proves the data — that the hashes we are about to hand every
    /// player actually describe a client that exists. Getting it wrong does not fail quietly:
    /// it turns PLAY off for everyone at once.
    /// </summary>
    private static async Task VerifyRealClientAsync(string clientDir)
    {
        var baselineJson = File.ReadAllText(@"C:\Wotlk\Launcher\baseline.json");
        var manifestJson = File.ReadAllText(@"C:\Wotlk\Launcher\manifest.json");

        var baseline = JsonSerializer.Deserialize<Baseline>(baselineJson)!;
        var manifest = JsonSerializer.Deserialize<Manifest>(manifestJson)!;

        Console.WriteLine($"client:   {clientDir}");
        Console.WriteLine($"baseline: {baseline.Files.Count} files, build {baseline.ClientBuild}, locale {baseline.Locale}");
        Console.WriteLine($"manifest: {manifest.Files.Count} files");
        Console.WriteLine();

        var locale = ClientLocale.Detect(clientDir);
        Console.WriteLine($"detected locale: {locale?.Describe() ?? "NONE"}");

        var state = new LauncherState();
        var started = DateTime.UtcNow;
        var lastReport = DateTime.UtcNow;

        var progress = new Progress<SyncProgress>(p =>
        {
            if ((DateTime.UtcNow - lastReport).TotalSeconds < 2) return;
            lastReport = DateTime.UtcNow;
            Console.WriteLine($"  {p.Status} {p.Completed}/{p.Total}");
        });

        var report = await new IntegrityVerifier(clientDir, manifest, baseline, locale, state)
            .VerifyAsync(progress, CancellationToken.None);

        var elapsed = DateTime.UtcNow - started;

        Console.WriteLine();
        Console.WriteLine($"COLD PASS: {elapsed.TotalSeconds:0.0}s, " +
                          $"{report.Checked} checked, {report.Skipped} absent-and-optional, " +
                          $"{report.BytesHashed / (1024 * 1024):N0} MB hashed");

        foreach (var p in report.Problems)
            Console.WriteLine($"  {p.Fault,-8} {(p.Blocking ? "BLOCKING " : "         ")}{p.Path}");

        // The second pass is the one players actually experience on every launch after the
        // first, so it is the number that decides whether this is acceptable at all.
        started = DateTime.UtcNow;
        var again = await new IntegrityVerifier(clientDir, manifest, baseline, locale, state)
            .VerifyAsync(new Progress<SyncProgress>(_ => { }), CancellationToken.None);
        var warm = DateTime.UtcNow - started;

        Console.WriteLine();
        Console.WriteLine($"WARM PASS: {warm.TotalSeconds:0.00}s, {again.BytesHashed / (1024 * 1024):N0} MB hashed");
        Console.WriteLine();

        Check("real client: no missing required files",
              !report.Problems.Any(p => p.Fault == IntegrityFault.Missing && p.Blocking));
        Check("real client: no corrupt required files",
              !report.Problems.Any(p => p.Fault == IntegrityFault.Corrupt && p.Blocking));
        Check("real client: warm pass hashes nothing", again.BytesHashed == 0);
        Check("real client: warm pass under 5s", warm.TotalSeconds < 5, $"{warm.TotalSeconds:0.00}s");
    }

    private static async Task RunAllAsync()
    {
        await CleanClientHasNoProblems();
        await MissingPayloadFileBlocksPlay();
        await CorruptBaseArchiveBlocksPlay();
        await ForeignArchiveWarnsButDoesNotBlock();
        await PlayerContentIsNotFlagged();
        await ToleratedFilesAreNotFlagged();
        await SecondLocaleIsNotFlagged();
        await LocaleMismatchSkipsLocaleFiles();
        await OptionalFileMissingIsNotAProblem();
        await SecondRunUsesTheHashCache();
        await CorruptionInvalidatesTheHashCache();
        await QuarantineMovesRatherThanDeletes();

        await NoItemCacheBlockWipesEverything();
        await ItemCacheInstallsAndSweepsTheOtherCaches();
        await RewrittenCacheIsNotReinstalled();
        await ChangedEpochReinstalls();
        await DeletedCacheReinstallsDespiteSentinel();
        await UnsupportedLocaleFallsBackToWiping();
        await BadTransportHashFallsBackToWiping();
        await BadContentHashFallsBackToWiping();
        await NotAWdbFallsBackToWiping();
        await DownloadFailureFallsBackToWiping();
        await IntegrityCheckIgnoresTheItemCache();

        await StalePartialDoesNotWedgeOnA416();
        await WrongLengthIsClassifiedAsAMismatch();
        await StalePartialRecoversOnceTheHostCatchesUp();
    }

    // ---------- dialog rendering ----------

    /// <summary>
    /// Renders both states of the warning dialog to PNG.
    ///
    /// Binding failures inside a DataTemplate are silent — WPF writes a trace nobody reads and
    /// draws a blank row. The only way to know the columns actually populate is to look, so
    /// this draws the window offscreen and saves it.
    /// </summary>
    private static void RenderDialogs()
    {
        // WPF needs a single-threaded-apartment thread and Main is async, so [STAThread] on it
        // would not take effect. A dedicated thread is the straightforward way in.
        var thread = new Thread(RenderDialogsCore, 16 * 1024 * 1024);
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
    }

    private static void RenderDialogsCore()
    {
        var outDir = Path.Combine(Path.GetTempPath(), "uncapped-dialog-shots");
        Directory.CreateDirectory(outDir);

        Render("blocking", new IntegrityReport(new List<IntegrityProblem>
        {
            new(@"Data\enUS\patch-enUS-Q.MPQ", IntegrityFault.Missing, true, 313_013_171,
                "http://x/", "abc"),
            new(@"Data\common.MPQ", IntegrityFault.Corrupt, true, 2_881_154_862, "http://x/", "abc"),
            new(@"Interface\AddOns\UncappedVersion\UncappedVersion.lua", IntegrityFault.Missing, true, 4_096,
                "http://x/", "abc"),
        }, 640, 0, 17_000_000_000), outDir);

        Render("foreign-only", new IntegrityReport(new List<IntegrityProblem>
        {
            new(@"Data\enUS\patch-enUS-X.MPQ", IntegrityFault.Foreign, false, 48_767_934),
            new(@"Data\enUS\patch-enUS-9.MPQ", IntegrityFault.Foreign, false, 2_140_000),
            new(@"someserver.dll", IntegrityFault.Foreign, false, 131_072),
        }, 643, 0, 17_000_000_000), outDir);

        Console.WriteLine($"Dialog screenshots written to {outDir}");
    }

    private static void Render(string name, IntegrityReport report, string outDir)
    {
        var window = new IntegrityWarningWindow(report)
        {
            WindowStartupLocation = System.Windows.WindowStartupLocation.Manual,
            Left = -10_000,
            Top = -10_000,
            ShowInTaskbar = false,
        };

        window.Show();
        window.UpdateLayout();
        window.Dispatcher.Invoke(() => { }, System.Windows.Threading.DispatcherPriority.Loaded);

        var width = (int)Math.Ceiling(window.ActualWidth);
        var height = (int)Math.Ceiling(window.ActualHeight);

        var bitmap = new System.Windows.Media.Imaging.RenderTargetBitmap(
            width, height, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
        bitmap.Render(window);

        var encoder = new System.Windows.Media.Imaging.PngBitmapEncoder();
        encoder.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bitmap));

        var path = Path.Combine(outDir, name + ".png");
        using (var stream = File.Create(path)) encoder.Save(stream);

        window.Close();

        Check($"dialog '{name}': rendered {width}x{height}", width > 100 && height > 100);
        Console.WriteLine($"        {path}");
    }

    // ---------- the cases ----------

    private static async Task CleanClientHasNoProblems()
    {
        using var c = new Fixture();
        var report = await c.VerifyAsync();

        Check("clean client: no problems", report.Problems.Count == 0, Describe(report));
        Check("clean client: PLAY allowed", report.CanPlay);
        Check("clean client: everything checked", report.Checked >= 5, $"checked={report.Checked}");
    }

    private static async Task MissingPayloadFileBlocksPlay()
    {
        using var c = new Fixture();
        File.Delete(Path.Combine(c.Client, "Interface", "AddOns", "UncappedVersion", "UncappedVersion.lua"));

        var report = await c.VerifyAsync();
        var problem = report.Problems.SingleOrDefault(p => p.Path.EndsWith("UncappedVersion.lua"));

        Check("missing payload file: reported", problem is not null, Describe(report));
        Check("missing payload file: fault is Missing", problem?.Fault == IntegrityFault.Missing);
        Check("missing payload file: blocks PLAY", report.CanPlay == false);
    }

    private static async Task CorruptBaseArchiveBlocksPlay()
    {
        using var c = new Fixture();

        // Same length, one byte different — the case a size check alone would wave through.
        var target = Path.Combine(c.Client, "Data", "common.MPQ");
        var bytes = File.ReadAllBytes(target);
        bytes[10] ^= 0xFF;
        File.WriteAllBytes(target, bytes);

        var report = await c.VerifyAsync();
        var problem = report.Problems.SingleOrDefault(p => p.Path.EndsWith("common.MPQ"));

        Check("corrupt base MPQ: reported", problem is not null, Describe(report));
        Check("corrupt base MPQ: fault is Corrupt", problem?.Fault == IntegrityFault.Corrupt);
        Check("corrupt base MPQ: blocks PLAY", report.CanPlay == false);
        Check("corrupt base MPQ: repair URL carried", !string.IsNullOrEmpty(problem?.Url));
        Check("corrupt base MPQ: expected hash carried", !string.IsNullOrEmpty(problem?.Sha256));
    }

    private static async Task ForeignArchiveWarnsButDoesNotBlock()
    {
        using var c = new Fixture();
        File.WriteAllText(Path.Combine(c.Client, "Data", "enUS", "patch-enUS-Z.MPQ"), "another server's patch");

        var report = await c.VerifyAsync();
        var problem = report.Problems.SingleOrDefault(p => p.Path.EndsWith("patch-enUS-Z.MPQ"));

        Check("foreign MPQ: reported", problem is not null, Describe(report));
        Check("foreign MPQ: fault is Foreign", problem?.Fault == IntegrityFault.Foreign);
        Check("foreign MPQ: does NOT block PLAY", report.CanPlay);
        Check("foreign MPQ: recognised as quarantinable", problem?.IsForeignArchive == true);
    }

    private static async Task PlayerContentIsNotFlagged()
    {
        using var c = new Fixture();

        // The things a player accumulates. None of this is evidence of anything, and flagging
        // any of it would fire the warning for practically everyone.
        c.Write("Interface/AddOns/Dominos/Dominos.toc", "## Interface: 30300");
        c.Write("Interface/AddOns/SomeRandomAddon/x.lua", "-- theirs");
        c.Write("Cache/WDB/enUS/creaturecache.wdb", "cache");
        c.Write("WTF/Account/BOB/config-cache.wtf", "settings");
        c.Write("Screenshots/WoWScrnShot_010125_120000.jpg", "a screenshot");
        c.Write("Logs/FrameXML.log", "log");
        c.Write("Errors/Crash.txt", "error");

        var report = await c.VerifyAsync();

        Check("player content: nothing flagged", report.Problems.Count == 0, Describe(report));
        Check("player content: PLAY allowed", report.CanPlay);
    }

    private static async Task ToleratedFilesAreNotFlagged()
    {
        using var c = new Fixture();

        // Files the launcher itself leaves behind, which must not read as tampering.
        c.Write("Data/enUS/patch-enUS-5.MPQ.retired-20260804", "a patch we pulled");
        c.Write("Data/enUS/realmlist.wtf", "set realmlist 152.53.115.249");
        c.Write("Data/enUS/patch-enUS-Q.MPQ.abcdef.uncapped-tmp", "an interrupted download");

        var report = await c.VerifyAsync();

        Check("tolerated files: nothing flagged", report.Problems.Count == 0, Describe(report));
    }

    private static async Task SecondLocaleIsNotFlagged()
    {
        using var c = new Fixture();

        // A second language installed beside the first is legitimate and we have no hashes
        // for it. Silence beats a false accusation.
        c.Write("Data/deDE/locale-deDE.MPQ", "german");
        c.Write("Data/deDE/base-deDE.MPQ", "german");
        c.Write("Data/deDE/speech-deDE.MPQ", "german");

        var report = await c.VerifyAsync();

        Check("second locale: nothing flagged", report.Problems.Count == 0, Describe(report));
    }

    private static async Task LocaleMismatchSkipsLocaleFiles()
    {
        // A deDE client cannot be checked against enUS hashes. It must not be called broken.
        using var c = new Fixture(locale: "deDE");
        var report = await c.VerifyAsync();

        var localeComplaints = report.Problems
            .Where(p => p.Path.Contains("deDE", StringComparison.OrdinalIgnoreCase))
            .ToList();

        Check("locale mismatch: no complaints about the client's own locale folder",
              localeComplaints.Count == 0, Describe(report));
        Check("locale mismatch: PLAY allowed", report.CanPlay, Describe(report));
    }

    private static async Task OptionalFileMissingIsNotAProblem()
    {
        using var c = new Fixture();
        File.Delete(Path.Combine(c.Client, "Data", "enUS", "Credits.html"));

        var report = await c.VerifyAsync();

        Check("optional file missing: not reported", report.Problems.Count == 0, Describe(report));
        Check("optional file missing: counted as skipped", report.Skipped == 1, $"skipped={report.Skipped}");
    }

    private static async Task SecondRunUsesTheHashCache()
    {
        using var c = new Fixture();

        var first = await c.VerifyAsync();
        var second = await c.VerifyAsync();

        Check("hash cache: first run reads the files", first.BytesHashed > 0, $"{first.BytesHashed} bytes");
        Check("hash cache: second run reads nothing", second.BytesHashed == 0, $"{second.BytesHashed} bytes");
        Check("hash cache: second run still clean", second.Problems.Count == 0, Describe(second));
    }

    private static async Task CorruptionInvalidatesTheHashCache()
    {
        using var c = new Fixture();
        await c.VerifyAsync();   // warm the cache on a clean client

        // Rewrite with the SAME length. Only the write time changes, which is exactly the
        // signal the cache is supposed to invalidate on.
        var target = Path.Combine(c.Client, "Data", "common.MPQ");
        var bytes = File.ReadAllBytes(target);
        bytes[3] ^= 0xFF;
        File.WriteAllBytes(target, bytes);
        File.SetLastWriteTimeUtc(target, DateTime.UtcNow.AddSeconds(5));

        var report = await c.VerifyAsync();

        Check("cache invalidation: corruption after a clean run is still caught",
              report.Problems.Any(p => p.Path.EndsWith("common.MPQ")), Describe(report));
        Check("cache invalidation: blocks PLAY", report.CanPlay == false);
    }

    private static async Task QuarantineMovesRatherThanDeletes()
    {
        using var c = new Fixture();
        var foreignPath = Path.Combine(c.Client, "Data", "enUS", "patch-enUS-Z.MPQ");
        File.WriteAllText(foreignPath, "another server's patch");

        var report = await c.VerifyAsync();
        var archives = report.Problems.Where(p => p.IsForeignArchive).ToList();

        var outcome = new RepairService(new HttpClient())
            .Quarantine(c.Client, archives, c.State);

        var moved = Path.Combine(c.Client, "Data", "_disabled", "patch-enUS-Z.MPQ");

        Check("quarantine: one file moved", outcome.Quarantined == 1);
        Check("quarantine: gone from Data\\enUS", !File.Exists(foreignPath));
        Check("quarantine: present in Data\\_disabled", File.Exists(moved));
        Check("quarantine: contents preserved",
              File.Exists(moved) && File.ReadAllText(moved) == "another server's patch");

        // And the quarantine folder itself must not then be reported as foreign, or the
        // warning would be permanent and un-clearable.
        var after = await c.VerifyAsync();
        Check("quarantine: clean afterwards", after.Problems.Count == 0, Describe(after));
        Check("quarantine: PLAY allowed afterwards", after.CanPlay);
    }

    // ---------- the item cache ----------
    //
    // These matter more than usual. The design is fail-open at the client: no server-side gate
    // checks that the file a client loaded is one we generated, so a subtle mistake here is
    // wrong tooltips for every player at once rather than nothing happening. Offline coverage
    // is the compensating control, so every failure path is asserted to end in the OLD
    // behaviour (wipe everything, install nothing) rather than in something clever.

    private static async Task NoItemCacheBlockWipesEverything()
    {
        using var c = new Fixture();
        c.SeedWdb();

        var outcome = await c.SyncWdbAsync(itemCache: null);

        Check("no itemCache block: nothing installed", !outcome.Installed);
        Check("no itemCache block: every cache file removed",
              c.WdbFiles().Count == 0, string.Join(",", c.WdbFiles()));
        Check("no itemCache block: reports the wipe", outcome.Deleted == 3, $"deleted={outcome.Deleted}");
    }

    private static async Task ItemCacheInstallsAndSweepsTheOtherCaches()
    {
        using var c = new Fixture();
        c.SeedWdb();
        var cache = ItemCacheFile.Build("2026.01.01a");

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("install: installed", outcome.Installed, outcome.Detail);
        Check("install: itemcache.wdb written with our bytes",
              c.ItemCacheBytes()?.SequenceEqual(cache.Plain) == true);
        Check("install: sentinel carries the epoch", c.Sentinel() == "2026.01.01a");
        Check("install: the OTHER caches are still wiped",
              !File.Exists(Path.Combine(c.WdbDir, "creaturecache.wdb")) &&
              !File.Exists(Path.Combine(c.WdbDir, "questcache.wdb")));
        Check("install: downloaded exactly once", cache.Handler.Requests == 1);
    }

    private static async Task RewrittenCacheIsNotReinstalled()
    {
        using var c = new Fixture();
        var cache = ItemCacheFile.Build("2026.01.01a");
        await c.SyncWdbAsync(cache.Spec, cache.Handler);

        // What the client does within seconds of logging in: appends its own records. A
        // hash-based trigger would re-download 1.7 MB here, on every launch, forever.
        File.AppendAllText(Path.Combine(c.WdbDir, WdbCache.ItemCacheName), "client wrote this");
        var mutated = File.ReadAllBytes(Path.Combine(c.WdbDir, WdbCache.ItemCacheName));

        c.SeedWdb(itemCache: false);
        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("rewritten cache: no second download", cache.Handler.Requests == 1,
              $"requests={cache.Handler.Requests}");
        Check("rewritten cache: not installed again", !outcome.Installed, outcome.Detail);
        Check("rewritten cache: the client's own bytes are left alone",
              c.ItemCacheBytes()?.SequenceEqual(mutated) == true);
        Check("rewritten cache: sentinel survives the sweep", c.Sentinel() == "2026.01.01a");
        Check("rewritten cache: the other caches are still wiped",
              !File.Exists(Path.Combine(c.WdbDir, "creaturecache.wdb")));
    }

    private static async Task ChangedEpochReinstalls()
    {
        using var c = new Fixture();
        var first = ItemCacheFile.Build("2026.01.01a");
        await c.SyncWdbAsync(first.Spec, first.Handler);
        File.AppendAllText(Path.Combine(c.WdbDir, WdbCache.ItemCacheName), "client wrote this");

        var second = ItemCacheFile.Build("2026.02.02b");
        var outcome = await c.SyncWdbAsync(second.Spec, second.Handler);

        Check("new epoch: installed", outcome.Installed, outcome.Detail);
        Check("new epoch: the client's edits are gone",
              c.ItemCacheBytes()?.SequenceEqual(second.Plain) == true);
        Check("new epoch: sentinel updated", c.Sentinel() == "2026.02.02b");
    }

    private static async Task DeletedCacheReinstallsDespiteSentinel()
    {
        using var c = new Fixture();
        var cache = ItemCacheFile.Build("2026.01.01a");
        await c.SyncWdbAsync(cache.Spec, cache.Handler);

        // "Delete your Cache folder" is a real thing players are told to do. The sentinel is
        // on disk beside the file precisely so that this reinstalls; a token kept only in
        // state.json would insist it was already there.
        File.Delete(Path.Combine(c.WdbDir, WdbCache.ItemCacheName));

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("deleted cache: reinstalled", outcome.Installed, outcome.Detail);
        Check("deleted cache: bytes back", c.ItemCacheBytes()?.SequenceEqual(cache.Plain) == true);
    }

    private static async Task UnsupportedLocaleFallsBackToWiping()
    {
        using var c = new Fixture(locale: "deDE");
        c.SeedWdb();
        var cache = ItemCacheFile.Build("2026.01.01a");   // locales: enUS only

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("deDE client: nothing installed", !outcome.Installed, outcome.Detail);
        Check("deDE client: nothing downloaded", cache.Handler.Requests == 0);
        Check("deDE client: wiped as before", c.WdbFiles().Count == 0);
    }

    private static async Task BadTransportHashFallsBackToWiping()
    {
        using var c = new Fixture();
        c.SeedWdb();
        var cache = ItemCacheFile.Build("2026.01.01a");
        cache.Spec.Sha256 = new string('0', 64);

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("bad gz hash: nothing installed", !outcome.Installed, outcome.Detail);
        Check("bad gz hash: wiped as before", c.WdbFiles().Count == 0);
        Check("bad gz hash: said so", outcome.Detail.Contains("checksum"), outcome.Detail);
    }

    private static async Task BadContentHashFallsBackToWiping()
    {
        using var c = new Fixture();
        c.SeedWdb();
        var cache = ItemCacheFile.Build("2026.01.01a");
        cache.Spec.ContentSha256 = new string('0', 64);

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("bad content hash: nothing installed", !outcome.Installed, outcome.Detail);
        Check("bad content hash: wiped as before", c.WdbFiles().Count == 0);
    }

    private static async Task NotAWdbFallsBackToWiping()
    {
        using var c = new Fixture();
        c.SeedWdb();

        // Hashes that agree perfectly with a file that is not an item cache — the one failure
        // the pins are structurally unable to notice.
        var cache = ItemCacheFile.Build("2026.01.01a", corruptMagic: true);

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("not a WDB: nothing installed", !outcome.Installed, outcome.Detail);
        Check("not a WDB: wiped as before", c.WdbFiles().Count == 0);
        Check("not a WDB: said so", outcome.Detail.Contains("magic"), outcome.Detail);
    }

    private static async Task DownloadFailureFallsBackToWiping()
    {
        using var c = new Fixture();
        c.SeedWdb();
        var cache = ItemCacheFile.Build("2026.01.01a");
        cache.Handler.Fail = true;

        var outcome = await c.SyncWdbAsync(cache.Spec, cache.Handler);

        Check("host down: did not throw", true);
        Check("host down: nothing installed", !outcome.Installed, outcome.Detail);
        Check("host down: wiped as before", c.WdbFiles().Count == 0);
    }

    /// <summary>
    /// The one that would lock the realm out if it were wrong.
    ///
    /// The integrity check blocks PLAY on an unverified client. It walks baseline.CheckedRoots
    /// ("Data") and treats every manifest.files entry as required — so an item cache that is
    /// under Cache\ and is NOT a manifest file is invisible to it, both before and after the
    /// client has rewritten it. Asserting that rather than assuming it, because the failure
    /// mode is everybody at once.
    /// </summary>
    private static async Task IntegrityCheckIgnoresTheItemCache()
    {
        using var c = new Fixture();
        var cache = ItemCacheFile.Build("2026.01.01a");
        await c.SyncWdbAsync(cache.Spec, cache.Handler);
        File.AppendAllText(Path.Combine(c.WdbDir, WdbCache.ItemCacheName), "client wrote this");

        c.Manifest.ItemCache = cache.Spec;
        var report = await c.VerifyAsync();

        Check("integrity: item cache raises no problem", report.Problems.Count == 0, Describe(report));
        Check("integrity: PLAY still allowed", report.CanPlay);
        Check("integrity: Cache\\ is not a checked root",
              !c.Baseline.CheckedRoots.Contains("Cache"));
    }

    // ---------- resumable download, against a CDN that is behind ----------

    /*
     * ★★ WHY THESE THREE EXIST
     *
     * 2026-08-16: two players, independently, spent over an hour unable to finish an update.
     * Their logs were one line repeating — "416 (Range Not Satisfiable)" — five attempts per
     * launch, unchanged across a dozen relaunches, for the same one file.
     *
     * manifest.json and the payload files are separate URLs on the same CDN and expire
     * independently, so a player can hold a manifest describing release N while an edge still
     * answers with release N-1's bytes. The download then came out the wrong LENGTH, which
     * (a) threw IOException, which SyncService does not classify as a stale host, so the
     * wait-and-resync gate built for exactly this never fired; and (b) left the partial on
     * disk. Every later attempt resumed from the end of that stale body, which is precisely
     * where the stale body ends, so the host answered 416 — forever, because nothing in the
     * loop ever changed `have`.
     *
     * The three cases below pin the three properties that fix it: a 416 discards the partial,
     * a wrong length reads as a mismatch rather than a transport error, and the whole thing
     * heals by itself once the CDN catches up.
     */

    private const int StaleBytes = 137_715;
    private const int FreshBytes = 144_411;

    /// <summary>
    /// The wedge itself. A partial exactly as long as the body the host is still serving must
    /// not produce the same 416 on every attempt until the attempts run out.
    /// </summary>
    private static async Task StalePartialDoesNotWedgeOnA416()
    {
        using var c = new Fixture();
        var host = new RangeHost(Fill(StaleBytes, (byte)'s'));
        var destination = Path.Combine(c.Root, "SoulForge.lua");

        // What the player had on disk: a full copy of the PREVIOUS release, parked as a temp
        // by the length check that rejected it.
        File.WriteAllBytes(ResilientDownload.TempFor(destination), Fill(StaleBytes, (byte)'s'));

        var thrown = await CatchAsync(() => new ResilientDownload(new HttpClient(host))
            .FetchAsync("http://cdn/SoulForge.lua", destination, FreshBytes,
                        Sha256Of(Fill(FreshBytes, (byte)'f')), "SoulForge.lua", null, default,
                        attempts: 2));

        Check("416: the partial was discarded, not retried into",
              host.FullRequests > 0, $"full={host.FullRequests} ranged={host.RangedRequests}");
        Check("416: did not fail with the 416 itself",
              thrown?.Message.Contains("Range") != true, thrown?.Message ?? "(nothing thrown)");
        Check("416: reported as a content mismatch", thrown is InvalidDataException,
              thrown?.GetType().Name ?? "(nothing thrown)");
        Check("416: left no temp behind",
              !File.Exists(ResilientDownload.TempFor(destination)));
    }

    /// <summary>
    /// A short body must surface as InvalidDataException. That type is the whole input to
    /// SyncOutcome.Mismatched → LooksLikeStaleHost → the publish gate's wait-and-resync; as an
    /// IOException it was indistinguishable from a dropped connection and the gate stayed shut.
    /// </summary>
    private static async Task WrongLengthIsClassifiedAsAMismatch()
    {
        using var c = new Fixture();
        var host = new RangeHost(Fill(StaleBytes, (byte)'s'));
        var destination = Path.Combine(c.Root, "Forge.lua");

        var thrown = await CatchAsync(() => new ResilientDownload(new HttpClient(host))
            .FetchAsync("http://cdn/Forge.lua", destination, FreshBytes,
                        Sha256Of(Fill(FreshBytes, (byte)'f')), "Forge.lua", null, default,
                        attempts: 5));

        Check("short body: reported as a mismatch", thrown is InvalidDataException,
              thrown?.GetType().Name ?? "(nothing thrown)");
        // :N0 groups with whatever the machine's locale uses — a comma here, a dot on the
        // German box this first failed on — so compare against the same formatting, not a
        // literal. The message is a player-facing diagnostic; it only has to name both sizes.
        Check("short body: says what the sizes were",
              thrown?.Message.Contains($"{FreshBytes:N0}") == true &&
              thrown?.Message.Contains($"{StaleBytes:N0}") == true, thrown?.Message ?? "");

        // Downloaded whole and still wrong is the host, not the link — one attempt, not five.
        // Five would turn the gate's measured wait into a crawl across ~480 files.
        Check("short body: not retried five times", host.FullRequests == 1,
              $"full={host.FullRequests}");
        Check("short body: left no temp behind",
              !File.Exists(ResilientDownload.TempFor(destination)));
    }

    /// <summary>
    /// The end state that matters to the player: once the CDN serves the new bytes, the next
    /// launch finishes on its own with no intervention and no manual cache clearing.
    ///
    /// Note this needs TWO attempts and is right to. The resume succeeds and reaches the
    /// correct LENGTH, but the first 137,715 bytes are the old release, so only the end-to-end
    /// hash catches it — which is exactly the property the class docs refuse to trade away.
    /// </summary>
    private static async Task StalePartialRecoversOnceTheHostCatchesUp()
    {
        using var c = new Fixture();
        var fresh = Fill(FreshBytes, (byte)'f');
        var host = new RangeHost(fresh);
        var destination = Path.Combine(c.Root, "Transmog.lua");

        File.WriteAllBytes(ResilientDownload.TempFor(destination), Fill(StaleBytes, (byte)'s'));

        var thrown = await CatchAsync(() => new ResilientDownload(new HttpClient(host))
            .FetchAsync("http://cdn/Transmog.lua", destination, FreshBytes,
                        Sha256Of(fresh), "Transmog.lua", null, default, attempts: 5));

        Check("caught-up host: succeeded", thrown is null, thrown?.Message ?? "");
        Check("caught-up host: file is in place", File.Exists(destination));
        Check("caught-up host: bytes are the new release",
              File.Exists(destination) && File.ReadAllBytes(destination).SequenceEqual(fresh));
        Check("caught-up host: stitched copy was not accepted", host.FullRequests == 1,
              $"full={host.FullRequests} ranged={host.RangedRequests}");
        Check("caught-up host: left no temp behind",
              !File.Exists(ResilientDownload.TempFor(destination)));
    }

    private static byte[] Fill(int count, byte value) => Enumerable.Repeat(value, count).ToArray();

    private static string Sha256Of(byte[] body) =>
        Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(body)).ToLowerInvariant();

    /// <summary>Runs an action that is expected to throw, and hands back what it threw.</summary>
    private static async Task<Exception?> CatchAsync(Func<Task> action)
    {
        try { await action(); return null; }
        catch (Exception ex) { return ex; }
    }

    /// <summary>
    /// A static host that honours Range the way nginx and GitHub's CDN do — including the part
    /// that caused the outage: a first-byte offset at or past the end of the body is 416, not
    /// an empty 206.
    /// </summary>
    private sealed class RangeHost : HttpMessageHandler
    {
        private readonly byte[] _body;

        public int FullRequests { get; private set; }
        public int RangedRequests { get; private set; }

        public RangeHost(byte[] body) => _body = body;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var from = request.Headers.Range?.Ranges.FirstOrDefault()?.From;

            if (from is null)
            {
                FullRequests++;
                return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
                {
                    Content = new ByteArrayContent(_body),
                });
            }

            RangedRequests++;

            // RFC 9110: the first-byte-pos must be strictly less than the current length.
            if (from.Value >= _body.Length)
                return Task.FromResult(
                    new HttpResponseMessage(System.Net.HttpStatusCode.RequestedRangeNotSatisfiable));

            var tail = _body[(int)from.Value..];
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.PartialContent)
            {
                Content = new ByteArrayContent(tail),
            });
        }
    }

    /// <summary>A published item cache, built in memory so the hashes are right by construction.</summary>
    private sealed class ItemCacheFile
    {
        public required byte[] Plain { get; init; }
        public required ItemCacheSpec Spec { get; init; }
        public required StubHost Handler { get; init; }

        public static ItemCacheFile Build(string epoch, bool corruptMagic = false)
        {
            // Header (24) + one {entry,size,payload} record + the eight-zero terminator.
            var plain = new List<byte>();
            plain.AddRange(corruptMagic ? "NOPE"u8.ToArray() : "BDIW"u8.ToArray());
            plain.AddRange(BitConverter.GetBytes(12340u));
            plain.AddRange("SUne"u8.ToArray());
            plain.AddRange(BitConverter.GetBytes(516u));
            plain.AddRange(BitConverter.GetBytes(5u));
            plain.AddRange(BitConverter.GetBytes(17u));
            plain.AddRange(BitConverter.GetBytes(900600u));       // entry
            plain.AddRange(BitConverter.GetBytes(4u));            // payload size
            plain.AddRange(BitConverter.GetBytes(1u));            // payload
            plain.AddRange(new byte[8]);                          // terminator

            var raw = plain.ToArray();

            using var packed = new MemoryStream();
            using (var gzip = new System.IO.Compression.GZipStream(
                       packed, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true))
                gzip.Write(raw);

            var gz = packed.ToArray();

            return new ItemCacheFile
            {
                Plain = raw,
                Handler = new StubHost(gz),
                Spec = new ItemCacheSpec
                {
                    Epoch = epoch,
                    Url = $"http://patches.invalid/itemcache-{epoch}.wdb.gz",
                    Sha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(gz)).ToLowerInvariant(),
                    Size = gz.Length,
                    ContentSha256 = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(raw)).ToLowerInvariant(),
                    ContentSize = raw.Length,
                    // Locales deliberately left at its default of enUS only, which is what a
                    // manifest that forgets the field must fall back to.
                },
            };
        }
    }

    /// <summary>
    /// Serves the bytes from memory and counts requests. A real socket would need a listener
    /// port and a URL ACL; the count is the assertion that matters anyway — "did this launch
    /// re-download 1.7 MB" is the question the epoch design exists to answer.
    /// </summary>
    private sealed class StubHost : HttpMessageHandler
    {
        private readonly byte[] _body;
        public int Requests { get; private set; }
        public bool Fail { get; set; }

        public StubHost(byte[] body) => _body = body;

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;

            if (Fail) throw new HttpRequestException("the patch host is unreachable");

            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new ByteArrayContent(_body),
            });
        }
    }

    // ---------- fixture ----------

    /// <summary>
    /// A throwaway client tree, plus the manifest and baseline that describe it. Everything is
    /// generated, so the hashes are correct by construction and a fault has to be introduced
    /// deliberately.
    /// </summary>
    private sealed class Fixture : IDisposable
    {
        public string Root { get; }
        public string Client { get; }
        public Manifest Manifest { get; }
        public Baseline Baseline { get; }
        public LauncherState State { get; private set; } = new();

        private readonly string _locale;

        public Fixture(string locale = "enUS")
        {
            _locale = locale;
            Root = Path.Combine(Path.GetTempPath(), "uncapped-integrity-" + Guid.NewGuid().ToString("N")[..8]);
            Client = Path.Combine(Root, "client");
            Directory.CreateDirectory(Client);

            // Stock client files.
            Write("Data/common.MPQ", "common archive contents");
            Write("Data/patch.MPQ", "patch archive contents");
            Write("Scan.dll", "a stock dll");
            Write($"Data/{locale}/base-{locale}.MPQ", "base locale archive");
            Write($"Data/{locale}/locale-{locale}.MPQ", "locale archive");
            Write($"Data/{locale}/Credits.html", "<html>credits</html>");

            // Files we publish.
            Write($"Data/{locale}/patch-{locale}-Q.MPQ", "our content patch");
            Write("Interface/AddOns/UncappedVersion/UncappedVersion.lua", "CLIENT_VERSION = 41");
            Write("UncappedClient.dat", "the patched client");

            Baseline = new Baseline
            {
                ClientBuild = "12340",
                Locale = "enUS",
                CheckedRoots = { "Data" },
                CheckRootFiles = { ".exe", ".dll" },
                SkipRoots = { "Cache", "WTF", "Logs", "Errors", "Screenshots", "Interface" },
                ToleratedNames = { "UncappedClient.dat", "UncappedCT.dll", "Uncapped.exe",
                                   "uncapped.config.json", "realmlist.wtf", "Wow.exe", "Repair.exe" },
                ToleratedPatterns = { "*.log", "*.bak", "*.tmp", "*.uncapped-tmp", "*.retired-*",
                                      "*.disabled-for-testing", "*-backup", "Thumbs.db", "desktop.ini" },
                Files =
                {
                    Entry("Data/common.MPQ", required: true),
                    Entry("Data/patch.MPQ", required: true),
                    Entry("Scan.dll", required: true),
                    Entry("Data/enUS/base-enUS.MPQ", required: true, isLocale: true),
                    Entry("Data/enUS/locale-enUS.MPQ", required: true, isLocale: true),
                    Entry("Data/enUS/Credits.html", required: false, isLocale: true),
                },
            };

            Manifest = new Manifest
            {
                Files =
                {
                    ManifestEntry("Data/enUS/patch-enUS-Q.MPQ"),
                    ManifestEntry("Interface/AddOns/UncappedVersion/UncappedVersion.lua"),
                    ManifestEntry("UncappedClient.dat"),
                },
            };
        }

        /// <summary>
        /// Baseline entries are hashed from the ENGLISH tree even when the fixture is another
        /// locale, because that is what a published baseline is: taken from one locale, and
        /// therefore inapplicable to the others. The deDE fixture is meant to be unverifiable.
        /// </summary>
        private BaselineFile Entry(string path, bool required, bool isLocale = false)
        {
            var onDisk = path.Replace("enUS", _locale);
            var full = Path.Combine(Client, onDisk.Replace('/', Path.DirectorySeparatorChar));

            return new BaselineFile
            {
                Path = path,
                Sha256 = HashOf(full),
                Size = File.Exists(full) ? new FileInfo(full).Length : 0,
                Required = required,
                Locale = isLocale,
                Url = required ? "http://152.53.115.249/base/" + path.Replace('/', '-') : null,
            };
        }

        private ManifestFile ManifestEntry(string path)
        {
            var onDisk = path.Replace("enUS", _locale);
            var full = Path.Combine(Client, onDisk.Replace('/', Path.DirectorySeparatorChar));

            return new ManifestFile
            {
                Path = path,
                Sha256 = HashOf(full),
                Size = new FileInfo(full).Length,
                Url = "https://example.invalid/" + path,
            };
        }

        private static string HashOf(string full) =>
            File.Exists(full) ? Hashing.Sha256FileAsync(full).GetAwaiter().GetResult() : "";

        public void Write(string relative, string contents)
        {
            var full = Path.Combine(Client, relative.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            File.WriteAllText(full, contents);
        }

        // ---- Cache\WDB helpers ----

        /// <summary>Where this client's WDB cache lives, named for its own locale.</summary>
        public string WdbDir => Path.Combine(Client, "Cache", "WDB", _locale);

        /// <summary>
        /// The state a played-in client is in: an item cache plus the other caches the
        /// launcher has always wiped and still does.
        /// </summary>
        public void SeedWdb(bool itemCache = true)
        {
            Directory.CreateDirectory(WdbDir);
            File.WriteAllText(Path.Combine(WdbDir, "creaturecache.wdb"), "someone else's creatures");
            File.WriteAllText(Path.Combine(WdbDir, "questcache.wdb"), "someone else's quests");
            if (itemCache)
                File.WriteAllText(Path.Combine(WdbDir, WdbCache.ItemCacheName), "someone else's items");
        }

        public List<string> WdbFiles()
        {
            var dir = Path.Combine(Client, "Cache", "WDB");
            return Directory.Exists(dir)
                ? Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)
                           .Select(Path.GetFileName).ToList()!
                : new List<string>();
        }

        public byte[]? ItemCacheBytes()
        {
            var path = Path.Combine(WdbDir, WdbCache.ItemCacheName);
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }

        public string? Sentinel()
        {
            var path = Path.Combine(WdbDir, WdbCache.SentinelName);
            return File.Exists(path) ? File.ReadAllText(path) : null;
        }

        public async Task<WdbOutcome> SyncWdbAsync(ItemCacheSpec? itemCache, HttpMessageHandler? host = null)
        {
            Manifest.ItemCache = itemCache;
            var locale = ClientLocale.Detect(Client);
            var http = host is null ? new HttpClient() : new HttpClient(host, disposeHandler: false);
            return await new WdbCache(http).SyncAsync(Client, Manifest, locale, CancellationToken.None);
        }

        public async Task<IntegrityReport> VerifyAsync()
        {
            var locale = ClientLocale.Detect(Client);
            if (locale is null) throw new InvalidOperationException("fixture is not a playable client");

            var progress = new Progress<SyncProgress>(_ => { });
            return await new IntegrityVerifier(Client, Manifest, Baseline, locale, State)
                .VerifyAsync(progress, CancellationToken.None);
        }

        public void Dispose()
        {
            try { Directory.Delete(Root, recursive: true); } catch { /* best effort */ }
        }
    }

    // ---------- plumbing ----------

    private static string Describe(IntegrityReport report) =>
        report.Problems.Count == 0
            ? "(no problems)"
            : string.Join("; ", report.Problems.Select(p => $"{p.Fault}{(p.Blocking ? "!" : "")} {p.Path}"));

    private static void Check(string name, bool condition, string? detail = null)
    {
        if (condition)
        {
            _passed++;
            Console.WriteLine($"  PASS  {name}");
        }
        else
        {
            _failed++;
            Console.WriteLine($"  FAIL  {name}{(detail is null ? "" : $"  —  {detail}")}");
        }
    }

    private static string? BackUpLiveState()
    {
        // See the class comment: this cannot be redirected, so it has to be preserved.
        var live = AppPaths.StateFile;
        if (!File.Exists(live)) return null;

        var backup = live + ".integritytests-backup";
        File.Copy(live, backup, overwrite: true);
        Console.WriteLine($"Backed up live state.json ({new FileInfo(live).Length:N0} bytes)");
        return backup;
    }

    private static void RestoreLiveState(string? backup)
    {
        var live = AppPaths.StateFile;

        if (backup is null)
        {
            // There was none before; leave none behind.
            try { if (File.Exists(live)) File.Delete(live); } catch { }
            return;
        }

        try
        {
            File.Copy(backup, live, overwrite: true);
            File.Delete(backup);
            Console.WriteLine($"Restored live state.json ({new FileInfo(live).Length:N0} bytes)");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"WARNING: could not restore state.json — {ex.Message}");
            Console.WriteLine($"         the backup is still at {backup}");
        }
    }
}
