using System.IO.Compression;
using MonoTorrent;
using MonoTorrent.Client;
using Uncapped.Model;

namespace Uncapped.Services;

public sealed record AcquireProgress(string Status, double Fraction, string Detail);

/// <summary>
/// One file of the stock client that we host ourselves and pin by hash.
///
/// This is the type that closes the hole described on <see cref="ClientAcquirer"/>: every
/// entry here comes from the same <see cref="Baseline"/> the integrity check verifies
/// against, so a file installed through this path cannot disagree with the file the
/// verifier is about to demand.
/// </summary>
/// <param name="RelativePath">Install-root-relative, already normalised for this OS.</param>
public sealed record ClientBaseFile(string RelativePath, string Url, string Sha256, long Size);

/// <summary>
/// Fetches the base client when the player has none, via BitTorrent, with an HTTP fallback.
///
/// Two deliberate choices here:
///
/// - Outbound-only by default (no inbound listener, DHT off). A torrent client that accepts
///   inbound connections triggers a Windows Firewall dialog on first run, which is exactly
///   the kind of scary prompt worth avoiding for an unsigned binary. The cost is slower peer
///   discovery; the magnet's trackers still supply peers. Flip torrentAllowInbound in the
///   config if the swarm proves hard to reach.
///
/// - Disk space is checked before a single byte is transferred. The archive and its
///   extraction coexist, so roughly twice the client size must be free.
///
/// ★★ WHY ACQUISITION ENDS BY PULLING FILES FROM OUR OWN HOST
///
/// Whatever an archive hands us is then judged by <see cref="IntegrityVerifier"/> against
/// <see cref="Baseline"/>, and until 2026-08-12 nothing guaranteed those two agreed. They did
/// not. The Internet Archive's WoW_3.3.5-12340 item is a DIFFERENT 3.3.5a build from the one
/// the baseline was generated against -- six required files differ:
///
///     Data/common-2.MPQ   1,810,430,636 expected   1,814,309,500 shipped
///     Data/common.MPQ     2,881,154,862 expected   2,884,769,683 shipped
///     Data/expansion.MPQ  1,921,219,911 expected   1,923,425,963 shipped
///     Data/lichking.MPQ   2,553,948,549 expected   2,581,186,393 shipped
///     Data/patch-2.MPQ    1,401,729,059 expected   1,403,129,115 shipped
///     Scan.dll                   47,876 expected          52,996 shipped
///
/// Six differed and exactly those six were flagged; the two that matched passed. So anyone
/// whose network blocked BitTorrent downloaded 17 GB through our own launcher and was then
/// told by that same launcher that their files were corrupt, with PLAY permanently disabled.
/// Their files were fine. We shipped them the wrong build.
///
/// The fix is structural rather than a new hash to trust: after ANY acquisition path, every
/// required baseline file is checked and re-fetched from our host if it does not match. The
/// archive becomes a fast way to get most of the bytes, never the authority on what they
/// should be. That makes this class incapable of producing a client its own verifier rejects,
/// which is the property that was missing.
///
/// The locale half is deliberately still taken from the Archive's per-language zip: it is the
/// only source for Data/enUS/Interface/Cinematics and the Documentation tree, which we do not
/// host, and it was measured to match the baseline exactly -- all 11 required MPQs and all 136
/// tail entries. If that ever stops being true the loop below simply re-downloads them from us.
/// </summary>
public sealed class ClientAcquirer
{
    /// <summary>
    /// Attempts per base file before giving up. Each attempt RESUMES rather than restarting,
    /// so a link that drops every few minutes still finishes a 4 GB MPQ.
    /// </summary>
    private const int BaseFileAttempts = 5;

    private readonly HttpClient _http;
    private readonly bool _allowInbound;

    public ClientAcquirer(HttpClient http, bool allowInbound)
    {
        _http = http;
        _allowInbound = allowInbound;
    }

