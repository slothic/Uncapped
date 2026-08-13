using System.Net.Http.Headers;
using System.Text;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// ★ TEMPORARY. Ships the client's frame-time log to a Discord channel on PLAY, then clears it.
///
/// WHY IT EXISTS
///
/// Players report frames collapsing during big pulls. Every attempt at it so far has been
/// server-side, and nobody has measured what the CLIENT spends a frame on. UncappedCT.dll now
/// samples that once a second into &lt;install&gt;\UncappedFPS.log; this is the half that gets it
/// off the player's machine and to somewhere it can be read.
///
/// WHAT IS IN THE FILE, AND WHAT IS DELIBERATELY NOT
///
/// Per second: a frame-time distribution, counts of slow frames, the map id, a position, how
/// many objects the client is tracking, and four activity counters. There is no character
/// name, no account name, no chat, no IP and nothing the player typed. It is a table of
/// numbers — several orders of magnitude less sensitive than a crash dump, which is a raw
/// memory snapshot, and it must stay that way.
///
/// It carries an install token so two players can be told apart in the channel and one player
/// followed across sessions. That token is 8 random bytes generated once on this machine and
/// stored locally (<see cref="LauncherState.InstallToken"/>) — it is derived from nothing,
/// least of all from an account or character name, and means nothing outside our own channel.
///
/// ★★ HOW THIS IS SWITCHED OFF, WHICH IS WHAT MAKES IT SAFE TO SHIP AS TEMPORARY
///
/// Exactly as <see cref="CrashReporter"/>: a <c>fpsReportWebhook</c> in the manifest that is
/// present but is not an http URL is a deliberate kill switch. Setting it to "off" stops this
/// dead for every player, with no client release and no publish.
///
/// This one goes one step further than the crash reporter, because a diagnostic that keeps
/// writing a file nobody will ever read is litter. When the webhook resolves to null this
/// drops <c>UncappedFPS.off</c> next to the client — which the DLL checks — so the kill
/// switch stops COLLECTION too, and deletes whatever was already gathered. Turning it back on
/// removes the marker again.
///
/// SEPARATE CHANNEL FROM CRASHES, ON PURPOSE. Different data at a completely different volume:
/// a crash is rare and needs triage, this is one attachment per player per play session. Mixed
/// together, the crash channel would stop being readable.
/// </summary>
public sealed class FpsReporter
{
    public const string LogName = "UncappedFPS.log";

    /// <summary>Presence of this file next to the client tells the DLL to stop collecting.</summary>
    public const string OffMarkerName = "UncappedFPS.off";

    /// <summary>Discord rejects larger uploads on a standard webhook.</summary>
    private const long MaxUploadBytes = 8 * 1024 * 1024;

    /// <summary>
    /// How much of an over-sized log to keep. The DLL caps the file at 6 MB, so this only
    /// engages on a file written before that cap existed, or one Discord would refuse.
    ///
    /// The TAIL is kept, not the head. A player uploading an over-long log has been playing
    /// for hours and the report that prompted it is about tonight, so the most recent minutes
    /// are the ones worth having. The cut is moved forward to the next newline so the file
    /// never starts mid-line, and a note says what was dropped.
    /// </summary>
    private const long KeepTailBytes = 7 * 1024 * 1024;

    /// <summary>
    /// Below this there is nothing in the file worth a post — a couple of header lines and a
    /// few seconds of the login screen. Also what stops a player who presses PLAY twice in a
    /// row from posting an empty attachment the second time.
    /// </summary>
    private const long MinUploadBytes = 2048;

    private readonly HttpClient _http;

    public FpsReporter(HttpClient http) => _http = http;

    /// <summary>
    /// The manifest wins if it carries a usable URL. A value that is present but is not an
    /// http(s) URL is the kill switch; absent falls back to the build-time constant, which
    /// ships EMPTY — the manifest is the intended mechanism and a temporary diagnostic has no
    /// business baking a webhook into a public binary.
    /// </summary>
    private static string? ResolveWebhook(Manifest manifest)
    {
        var fromManifest = manifest.FpsReportWebhook?.Trim();

        if (!string.IsNullOrEmpty(fromManifest))
            return fromManifest.StartsWith("http", StringComparison.OrdinalIgnoreCase)
                ? fromManifest
                : null;

        var baked = BuildSecrets.FpsWebhook;
        return string.IsNullOrWhiteSpace(baked) ? null : baked;
    }

    /// <summary>
    /// Uploads the frame log and clears it. Returns true only if something was actually sent.
    ///
    /// NEVER THROWS AT THE CALLER and never clears a log it did not manage to send: a failed
    /// upload leaves the file exactly where it was, so the next PLAY tries again.
    /// </summary>
    public async Task<bool> ReportAsync(
        string installPath, Manifest manifest, LauncherState state, CancellationToken ct)
    {
        var webhook = ResolveWebhook(manifest);
        var log = new FileInfo(Path.Combine(installPath, LogName));

        if (webhook is null)
        {
            // Switched off. Stop the DLL collecting, and bin what is already there — nothing
            // is ever going to read it, and leaving a file growing on a player's disk for a
            // diagnostic we have retired is not acceptable.
            SetOffMarker(installPath, on: true);
            TryDelete(log);
            return false;
        }

        SetOffMarker(installPath, on: false);

        log.Refresh();
        if (!log.Exists || log.Length < MinUploadBytes) return false;

        var (bytes, note) = ReadForUpload(log);
        if (bytes.Length == 0) return false;

        await SendAsync(webhook, manifest, installPath, state, bytes, note, ct);

        // Only after the post came back successful. SendAsync throws otherwise and the caller
        // logs it, leaving the file for the next attempt.
        TryDelete(log);

        state.FpsReportsSent++;
        state.Save();
        return true;
    }

