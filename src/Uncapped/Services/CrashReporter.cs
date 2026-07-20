using System.Net.Http.Headers;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Ships client crash dumps to a Discord channel so crashes get seen without anyone having to
/// ask a player to go digging in their Errors folder.
///
/// The client writes matching pairs into &lt;install&gt;\Errors\ when it falls over:
/// "&lt;timestamp&gt; Crash.dmp" (a memory snapshot) and "&lt;timestamp&gt; Crash.txt" (a readable
/// stack trace and system summary). We send both — the .txt is what is actually diagnosable
/// at a glance.
///
/// Two things worth being aware of:
///
/// - A .dmp is a snapshot of process memory. It can contain the account name, recent chat and
///   the player's IP. This uploads automatically, by decision, so it is disclosed in the
///   player-facing release notes rather than done quietly.
/// - The webhook URL ships inside a public client and can be extracted. It is write-only to
///   one channel, and it lives in the manifest so rotating it is an edit rather than a
///   release. Worst case someone posts junk into that channel.
/// </summary>
public sealed class CrashReporter
{
    /// <summary>Discord rejects larger uploads on a standard webhook.</summary>
    private const long MaxUploadBytes = 8 * 1024 * 1024;

    /// <summary>
    /// Only look at recent crashes. A client that has been around a while may have a pile of
    /// historic dumps, and uploading all of them on first run is noise, not signal.
    /// </summary>
    private static readonly TimeSpan MaxAge = TimeSpan.FromDays(14);

    private const int MaxPerRun = 3;

    private readonly HttpClient _http;

    public CrashReporter(HttpClient http) => _http = http;

    public async Task<int> ReportNewCrashesAsync(
        string installPath, Manifest manifest, LauncherState state, CancellationToken ct)
    {
        var webhook = manifest.CrashReportWebhook;
        if (string.IsNullOrWhiteSpace(webhook)) return 0;

        var errors = Path.Combine(installPath, "Errors");
        if (!Directory.Exists(errors)) return 0;

        var sent = 0;
        var cutoff = DateTime.UtcNow - MaxAge;

        var dumps = new DirectoryInfo(errors)
            .EnumerateFiles("*Crash.dmp")
            .Where(f => f.LastWriteTimeUtc >= cutoff)
            .Where(f => !state.ReportedCrashes.Contains(f.Name, StringComparer.OrdinalIgnoreCase))
            .OrderByDescending(f => f.LastWriteTimeUtc)
            .Take(MaxPerRun)
            .ToList();

        foreach (var dump in dumps)
        {
            ct.ThrowIfCancellationRequested();

            try
            {
                // The .txt sits alongside with the same timestamp prefix.
                var log = new FileInfo(Path.ChangeExtension(dump.FullName, ".txt"));

                await SendAsync(webhook!, manifest, dump, log.Exists ? log : null, ct);
                sent++;
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                // A failed upload must never block launching the game. Record it anyway so a
                // permanently-unsendable dump does not get retried on every single launch.
                Log.Write($"crash upload failed for {dump.Name}: {ex.Message}");
            }
            finally
            {
                state.ReportedCrashes.Add(dump.Name);
            }
        }

        if (dumps.Count > 0)
        {
            TrimHistory(state);
            state.Save();
        }

        return sent;
    }

    private async Task SendAsync(
        string webhook, Manifest manifest, FileInfo dump, FileInfo? log, CancellationToken ct)
    {
        using var form = new MultipartFormDataContent();

        var when = dump.LastWriteTime.ToString("yyyy-MM-dd HH:mm");
        var summary =
            $"**Client crash** on `{Environment.MachineName}`\n" +
            $"realm: {manifest.Realm.Name} · launcher v{AppPaths.CurrentVersion} · {when}";

        form.Add(new StringContent(summary), "content");

        var attached = 0;

        // Attach the readable log first: it is what someone actually reads, and if only one
        // file fits under the size limit it should be this one.
        if (log is not null && log.Length <= MaxUploadBytes)
            attached += AddFile(form, log, $"files[{attached}]");

        if (dump.Length <= MaxUploadBytes)
            attached += AddFile(form, dump, $"files[{attached}]");
        else
            form.Add(new StringContent($"(dump omitted: {dump.Length / 1024 / 1024} MB, over the upload limit)"),
                     "payload_note");

        if (attached == 0) return;

        using var response = await _http.PostAsync(webhook, form, ct);
        response.EnsureSuccessStatusCode();
    }

    private static int AddFile(MultipartFormDataContent form, FileInfo file, string fieldName)
    {
        var content = new ByteArrayContent(File.ReadAllBytes(file.FullName));
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        form.Add(content, fieldName, file.Name);
        return 1;
    }

    /// <summary>Keeps the remembered list from growing without bound.</summary>
    private static void TrimHistory(LauncherState state)
    {
        const int keep = 200;
        if (state.ReportedCrashes.Count > keep)
            state.ReportedCrashes = state.ReportedCrashes
                .Skip(state.ReportedCrashes.Count - keep)
                .ToList();
    }
}
