using System.IO.Compression;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>What the WDB pass did this launch. One line for launcher.log.</summary>
public sealed record WdbOutcome(string Detail, int Deleted, bool Installed);

/// <summary>
/// Manages Cache\WDB — the client's cache of server-sent item/creature/quest data.
///
/// WHY IT IS TOUCHED AT ALL
///
/// The client caches every query response it ever receives here and never expires an entry.
/// Change an item on the server and anyone who already saw it keeps the stale copy forever,
/// which reads to players as a server bug (report #224: blank icons on items whose displayid
/// and texture are both correct on our side).
///
/// Worse, the cache is keyed by entry id and is NOT namespaced per realm, so it is shared with
/// every other server the player connects to using this client — their item 900400 silently
/// becomes ours. That contaminating case never touches our payload at all, which is why this
/// used to WIPE unconditionally on every launch rather than only when something we ship
/// changed: there is no signal on our side to gate it on.
///
/// WHAT CHANGED, AND WHY THE GUARANTEE SURVIVES
///
/// We now generate itemcache.wdb server-side (Server/azerothcore-wotlk/tools/wdb/gen_itemcache.py)
/// and install it. An authoritative file supersedes the contamination argument for THAT file —
/// our bytes win regardless of who wrote what was there before — but only for that file. So:
///
///   * every other .wdb under Cache\WDB is still wiped on EVERY launch, exactly as before.
///     creaturecache, questcache, gameobjectcache and friends are not something we ship, so
///     the old reasoning still applies to them in full;
///   * itemcache.wdb is wiped and replaced whenever the epoch changes, and left alone
///     otherwise;
///   * if anything at all goes wrong — no manifest block, a locale we did not generate for, a
///     failed download, a hash mismatch, a file that is not a WDB — we fall back to wiping
///     everything, which is precisely the old behaviour. The feature is fail-safe by
///     construction: the worst case is the client we shipped last month.
///
/// ⚠ THE TRIGGER IS AN EPOCH TOKEN, NOT A FILE HASH.
///
/// The client REWRITES itemcache.wdb continuously during play — it appends every new query
/// response. Its hash therefore stops matching whatever we installed within seconds of the
/// player logging in, and never matches again. Hash-based change detection would re-download
/// ~1.7 MB on every single launch, forever, and would report the file as corrupt to anything
/// that checked it. So the launcher records the epoch it installed in a sentinel FILE BESIDE
/// the cache, which the client has no idea exists and never touches, and compares that.
///
/// The sentinel lives on disk rather than in %LOCALAPPDATA%\Uncapped\state.json on purpose: a
/// player who deletes their Cache folder (a genuinely common "fix it" step) must get the file
/// back, and a token kept only in the state file would say it was already installed.
/// </summary>
public sealed class WdbCache
{
    /// <summary>
    /// Beside the cache it describes. The client opens WDB files by exact name and never
    /// enumerates the folder, so an extra file here is inert to it.
    /// </summary>
    public const string SentinelName = "uncapped-itemcache.epoch";

    public const string ItemCacheName = "itemcache.wdb";

    /// <summary>
    /// First four bytes of a 3.3.5a itemcache.wdb: "WDBI" stored byte-reversed. Cheap proof
    /// that what we decompressed is the kind of file we think it is.
    /// </summary>
    private static readonly byte[] Magic = { (byte)'B', (byte)'D', (byte)'I', (byte)'W' };

    private const uint ExpectedBuild = 12340;

    /// <summary>Header (24) + terminator (8). The empty cache the client writes on a fresh install.</summary>
    private const int MinimumSize = 32;

    private readonly HttpClient _http;

    public WdbCache(HttpClient http) => _http = http;

