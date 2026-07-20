using System.Diagnostics;
using Uncapped.Model;
using Uncapped.Services;

namespace Uncapped;

public sealed class MainForm : Form
{
    private static readonly Color Bg = Color.FromArgb(24, 26, 31);
    private static readonly Color Panel = Color.FromArgb(33, 36, 43);
    private static readonly Color Ink = Color.FromArgb(232, 234, 238);
    private static readonly Color Muted = Color.FromArgb(150, 156, 168);
    private static readonly Color Accent = Color.FromArgb(88, 166, 96);

    private readonly HttpClient _http;
    private readonly LauncherConfig _config;
    private readonly LauncherState _state;

    private readonly ListBox _news = new();
    private readonly Label _newsBody = new();
    private readonly Label _realmDot = new();
    private readonly Label _realmText = new();
    private readonly Label _status = new();
    private readonly ProgressBar _progress = new();
    private readonly Button _play = new();
    private readonly LinkLabel _register = new();
    private readonly LinkLabel _changeFolder = new();

    private Manifest? _manifest;
    private string? _installPath;
    private bool _readyToPlay;
    private CancellationTokenSource _cts = new();

    public MainForm(HttpClient http, LauncherConfig config, LauncherState state)
    {
        _http = http;
        _config = config;
        _state = state;

        BuildUi();
        Shown += async (_, _) => await RunStartupAsync();
        FormClosing += (_, _) => _cts.Cancel();
    }