    /// <summary>
    /// Reads the log for upload, keeping only the tail if it is over-sized. Returns the bytes
    /// and a human note about what was dropped, or an empty note if nothing was.
    /// </summary>
    private static (byte[] Bytes, string Note) ReadForUpload(FileInfo log)
    {
        try
        {
            // FileShare.ReadWrite|Delete: the client should not be running at this point, but
            // reading a log another process might hold must never be the thing that throws.
            using var stream = new FileStream(
                log.FullName, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);

            var length = stream.Length;
            if (length <= KeepTailBytes)
            {
                var all = new byte[length];
                stream.ReadExactly(all, 0, all.Length);
                return (all, "");
            }

            stream.Seek(length - KeepTailBytes, SeekOrigin.Begin);
            var tail = new byte[KeepTailBytes];
            stream.ReadExactly(tail, 0, tail.Length);

            // Start at the first whole line so the file never begins mid-number.
            var start = Array.IndexOf(tail, (byte)'\n') + 1;
            if (start <= 0 || start >= tail.Length) start = 0;

            var kept = new byte[tail.Length - start];
            Array.Copy(tail, start, kept, 0, kept.Length);

            var droppedMb = (length - kept.Length) / 1024 / 1024;
            return (kept, $"first {droppedMb} MB dropped — tail only");
        }
        catch (Exception ex)
        {
            Log.Write($"fps log read failed: {ex.Message}");
            return (Array.Empty<byte>(), "");
        }
    }

    private async Task SendAsync(
        string webhook, Manifest manifest, string installPath, LauncherState state,
        byte[] bytes, string note, CancellationToken ct)
    {
        using var form = new MultipartFormDataContent();

        var name = $"fps-{state.InstallToken}-{DateTime.Now:yyyyMMdd-HHmm}.log";

        var summary = new StringBuilder();
        summary.Append("**Frame log** `").Append(state.InstallToken).Append("`\n");
        summary.Append(manifest.Realm.Name).Append(" · launcher v").Append(AppPaths.CurrentVersion);
        summary.Append(" · ").Append(Describe(installPath));
        if (note.Length > 0) summary.Append(" · ").Append(note);

        form.Add(new StringContent(summary.ToString()), "content");

        var content = new ByteArrayContent(bytes);
        content.Headers.ContentType = new MediaTypeHeaderValue("text/plain");
        form.Add(content, "files[0]", name);

        if (bytes.Length > MaxUploadBytes)
        {
            // Should be unreachable: the DLL caps at 6 MB and the tail trim at 7 MB. Kept
            // because a silent 413 from Discord looks exactly like the feature not working.
            Log.Write($"fps log still {bytes.Length / 1024 / 1024} MB after trimming; not sent");
            return;
        }

        using var response = await _http.PostAsync(webhook, form, ct);
        response.EnsureSuccessStatusCode();
    }

    /// <summary>
    /// The settings that decide most of a WoW client's framerate before anything we wrote gets
    /// a say, plus how much addon is loaded. Read from the player's own Config.wtf and
    /// AddOns.txt, because a frame-time table is uninterpretable without them: 40 fps at
    /// 3840x2160 with farclip 1277 is a different report from 40 fps at 1280x720.
    ///
    /// Nothing here identifies anyone.
    /// </summary>
    private static string Describe(string installPath)
    {
        var parts = new List<string>();

        try
        {
            var res = ConfigWtf.Read(installPath, "gxResolution");
            if (!string.IsNullOrWhiteSpace(res)) parts.Add(res!);

            var farclip = ConfigWtf.Read(installPath, "farclip");
            if (!string.IsNullOrWhiteSpace(farclip)) parts.Add($"farclip {farclip}");
        }
        catch { /* context is a nicety; never let it stop the upload */ }

        try
        {
            var enabled = CountEnabledAddOns(installPath);
            if (enabled >= 0) parts.Add($"{enabled} addons");
        }
        catch { }

        parts.Add($"{Environment.ProcessorCount} cores");
        parts.Add(Environment.OSVersion.Version.ToString());

        return string.Join(" · ", parts);
    }

    /// <summary>
    /// Counts enabled entries across every account's AddOns.txt, or -1 if none was readable.
    /// The COUNT only — which addons a player runs is their business, and the DLL already
    /// measures what they actually cost per second.
    /// </summary>
    private static int CountEnabledAddOns(string installPath)
    {
        var wtf = Path.Combine(installPath, "WTF", "Account");
        if (!Directory.Exists(wtf)) return -1;

        var best = -1;
        foreach (var file in Directory.EnumerateFiles(wtf, "AddOns.txt", SearchOption.AllDirectories))
        {
            var n = File.ReadLines(file)
                        .Count(l => l.TrimEnd().EndsWith(": enabled", StringComparison.OrdinalIgnoreCase));
            if (n > best) best = n;
        }
        return best;
    }

    /// <summary>
    /// Creates or removes the marker the DLL reads. Failures are logged and ignored: the worst
    /// case is that a client keeps writing a capped local file the launcher then deletes on
    /// every PLAY, which is untidy rather than harmful.
    /// </summary>
    private static void SetOffMarker(string installPath, bool on)
    {
        var path = Path.Combine(installPath, OffMarkerName);
        try
        {
            if (on)
            {
                if (!File.Exists(path)) File.WriteAllText(path, "");
            }
            else if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception ex)
        {
            Log.Write($"fps off-marker: {ex.Message}");
        }
    }

    private static void TryDelete(FileInfo file)
    {
        try
        {
            file.Refresh();
            if (file.Exists) file.Delete();
        }
        catch (Exception ex)
        {
            Log.Write($"fps log clear failed: {ex.Message}");
        }
    }
}