    /// <summary>
    /// Brings Cache\WDB into the state the manifest asks for. Never throws: every failure
    /// path ends in a full wipe, which is a correct client.
    /// </summary>
    public async Task<WdbOutcome> SyncAsync(
        string installPath, Manifest manifest, ClientLocale? locale, CancellationToken ct)
    {
        var spec = manifest.ItemCache;

        // ---- The off switch. One edit to tools/itemcache.json drops this block from the
        // manifest and every client returns to the old wipe-everything behaviour on its next
        // launch, with no launcher release. That is the rollback for this whole feature.
        if (spec is null || !spec.IsUsable)
            return new WdbOutcome("cleared (no item cache published)", WipeAll(installPath), false);

        // ---- The generated file carries a hardcoded enUS locale in its header and is built
        // from base item_template strings, so it is only correct for an enUS client. A deDE
        // player gets the old behaviour rather than an English cache we cannot vouch for.
        var code = locale?.Code;
        if (code is null || !spec.AppliesToLocale(code))
            return new WdbOutcome(
                $"cleared (no item cache generated for locale {code ?? "unknown"})",
                WipeAll(installPath), false);

        var dir = Path.Combine(installPath, "Cache", "WDB", code);
        var target = Path.Combine(dir, ItemCacheName);
        var sentinel = Path.Combine(dir, SentinelName);

        // ---- Already current: leave itemcache.wdb and its sentinel alone, wipe the rest.
        // Both halves have to be true. The sentinel alone would survive a player deleting the
        // cache file itself, and the file alone tells us nothing about which epoch it is.
        if (File.Exists(target) && ReadSentinel(sentinel) == spec.Epoch)
        {
            var swept = WipeAll(installPath, keep: new[] { target, sentinel });
            return new WdbOutcome($"item cache epoch {spec.Epoch} already installed", swept, false);
        }

        // Staged beside its destination, not in %TEMP%: the game is often on a different
        // drive from the system one, and a 21 MB file has to land with a same-volume rename
        // rather than a cross-volume copy that can fail or half-write.
        Directory.CreateDirectory(dir);
        var staged = target + $".{Guid.NewGuid():N}.uncapped-tmp";

        try
        {
            // Download and validate BEFORE destroying anything. A failure here must leave the
            // player with a wiped cache, not a half-written one.
            await FetchAsync(spec, staged, ct);

            // The staged file is itself under Cache\WDB, so it has to survive the sweep that
            // clears everything else out from under it.
            var deleted = WipeAll(installPath, keep: new[] { staged });
            File.Move(staged, target, overwrite: true);

            File.WriteAllText(sentinel, spec.Epoch);

            return new WdbOutcome(
                $"installed item cache epoch {spec.Epoch} ({new FileInfo(target).Length:N0} bytes)",
                deleted, true);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            // Fail-safe, not fail-open: the old unconditional wipe is the fallback, so a bad
            // download costs the player a re-cached session and nothing else.
            var deleted = WipeAll(installPath);
            return new WdbOutcome($"cleared (item cache install failed: {ex.Message})", deleted, false);
        }
        finally
        {
            if (File.Exists(staged)) { try { File.Delete(staged); } catch { /* best effort */ } }
        }
    }