    private void BuildUi()
    {
        Text = "Uncapped Launcher";

        // The window and taskbar do not inherit the exe's icon automatically; pull it back
        // off our own binary so all three match.
        try { Icon = Icon.ExtractAssociatedIcon(AppPaths.ExePath); }
        catch { /* keep the WinForms default if it cannot be read */ }

        ClientSize = new Size(760, 440);
        MinimumSize = new Size(680, 400);
        StartPosition = FormStartPosition.CenterScreen;
        BackColor = Bg;
        ForeColor = Ink;
        Font = new Font("Segoe UI", 9F);

        var title = new Label
        {
            Text = "UNCAPPED",
            Font = new Font("Segoe UI", 20F, FontStyle.Bold),
            ForeColor = Ink,
            AutoSize = true,
            Location = new Point(20, 14),
        };

        var subtitle = new Label
        {
            Text = "World of Warcraft 3.3.5a",
            ForeColor = Muted,
            AutoSize = true,
            Location = new Point(23, 52),
        };

        var newsLabel = new Label
        {
            Text = "NEWS",
            ForeColor = Muted,
            Font = new Font("Segoe UI", 8F, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(20, 84),
        };

        _news.SetBounds(20, 102, 460, 108);
        _news.BackColor = Panel;
        _news.ForeColor = Ink;
        _news.BorderStyle = BorderStyle.None;
        _news.IntegralHeight = false;
        _news.SelectedIndexChanged += (_, _) => ShowSelectedNews();

        _newsBody.SetBounds(20, 216, 460, 96);
        _newsBody.ForeColor = Muted;
        _newsBody.AutoEllipsis = true;

        // Right column: realm status.
        var realmLabel = new Label
        {
            Text = "REALM",
            ForeColor = Muted,
            Font = new Font("Segoe UI", 8F, FontStyle.Bold),
            AutoSize = true,
            Location = new Point(510, 84),
        };

        _realmDot.SetBounds(510, 104, 12, 12);
        _realmDot.BackColor = Muted;

        _realmText.SetBounds(530, 102, 210, 40);
        _realmText.ForeColor = Ink;
        _realmText.Text = "Checking…";

        _register.SetBounds(510, 150, 220, 20);
        _register.Text = "Create an account";
        _register.LinkColor = Accent;
        _register.ActiveLinkColor = Accent;
        _register.Visible = false;
        _register.LinkClicked += (_, _) => OpenUrl(_manifest?.Realm.RegisterUrl);

        _changeFolder.SetBounds(510, 176, 220, 20);
        _changeFolder.Text = "Change game folder";
        _changeFolder.LinkColor = Muted;
        _changeFolder.ActiveLinkColor = Ink;
        _changeFolder.LinkClicked += async (_, _) => await ChangeFolderAsync();

        // Bottom bar.
        _status.SetBounds(20, 330, 500, 20);
        _status.ForeColor = Muted;
        _status.Text = "Starting…";

        _progress.SetBounds(20, 354, 500, 8);
        _progress.Style = ProgressBarStyle.Continuous;
        _progress.Maximum = 1000;

        _play.SetBounds(560, 326, 180, 60);
        _play.Text = "PLAY";
        _play.Font = new Font("Segoe UI", 14F, FontStyle.Bold);
        _play.FlatStyle = FlatStyle.Flat;
        _play.FlatAppearance.BorderSize = 0;
        _play.BackColor = Accent;
        _play.ForeColor = Color.White;
        _play.Enabled = false;
        _play.Click += async (_, _) => await OnPlayAsync();

        Controls.AddRange(new Control[]
        {
            title, subtitle, newsLabel, _news, _newsBody,
            realmLabel, _realmDot, _realmText, _register, _changeFolder,
            _status, _progress, _play,
        });
    }

    // ---------- startup ----------

    private async Task RunStartupAsync()
    {
        SelfUpdater.CleanupPreviousUpdate();
        AppPaths.EnsureDirs();

        try
        {
            SetStatus("Checking for updates…");
            _manifest = await new ManifestService(_http).FetchAsync(_config.ManifestUrl, _cts.Token);
        }
        catch (Exception ex)
        {
            // Offline is not fatal: if we already know where the client is, the player should
            // still be able to play on whatever they last synced.
            SetStatus($"Could not reach the update server — {ex.Message}");
            Log(ex.ToString());

            if (InstallLocator.IsValidInstall(_state.InstallPath))
            {
                _installPath = _state.InstallPath;
                EnablePlay("Playing offline with your current files.");
            }
            return;
        }

        Text = $"{_manifest.Realm.Name} Launcher";
        LoadNews(_manifest);
        _ = RefreshRealmStatusAsync(_manifest);

        if (!string.IsNullOrWhiteSpace(_manifest.Realm.RegisterUrl)) _register.Visible = true;

        if (SelfUpdater.UpdateAvailable(_manifest))
        {
            SetStatus("Updating the launcher…");
            var updater = new SelfUpdater(_http);
            var applied = await updater.TryApplyAsync(
                _manifest, new Progress<string>(SetStatus), _cts.Token);

            if (applied) { Application.Exit(); return; }
        }

        _installPath = await ResolveInstallAsync(_manifest);
        if (_installPath is null) return;

        await SyncAndPrepareAsync();
    }

    // ---------- install location ----------

    private async Task<string?> ResolveInstallAsync(Manifest manifest)
    {
        SetStatus("Looking for your World of Warcraft folder…");

        var found = InstallLocator.Discover(_state.InstallPath).FirstOrDefault();
        if (found is not null)
        {
            _state.InstallPath = found.Path;
            _state.Save();
            return found.Path;
        }

        var choice = MessageBox.Show(
            "No World of Warcraft 3.3.5a folder was found.\n\n" +
            "Yes — download the game client (about 17 GB)\n" +
            "No — point the launcher at a folder you already have",
            "Game client needed", MessageBoxButtons.YesNoCancel, MessageBoxIcon.Question);

        if (choice == DialogResult.Cancel) { Close(); return null; }
        if (choice == DialogResult.No) return await PickFolderAsync();

        return await DownloadClientAsync(manifest);
    }

    private async Task<string?> PickFolderAsync()
    {
        while (true)
        {
            using var dialog = new FolderBrowserDialog
            {
                Description = "Select your World of Warcraft 3.3.5a folder (the one containing Wow.exe)",
                UseDescriptionForTitle = true,
                ShowNewFolderButton = false,
            };

            if (dialog.ShowDialog(this) != DialogResult.OK) return null;

            if (InstallLocator.IsValidInstall(dialog.SelectedPath))
            {
                _state.InstallPath = dialog.SelectedPath;
                _state.Save();
                await Task.CompletedTask;
                return dialog.SelectedPath;
            }

            MessageBox.Show(
                "That folder does not look like a World of Warcraft install.\n\n" +
                "It needs to contain Wow.exe and a Data folder.",
                "Wrong folder", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task<string?> DownloadClientAsync(Manifest manifest)
    {
        using var dialog = new FolderBrowserDialog
        {
            Description = "Choose where to install the game (about 17 GB, plus the same again while unpacking)",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
        };

        if (dialog.ShowDialog(this) != DialogResult.OK) return null;

        var target = Path.Combine(dialog.SelectedPath, "WoW335");

        try
        {
            var acquirer = new ClientAcquirer(_http, _config.TorrentAllowInbound);
            var reporter = new Progress<AcquireProgress>(p =>
            {
                SetStatus($"{p.Status} — {p.Detail}");
                SetProgress(p.Fraction);
            });

            await acquirer.AcquireAsync(manifest.Client, target, reporter, _cts.Token);
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex)
        {
            Log(ex.ToString());
            MessageBox.Show(
                $"The game client could not be downloaded.\n\n{ex.Message}",
                "Download failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
            SetStatus("Client download failed.");
            return null;
        }

        // The zip may unpack into a single nested folder rather than directly into the target.
        var root = InstallLocator.IsValidInstall(target)
            ? target
            : Directory.EnumerateDirectories(target).FirstOrDefault(InstallLocator.IsValidInstall);

        if (root is null)
        {
            MessageBox.Show(
                "The client was downloaded but no Wow.exe could be found inside it.",
                "Unexpected archive", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return null;
        }

        _state.InstallPath = root;
        _state.Save();

        // First install only: give the client windowed mode at the desktop resolution, so a
        // new player is not dropped into a fullscreen mode their monitor may not like.
        try
        {
            await FirstRunConfigurator.ConfigureAsync(root, new Progress<string>(SetStatus), _cts.Token);
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex)
        {
            // Display defaults are a convenience, not a requirement. Never block the install.
            Log($"first-run display config: {ex}");
        }

        return root;
    }

    private async Task ChangeFolderAsync()
    {
        var picked = await PickFolderAsync();
        if (picked is null) return;

        _installPath = picked;
        _readyToPlay = false;
        _play.Enabled = false;
        await SyncAndPrepareAsync();
    }

    // ---------- sync ----------

    private async Task SyncAndPrepareAsync()
    {
        if (_manifest is null || _installPath is null) return;

        if (GameProcess.IsRunning(_installPath))
        {
            SetStatus("World of Warcraft is already running — close it, then reopen the launcher.");
            MessageBox.Show(
                "World of Warcraft is running.\n\n" +
                "Files cannot be updated while the game is open. Close it and start the launcher again.",
                "Game is running", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        if (InstallLocator.NeedsElevation(_installPath))
        {
            SetStatus("Cannot write to the game folder.");
            MessageBox.Show(
                $"The game is installed at:\n{_installPath}\n\n" +
                "That location needs administrator rights to change, so addons and patches " +
                "cannot be installed there.\n\n" +
                "Either move the game somewhere like C:\\Games\\WoW335, or right-click the " +
                "launcher and choose \"Run as administrator\".",
                "Permission needed", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        SyncOutcome outcome;
        try
        {
            var sync = new SyncService(_http);
            var reporter = new Progress<SyncProgress>(p =>
            {
                SetStatus($"{p.Status}  ({p.Completed}/{p.Total})");
                SetProgress(p.Total == 0 ? 1 : (double)p.Completed / p.Total);
            });

            outcome = await sync.SyncAsync(_installPath, _manifest, _state, reporter, _cts.Token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception ex)
        {
            Log(ex.ToString());
            SetStatus($"Update failed — {ex.Message}");
            EnablePlay("You can still play, but your files may be out of date.");
            return;
        }

        SetProgress(1);

        var realm = ClientConfigWriter.WriteRealmlist(
            _installPath, _manifest.Realm.Address, _manifest.Realm.Name);

        foreach (var failure in realm.Failed) Log($"realmlist: {failure}");

        AddOnsTxtEnforcer.Apply(_installPath, _manifest.ForceEnableAddOns, _manifest.ForceDisableAddOns);

        if (_manifest.HardenClient)
        {
            var hardened = ClientHardening.Apply(_installPath);
            foreach (var note in hardened.Notes) Log($"hardening: {note}");
        }

        // Crash uploads run after the sync so a broken install gets fixed first, and are
        // never allowed to stop the player launching.
        try
        {
            var reporter = new CrashReporter(_http);
            var sent = await reporter.ReportNewCrashesAsync(_installPath, _manifest, _state, _cts.Token);
            if (sent > 0) Log($"uploaded {sent} crash report(s)");
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Log($"crash reporting: {ex.Message}"); }

        // Only worth clearing when something actually changed — it costs the player a slower
        // first login while the client refetches.
        if (outcome.ChangedAnything) WdbCleaner.Clear(_installPath);

        if (outcome.Errors.Count > 0)
        {
            foreach (var e in outcome.Errors) Log($"sync: {e}");
            EnablePlay($"Ready, but {outcome.Errors.Count} file(s) failed to update. See launcher.log.");
        }
        else if (outcome.ChangedAnything)
        {
            EnablePlay($"Updated {outcome.Downloaded} file(s). Ready to play.");
        }
        else
        {
            EnablePlay("Up to date.");
        }
    }

    // ---------- play ----------

    private async Task OnPlayAsync()
    {
        if (!_readyToPlay || _installPath is null) return;

        if (GameProcess.IsRunning(_installPath))
        {
            MessageBox.Show("World of Warcraft is already running.", "Already running",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        try
        {
            GameProcess.Launch(_installPath);
            SetStatus("Launched. Have fun.");
            _play.Enabled = false;

            // Stay open behind the game, then re-arm so a player who logs out can relaunch
            // without restarting the launcher.
            await Task.Delay(TimeSpan.FromSeconds(10), _cts.Token);
            _play.Enabled = true;
            SetStatus("Running.");
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log(ex.ToString());
            MessageBox.Show($"Could not start the game.\n\n{ex.Message}", "Launch failed",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    // ---------- helpers ----------

    private async Task RefreshRealmStatusAsync(Manifest manifest)
    {
        var up = await RealmStatus.IsReachableAsync(
            manifest.Realm.Address, manifest.Realm.AuthPort, _cts.Token);

        if (IsDisposed) return;

        _realmDot.BackColor = up ? Accent : Color.FromArgb(190, 80, 80);
        _realmText.Text = up
            ? $"{manifest.Realm.Name}\nreachable"
            : $"{manifest.Realm.Name}\nnot responding";
    }

    private void LoadNews(Manifest manifest)
    {
        _news.Items.Clear();
        foreach (var item in manifest.News)
            _news.Items.Add($"{item.Date}   {item.Title}");

        if (_news.Items.Count > 0) _news.SelectedIndex = 0;
        else _newsBody.Text = "No news yet.";
    }

    private void ShowSelectedNews()
    {
        var i = _news.SelectedIndex;
        if (_manifest is null || i < 0 || i >= _manifest.News.Count) return;
        _newsBody.Text = _manifest.News[i].Body ?? "";
    }

    private void EnablePlay(string status)
    {
        _readyToPlay = true;
        _play.Enabled = true;
        SetStatus(status);
    }

    private void SetStatus(string text)
    {
        if (InvokeRequired) { BeginInvoke(() => SetStatus(text)); return; }
        _status.Text = text;
    }

    private void SetProgress(double fraction)
    {
        if (InvokeRequired) { BeginInvoke(() => SetProgress(fraction)); return; }
        _progress.Value = Math.Clamp((int)(fraction * 1000), 0, 1000);
    }

    private static void OpenUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return;
        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch { /* no browser association; nothing sensible to do */ }
    }

    internal static void Log(string message) => Uncapped.Log.Write(message);
}