    private static string? DriveOf(string dir)
    {
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(dir));
            return string.IsNullOrEmpty(root) ? null : root;
        }
        catch { return null; }
    }

    private static long FreeOn(string drive)
    {
        try { return new DriveInfo(drive).AvailableFreeSpace; }
        catch { return long.MaxValue; } // unknown drive: do not block on a check we cannot make
    }

    /// <summary>
    /// The archive downloads to %LOCALAPPDATA% and extracts to the install folder, which are
    /// often on different drives. Checking only the install drive would let C: fill up
    /// silently. Both are checked, and combined when they are the same drive.
    /// </summary>
    /// <param name="largestBaseFile">
    /// Size of the biggest file fetched from our host, which needs room on the INSTALL drive
    /// rather than the download drive -- base files stream to a .uncapped-tmp beside their
    /// destination and are moved into place, so they never pass through %LOCALAPPDATA%.
    ///
    /// It is counted on top of the installed size because the two genuinely coexist whenever an
    /// archive already put a copy of that file there: the wrong 4 GB patch.MPQ is still on disk
    /// while the right one downloads next to it. On the intended manifest, where the archive
    /// supplies only the locale folder, this is headroom rather than a real requirement -- and
    /// headroom on a check that already refuses installs is the correct direction to be wrong in.
    /// </param>
    public static void EnsureEnoughSpace(string targetDir, ClientSource source, long largestBaseFile = 0)
    {
        var downloadDrive = DriveOf(AppPaths.DownloadDir);
        var installDrive = DriveOf(targetDir);
        if (downloadDrive is null || installDrive is null) return;

        var installNeeded = source.InstalledBytes + Math.Max(0, largestBaseFile);
        var sameDrive = string.Equals(downloadDrive, installDrive, StringComparison.OrdinalIgnoreCase);

        if (sameDrive)
        {
            var needed = source.PeakArchiveBytes() + installNeeded;
            var free = FreeOn(installDrive);
            if (free < needed)
                throw new IOException(
                    $"Not enough space on {installDrive.TrimEnd('\\')}. The download and the unpacked " +
                    $"game exist side by side for a while, so about {Gb(needed)} is needed but only " +
                    $"{Gb(free)} is free.");
            return;
        }

        var freeDownload = FreeOn(downloadDrive);
        if (freeDownload < source.PeakArchiveBytes())
            throw new IOException(
                $"Not enough space on {downloadDrive.TrimEnd('\\')} for the download. About " +
                $"{Gb(source.PeakArchiveBytes())} is needed there (the launcher downloads to " +
                $"{AppPaths.DownloadDir}), but only {Gb(freeDownload)} is free.");

        var freeInstall = FreeOn(installDrive);
        if (freeInstall < installNeeded)
            throw new IOException(
                $"Not enough space on {installDrive.TrimEnd('\\')} for the game. About " +
                $"{Gb(installNeeded)} is needed but only {Gb(freeInstall)} is free.");
    }

    /// <summary>
    /// The authoritative file list for a fresh install: every required baseline file we
    /// publish a download for, plus the client executable.
    ///
    /// The executable is here because the baseline deliberately does not carry one. Hardening
    /// renames Wow.exe and <see cref="LargeAddressAware"/> rewrites two bytes of its PE header,
    /// so its hash on a real install is never the stock hash and baselining it would flag every
    /// client we ship. It lives in the manifest instead, as UncappedClient.dat.
    ///
    /// That matters more than it looks: <see cref="InstallLocator.Validate"/> runs the moment
    /// acquisition returns and rejects a folder with no game executable. The archive used to
    /// supply Wow.exe, so dropping the archive without supplying the executable here would
    /// produce a freshly downloaded client that the launcher refuses as incomplete.
    /// </summary>
    public static IReadOnlyList<ClientBaseFile> BaseFilesFrom(Baseline? baseline, Manifest manifest)
    {
        var files = new List<ClientBaseFile>();

        if (baseline is not null)
        {
            foreach (var file in baseline.Files)
            {
                if (!file.Required) continue;

                // A required file with no published download cannot be repaired or acquired.
                // Skipping it is right: the alternative is inventing a URL.
                if (string.IsNullOrWhiteSpace(file.Url) || string.IsNullOrEmpty(file.Sha256)) continue;

                var relative = SyncService.NormalizeRelative(file.Path);
                if (relative is null) continue;

                files.Add(new ClientBaseFile(relative, file.Url!, file.Sha256, file.Size));
            }
        }

        var exe = manifest.Files.FirstOrDefault(f =>
            string.Equals(f.Path, ClientExecutable.HiddenName, StringComparison.OrdinalIgnoreCase));

        if (exe is not null && !string.IsNullOrWhiteSpace(exe.Url) && !string.IsNullOrEmpty(exe.Sha256))
        {
            var relative = SyncService.NormalizeRelative(exe.Path);
            if (relative is not null)
                files.Add(new ClientBaseFile(relative, exe.Url, exe.Sha256, exe.Size));
        }

        return files;
    }

    /// <param name="baseFiles">
    /// What this install must end up containing, from <see cref="BaseFilesFrom"/>. Empty is
    /// allowed and means "archives only" -- the pre-1.10 behaviour, reached when the manifest
    /// publishes no baselineUrl at all.
    /// </param>
    public async Task<string> AcquireAsync(
        ClientSource source,
        IReadOnlyList<ClientBaseFile> baseFiles,
        string targetDir,
        IProgress<AcquireProgress> progress,
        CancellationToken ct)
    {
        EnsureEnoughSpace(targetDir, source, baseFiles.Count == 0 ? 0 : baseFiles.Max(f => f.Size));

        Directory.CreateDirectory(targetDir);
        Directory.CreateDirectory(AppPaths.DownloadDir);

        /*
         * The HTTP route can be several archives, not one.
         *
         * Mirrors do not all ship a single file -- the Internet Archive's copy is split into
         * a ~14 GB Common.zip plus a per-language zip. Downloading only the first would give
         * a client with no locale data: it installs, it launches, and it is broken in a way
         * that looks like our bug rather than a half-finished download. So the fallback
         * works in terms of a LIST, and a single directDownloadUrl is just a list of one.
         */
        var httpArchives = source.HttpArchives();

        Log.Write($"client acquire: target={targetDir} magnet={(string.IsNullOrWhiteSpace(source.Magnet) ? "no" : "yes")} " +
                  $"httpParts={httpArchives.Count} baseFiles={baseFiles.Count}");

        var gotArchive = false;

        if (!string.IsNullOrWhiteSpace(source.Magnet))
        {
            try
            {
                Log.Write("client acquire: trying BitTorrent");
                var archive = await DownloadViaTorrentAsync(source, progress, ct);
                Log.Write($"client acquire: torrent finished -> {archive}");
                await ExtractAndDeleteAsync(archive, targetDir, progress, ct);
                Log.Write("client acquire: unpacked via torrent");
                gotArchive = true;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex) when (httpArchives.Count > 0)
            {
                // Some ISPs and most corporate/university networks throttle or block
                // BitTorrent outright. Say so plainly, then try the mirror.
                Log.Write($"client acquire: torrent failed ({ex.GetType().Name}: {ex.Message}) -- falling back to HTTP");
                progress.Report(new AcquireProgress(
                    "BitTorrent did not work — trying the direct download instead.", 0, ex.Message));
            }
        }

        if (!gotArchive && httpArchives.Count == 0)
            throw new InvalidOperationException("The manifest lists no way to download the client.");

        if (!gotArchive)
        {
            /*
             * One at a time, extracting each before fetching the next.
             *
             * Not all-then-extract: holding every part on disk at once would need 16 GB of
             * downloads beside the unpacked game, on a drive we have already told the player only
             * needs room for the largest single part.
             */
            for (var i = 0; i < httpArchives.Count; i++)
            {
                var part = httpArchives[i];
                var label = httpArchives.Count > 1 ? $" (part {i + 1} of {httpArchives.Count})" : "";

                Log.Write($"client acquire: HTTP part {i + 1}/{httpArchives.Count} " +
                          $"({part.Bytes} bytes expected) {part.Url}");

                var archive = await DownloadOneAsync(part, label, progress, ct);
                await ExtractAndDeleteAsync(archive, targetDir, progress, ct);

                Log.Write($"client acquire: HTTP part {i + 1}/{httpArchives.Count} extracted");
            }

            Log.Write("client acquire: archives unpacked via HTTP");
        }

        /*
         * ★ LAST, AND OVER THE TOP OF WHATEVER THE ARCHIVE LEFT.
         *
         * Ordering is the safety property, not an implementation detail. Our files are written
         * AFTER the archive is expanded, so if a manifest still lists an archive carrying the
         * wrong build, the correct bytes overwrite the wrong ones rather than the other way
         * round. Acquisition is therefore correct whether or not the manifest has been
         * updated -- the manifest edit only decides how much is downloaded needlessly, never
         * whether the result is right. Given that a partly-updated manifest has silently broken
         * this launcher twice before, that independence is worth the extra pass.
         */
        await EnsureBaseFilesAsync(baseFiles, targetDir, progress, ct);

        Log.Write("client acquire: done");
        return targetDir;
    }

    /// <summary>
    /// Brings every hosted base file to the exact bytes the baseline names, downloading only
    /// what is not already right.
    ///
    /// The skip check is what keeps this cheap. After the locale zip is expanded, its 11
    /// required MPQs already hash correctly and cost nothing but a read; the ~16 GB the Archive
    /// gets wrong is what actually transfers. It also means a retried install resumes at file
    /// granularity for free, and that a future change to either side self-corrects here instead
    /// of becoming a support thread.
    /// </summary>
    private async Task EnsureBaseFilesAsync(
        IReadOnlyList<ClientBaseFile> files, string targetDir,
        IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        if (files.Count == 0)
        {
            // Reached only when the manifest publishes no baselineUrl, i.e. integrity checking
            // is switched off wholesale. Worth a log line, because it is also what a failed
            // baseline fetch would look like from in here.
            Log.Write("client acquire: no base file list; leaving the archive's files as they are");
            return;
        }

        progress.Report(new AcquireProgress("Checking the game files", 0, ""));

        // Which ones actually need fetching. Done as its own pass so the progress bar can be
        // driven by bytes remaining rather than jumping about as each file is examined.
        var needed = new List<ClientBaseFile>();
        long neededBytes = 0;
        var examined = 0;

        foreach (var file in files)
        {
            ct.ThrowIfCancellationRequested();

            var full = Path.Combine(targetDir, file.RelativePath);

            // Reported per file: after a torrent this pass reads the whole 17 GB client to
            // confirm it, which is ten seconds or so of a bar that would otherwise sit still.
            progress.Report(new AcquireProgress(
                "Checking the game files",
                (double)examined / files.Count,
                Path.GetFileName(file.RelativePath)));

            examined++;

            if (await AlreadyCorrectAsync(full, file, ct)) continue;

            needed.Add(file);
            neededBytes += file.Size;
        }

        Log.Write($"client acquire: base files — {files.Count - needed.Count} already correct, " +
                  $"{needed.Count} to fetch ({neededBytes:N0} bytes)");

        if (needed.Count == 0) return;

        long doneBytes = 0;

        foreach (var file in needed)
        {
            ct.ThrowIfCancellationRequested();

            var full = Path.Combine(targetDir, file.RelativePath);
            var dir = Path.GetDirectoryName(full);
            if (dir is not null) Directory.CreateDirectory(dir);

            var name = Path.GetFileName(file.RelativePath);
            var startedAt = doneBytes;

            await DownloadBaseFileAsync(file, full, name, progress, neededBytes, startedAt, ct);

            doneBytes = startedAt + file.Size;
            Log.Write($"client acquire: base file ok {file.RelativePath}");
        }
    }

    /// <summary>
    /// True when the file on disk is already exactly what the baseline names. Size is checked
    /// first because it settles almost every case without reading a byte.
    /// </summary>
    private static async Task<bool> AlreadyCorrectAsync(
        string full, ClientBaseFile file, CancellationToken ct)
    {
        try
        {
            if (!File.Exists(full)) return false;
            if (new FileInfo(full).Length != file.Size) return false;

            var actual = await Hashing.Sha256FileAsync(full, ct);
            return Hashing.Matches(actual, file.Sha256);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            // Unreadable counts as not correct: re-fetching is always a safe answer here.
            Log.Write($"client acquire: could not check {file.RelativePath} — {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Downloads one base file through <see cref="ResilientDownload"/>, translating its
    /// per-file progress into the overall fraction across every file still to fetch.
    /// </summary>
    private async Task DownloadBaseFileAsync(
        ClientBaseFile file, string full, string name,
        IProgress<AcquireProgress> progress, long totalBytes, long bytesBefore,
        CancellationToken ct)
    {
        var reporter = new Progress<DownloadProgress>(p =>
        {
            var detail = p.Stage switch
            {
                DownloadStage.Verifying => "checking the file is intact",
                DownloadStage.Retrying => $"connection problem, resuming ({p.Attempt} of {p.Attempts})",
                _ => $"{Gb(p.Bytes)} of {Gb(file.Size)}",
            };

            // Every stage reports bytes actually on disk for this file, and a resume keeps
            // them, so the bar advances monotonically and never rewinds past the files already
            // finished.
            var done = bytesBefore + p.Bytes;

            progress.Report(new AcquireProgress(
                $"Downloading the game client — {name}",
                totalBytes > 0 ? (double)done / totalBytes : 0,
                detail));
        });

        try
        {
            await new ResilientDownload(_http)
                .FetchAsync(file.Url, full, file.Size, file.Sha256, file.RelativePath, reporter, ct,
                            BaseFileAttempts);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            // Named, because the caller's message is about the client as a whole and "it failed"
            // without saying which of 26 files is not actionable.
            throw new IOException($"{name} {ex.Message}", ex);
        }
    }

    private async Task<string> DownloadViaTorrentAsync(
        ClientSource source, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        if (!MagnetLink.TryParse(source.Magnet ?? "", out var magnet) || magnet is null)
            throw new InvalidDataException("The magnet link in the manifest is not valid.");

        /*
         * ★★ STALE FAST-RESUME IS WHY A REINSTALL NEVER USES THE TORRENT.
         *
         * MonoTorrent persists fast-resume state in CacheDirectory and reloads it
         * automatically. We delete the .zip as soon as it is extracted, so the
         * NEXT acquire starts a torrent that resume data says is already 100%
         * complete while its payload no longer exists. manager.Complete is true
         * before the loop runs, DownloadViaTorrentAsync falls straight through to
         * the "no .zip was found" throw, and the whole thing fails in about five
         * seconds -- then quietly diverts to the 15 GB HTTP mirror.
         *
         * That is exactly what a player's log showed on 2026-08-11:
         *   00:57:05 client acquire: trying BitTorrent
         *   00:57:10 torrent failed (FileNotFoundException: The torrent finished
         *            but no .zip was found ...) -- falling back to HTTP
         * Five seconds. It never contacted a single peer.
         *
         * So anyone reinstalling -- which is exactly what someone does when
         * something went wrong -- has silently been pushed onto the slowest path
         * available since the delete-after-extract behaviour was added.
         *
         * If the archive is not on disk, any claim that this torrent is finished
         * is false. Drop the cache and start honestly. Worst case we re-fetch
         * metadata, which is seconds; best case we stop pushing 15 GB of HTTP at
         * people who have a working swarm.
         */
        var expectedArchive = Path.Combine(AppPaths.DownloadDir, source.ArchiveName);
        if (!File.Exists(expectedArchive) && Directory.Exists(AppPaths.TorrentCacheDir))
        {
            try
            {
                Directory.Delete(AppPaths.TorrentCacheDir, recursive: true);
                Log.Write("client acquire: cleared stale torrent resume state (archive absent)");
            }
            catch (Exception ex)
            {
                // Not fatal -- worst case we are back to the old behaviour, and the
                // HTTP fallback still gets the player a client.
                Log.Write($"client acquire: could not clear torrent cache ({ex.Message})");
            }
        }

        var settings = new EngineSettingsBuilder
        {
            CacheDirectory = AppPaths.TorrentCacheDir,
            AllowPortForwarding = _allowInbound,
            // Null endpoints mean "do not listen" — no inbound socket, so no firewall prompt.
            DhtEndPoint = _allowInbound ? new System.Net.IPEndPoint(System.Net.IPAddress.Any, 0) : null,
        };

        if (_allowInbound)
            settings.ListenEndPoints = new Dictionary<string, System.Net.IPEndPoint>
            {
                { "ipv4", new System.Net.IPEndPoint(System.Net.IPAddress.Any, 0) },
            };
        else
            settings.ListenEndPoints = new Dictionary<string, System.Net.IPEndPoint>();

        using var engine = new ClientEngine(settings.ToSettings());

        var manager = await engine.AddAsync(magnet, AppPaths.DownloadDir);
        await manager.StartAsync();

        try
        {
            var stalledFor = TimeSpan.Zero;
            var metadataFor = TimeSpan.Zero;
            var noProgressFor = TimeSpan.Zero;
            var lastProgress = manager.Progress;
            var tick = TimeSpan.FromSeconds(1);

            while (manager.State != TorrentState.Seeding && manager.Complete == false)
            {
                ct.ThrowIfCancellationRequested();
                await Task.Delay(tick, ct);

                if (manager.State == TorrentState.Error)
                    throw new IOException(
                        manager.Error?.Exception.Message ?? "The torrent stopped with an error.");

                var peers = manager.Peers.Available + manager.Peers.Seeds + manager.Peers.Leechs;
                var rate = manager.Monitor.DownloadRate;

                /*
                 * Show the peer count even while fetching metadata.
                 *
                 * This used to read a bare "Fetching torrent details…" for the whole
                 * Metadata state, which hides the one number that says what is wrong.
                 * "0 peer(s)" means nothing was found at all -- blocked UDP, so dead
                 * trackers and a DHT that cannot bootstrap. A non-zero count with no
                 * progress means peers were found but will not hand over the metadata,
                 * which is a completely different problem. Guessing between those two
                 * from a screenshot cost a player an evening.
                 */
                var detail = manager.State == TorrentState.Metadata
                    ? $"Fetching torrent details… {peers} peer(s)"
                    : $"{peers} peer(s) · {Mb(rate)}/s";

                progress.Report(new AcquireProgress(
                    "Downloading the game client", manager.Progress / 100.0, detail));

                // Distinguish "slow" from "nobody is there". A dead swarm should produce a
                // clear message rather than an indefinite 0% bar.
                if (rate == 0 && peers == 0) stalledFor += tick; else stalledFor = TimeSpan.Zero;

                if (stalledFor > TimeSpan.FromMinutes(3))
                    throw new TimeoutException(
                        "No peers found after 3 minutes. Your network may be blocking BitTorrent. " +
                        "You can instead point the launcher at an existing 3.3.5a client with " +
                        "\"Change game folder\".");

                /*
                 * ★★ THE GUARD ABOVE NEEDS *BOTH* COUNTERS AT ZERO IN THE SAME SECOND,
                 *    AND THAT IS WHY A PLAYER SAT ON THIS SCREEN FOREVER (2026-08-11).
                 *
                 * `peers` counts Available + Seeds + Leechs, and Available is peers the
                 * TRACKER has told us about -- not peers we ever connected to. On a
                 * network that blocks BitTorrent the tracker reply still arrives over
                 * HTTP, so the count flickers above zero every time it refreshes, resets
                 * stalledFor to zero, and the three-minute timer never completes. The
                 * screen reads "0 peer(s) · 0,0 MB/s" the whole time because those blips
                 * land between the once-a-second samples.
                 *
                 * The HTTP mirror fallback was there the entire time and worked; it is
                 * only reached when this method THROWS, and it never threw. So the one
                 * player-visible symptom was an indefinite 0% bar next to a working
                 * alternative nobody could get to.
                 *
                 * This second guard asks the only question that actually matters -- has
                 * the download moved at all? -- and cannot be reset by tracker chatter.
                 * Ten minutes is deliberately generous: a genuinely slow swarm still
                 * advances Progress well inside it, and being wrong here only costs an
                 * unnecessary switch to a mirror that also works.
                 */
                if (manager.Progress > lastProgress)
                {
                    lastProgress = manager.Progress;
                    noProgressFor = TimeSpan.Zero;
                }
                else if (manager.State != TorrentState.Metadata)
                {
                    // Metadata has its own timer below; counting it here too would fire
                    // this one first and report the wrong cause.
                    noProgressFor += tick;
                }

                if (noProgressFor > TimeSpan.FromMinutes(10))
                    throw new TimeoutException(
                        $"The download has not advanced in 10 minutes ({peers} peer(s) seen, " +
                        $"{manager.Progress:0.##}% complete). Your network is most likely " +
                        "throttling BitTorrent. Switching to the direct download.");

                /*
                 * Metadata stall. The check above only fires when peers AND rate are both
                 * zero, so a torrent that finds peers but never receives the metadata sat
                 * on this screen indefinitely -- no progress, no error, nothing to report.
                 * Time the metadata phase separately and fail with something actionable.
                 */
                if (manager.State == TorrentState.Metadata)
                {
                    metadataFor += tick;
                    if (metadataFor > TimeSpan.FromMinutes(5))
                        throw new TimeoutException(
                            $"Could not fetch the torrent details after 5 minutes ({peers} peer(s) seen). " +
                            "Your network is likely blocking BitTorrent. Point the launcher at an " +
                            "existing 3.3.5a client with \"Change game folder\" instead.");
                }
                else
                    metadataFor = TimeSpan.Zero;
            }
        }
        finally
        {
            try { await engine.StopAllAsync(); } catch { /* shutting down anyway */ }
        }

        // The torrent's payload is a single .zip (ChromieCraft_3.3.5a.zip). Prefer the exact
        // name from the manifest; fall back to the largest .zip in case the torrent is ever
        // repacked under a different name.
        var expected = Path.Combine(AppPaths.DownloadDir, source.ArchiveName);
        if (File.Exists(expected)) return expected;

        var file = Directory.EnumerateFiles(AppPaths.DownloadDir, "*.zip", SearchOption.AllDirectories)
            .OrderByDescending(f => new FileInfo(f).Length)
            .FirstOrDefault();

        return file ?? throw new FileNotFoundException(
            $"The torrent finished but no .zip was found in {AppPaths.DownloadDir}.");
    }

    /// <summary>
    /// A safe local filename from a URL, for a manifest entry that omits one. Query strings
    /// and stray path characters are stripped -- this becomes a real path on disk.
    /// </summary>
    private static string SafeNameFromUrl(string url)
    {
        var name = "client.zip";
        try
        {
            var path = new Uri(url).AbsolutePath;
            var candidate = Path.GetFileName(path);
            if (!string.IsNullOrWhiteSpace(candidate)) name = candidate;
        }
        catch { /* not a well-formed absolute URI; the default will do */ }

        foreach (var bad in Path.GetInvalidFileNameChars()) name = name.Replace(bad, '_');
        return name;
    }

    /// <summary>Extracts an archive into the target, then removes it before the next one.</summary>
    private async Task ExtractAndDeleteAsync(
        string archive, string targetDir, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        Log.Write($"client acquire: extracting {archive}");
        progress.Report(new AcquireProgress("Extracting the client… this takes a while.", 0, archive));
        await Task.Run(() => ExtractTo(archive, targetDir, progress, ct), ct);

        // Deleted as we go, not at the end: with a split download the parts would otherwise
        // pile up beside the game they are being unpacked into.
        try { File.Delete(archive); } catch { /* leave it; the player can clear it manually */ }
    }

    private async Task<string> DownloadOneAsync(
        ClientArchive part, string label, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        var name = string.IsNullOrWhiteSpace(part.Name)
            ? SafeNameFromUrl(part.Url)
            : part.Name;

        var destination = Path.Combine(AppPaths.DownloadDir, name);

        using var response = await _http.GetAsync(
            part.Url, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();

        var expected = response.Content.Headers.ContentLength ?? part.Bytes;

        await using (var input = await response.Content.ReadAsStreamAsync(ct))
        await using (var output = new FileStream(destination, FileMode.Create, FileAccess.Write,
                                                 FileShare.None, 1024 * 256, useAsync: true))
        {
            var buffer = new byte[1024 * 256];
            long copied = 0;
            int read;

            while ((read = await input.ReadAsync(buffer, ct)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, read), ct);
                copied += read;

                progress.Report(new AcquireProgress(
                    "Downloading the game client" + label,
                    expected > 0 ? (double)copied / expected : 0,
                    $"{Gb(copied)} of {Gb(expected)}"));
            }
        }

        /*
         * A short file is the failure that would otherwise pass silently.
         *
         * A mirror that drops the connection mid-transfer still leaves a valid-looking .zip
         * on disk; extraction of a truncated archive can even partially succeed. That ends as
         * a client missing files, which looks like our bug rather than a broken download, and
         * with nothing in the log to say otherwise.
         */
        var actual = new FileInfo(destination).Length;
        if (expected > 0 && actual != expected)
        {
            Log.Write($"client acquire: SHORT DOWNLOAD {name} got {actual} of {expected} bytes");
            throw new IOException(
                $"The download of {name} stopped early ({Gb(actual)} of {Gb(expected)}). " +
                "The mirror may have dropped the connection; try again.");
        }

        Log.Write($"client acquire: downloaded {name} ({actual} bytes)");
        return destination;
    }

    private static void ExtractTo(
        string archivePath, string targetDir, IProgress<AcquireProgress> progress, CancellationToken ct)
    {
        using var zip = ZipFile.OpenRead(archivePath);

        var entries = zip.Entries;
        var root = Path.GetFullPath(targetDir);

        for (var i = 0; i < entries.Count; i++)
        {
            ct.ThrowIfCancellationRequested();
            var entry = entries[i];

            if (string.IsNullOrEmpty(entry.Name)) continue; // directory entry

            var destination = Path.GetFullPath(Path.Combine(targetDir, entry.FullName));

            // Zip-slip guard: an entry named ..\..\something must not write outside the target.
            if (!destination.StartsWith(root, StringComparison.OrdinalIgnoreCase)) continue;

            var dir = Path.GetDirectoryName(destination);
            if (dir is not null) Directory.CreateDirectory(dir);

            entry.ExtractToFile(destination, overwrite: true);

            if (i % 25 == 0)
                progress.Report(new AcquireProgress(
                    "Extracting the client", (double)i / entries.Count, entry.Name));
        }
    }

    private static string Gb(long bytes) => $"{bytes / 1024.0 / 1024 / 1024:0.0} GB";
    private static string Mb(long bytesPerSecond) => $"{bytesPerSecond / 1024.0 / 1024:0.0} MB";
}