    /// <summary>
    /// Downloads the published cache, checks it against both pinned hashes and the WDB layout,
    /// and leaves the decompressed file at <paramref name="plain"/>. Throws on anything that
    /// does not add up, having cleaned up after itself.
    /// </summary>
    private async Task FetchAsync(ItemCacheSpec spec, string plain, CancellationToken ct)
    {
        // The compressed half is small enough (~1.7 MB) that %TEMP% is fine for it.
        var packed = Path.Combine(Path.GetTempPath(), $"uncapped-wdb-{Guid.NewGuid():N}.gz");

        try
        {
            using (var response = await _http.GetAsync(spec.Url, HttpCompletionOption.ResponseHeadersRead, ct))
            {
                response.EnsureSuccessStatusCode();

                await using var source = await response.Content.ReadAsStreamAsync(ct);
                await using var file = new FileStream(packed, FileMode.Create, FileAccess.Write,
                                                      FileShare.None, 1024 * 64, useAsync: true);
                await source.CopyToAsync(file, ct);
            }

            // Transport pin: the bytes the host served are the bytes we published. Same
            // guarantee the MPQs get, and the reason a compromised or confused host cannot
            // push an item table of its choosing into every client.
            var packedHash = await Hashing.Sha256FileAsync(packed, ct);
            if (!Hashing.Matches(packedHash, spec.Sha256))
                throw new InvalidDataException(
                    $"download checksum mismatch (expected {Short(spec.Sha256)}, got {Short(packedHash)})");

            await using (var source = new FileStream(packed, FileMode.Open, FileAccess.Read,
                                                     FileShare.Read, 1024 * 64, useAsync: true))
            await using (var gzip = new GZipStream(source, CompressionMode.Decompress))
            await using (var file = new FileStream(plain, FileMode.Create, FileAccess.Write,
                                                   FileShare.None, 1024 * 64, useAsync: true))
                await gzip.CopyToAsync(file, ct);

            // Content pin: what came OUT of the gzip is what we generated. The transport pin
            // cannot say anything about that, and this is the file the client actually parses.
            if (!string.IsNullOrEmpty(spec.ContentSha256))
            {
                var plainHash = await Hashing.Sha256FileAsync(plain, ct);
                if (!Hashing.Matches(plainHash, spec.ContentSha256))
                    throw new InvalidDataException(
                        $"decompressed checksum mismatch (expected {Short(spec.ContentSha256)}, got {Short(plainHash)})");
            }

            // And it has to actually be one of these. Belt and braces over the hash, because
            // the failure this guards is a correct hash pinned against the wrong file — the
            // one thing the pins are structurally unable to notice.
            CheckLooksLikeItemCache(plain, spec.ContentSize);
        }
        catch
        {
            if (File.Exists(plain)) { try { File.Delete(plain); } catch { /* best effort */ } }
            throw;
        }
        finally
        {
            if (File.Exists(packed)) { try { File.Delete(packed); } catch { /* best effort */ } }
        }
    }

    /// <summary>
    /// The file layout, asserted: 24-byte header (magic, build, locale, three constants), then
    /// {entry, size, payload} records, then eight zero bytes. Only the parts that are cheap to
    /// check from the ends are checked — walking 47,000 records would buy nothing the content
    /// hash has not already bought.
    /// </summary>
    private static void CheckLooksLikeItemCache(string path, long expectedSize)
    {
        var info = new FileInfo(path);

        if (info.Length < MinimumSize)
            throw new InvalidDataException($"decompressed to {info.Length} bytes, too small to be a WDB");

        if (expectedSize > 0 && info.Length != expectedSize)
            throw new InvalidDataException(
                $"decompressed to {info.Length} bytes, manifest says {expectedSize}");

        using var stream = File.OpenRead(path);

        var head = new byte[8];
        stream.ReadExactly(head);

        for (var i = 0; i < Magic.Length; i++)
            if (head[i] != Magic[i])
                throw new InvalidDataException("not a WDB file (bad magic)");

        var build = BitConverter.ToUInt32(head, 4);
        if (build != ExpectedBuild)
            throw new InvalidDataException($"WDB is for client build {build}, expected {ExpectedBuild}");

        var tail = new byte[8];
        stream.Seek(-8, SeekOrigin.End);
        stream.ReadExactly(tail);

        if (tail.Any(b => b != 0))
            throw new InvalidDataException("WDB does not end in the eight-zero-byte terminator");
    }

    /// <summary>
    /// The old unconditional clear, now with an exemption list. Everything under Cache\WDB
    /// goes except the files named — which is only ever our own itemcache.wdb and its epoch
    /// sentinel, and only when they are already the version the manifest asks for.
    /// </summary>
    public static int WipeAll(string installPath, IReadOnlyCollection<string>? keep = null)
    {
        var wdb = Path.Combine(installPath, "Cache", "WDB");
        if (!Directory.Exists(wdb)) return 0;

        var spared = keep is null
            ? null
            : new HashSet<string>(keep, StringComparer.OrdinalIgnoreCase);

        var deleted = 0;
        foreach (var file in Directory.EnumerateFiles(wdb, "*", SearchOption.AllDirectories))
        {
            if (spared is not null && spared.Contains(file)) continue;

            try { File.Delete(file); deleted++; }
            catch { /* a locked cache file is not worth failing the whole sync over */ }
        }
        return deleted;
    }

    private static string? ReadSentinel(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path).Trim() : null; }
        catch { return null; }
    }

    private static string Short(string hash) =>
        string.IsNullOrEmpty(hash) ? "(none)" : hash[..Math.Min(12, hash.Length)] + "…";
}
