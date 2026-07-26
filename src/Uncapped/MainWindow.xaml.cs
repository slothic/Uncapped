using System.Diagnostics;
using System.Net.Http;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using Uncapped.Model;
using Uncapped.Services;

namespace Uncapped;

public partial class MainWindow : Window
{
    private readonly HttpClient _http;
    private readonly LauncherConfig _config;
    private readonly LauncherState _state;
    private readonly CancellationTokenSource _cts = new();

    /// <summary>
    /// How many times a sync will wait out a half-published release and try again before
    /// settling for letting the player in with a warning.
    /// </summary>
    private const int MaxHostRetries = 2;

    private Credentials _credentials = Credentials.Load();
    private Manifest? _manifest;
    private string? _manifestHash;
    private string? _installPath;
    private ClientVersions? _versions;
    private bool _readyToPlay;
    private bool _closing;

    public MainWindow(HttpClient http, LauncherConfig config, LauncherState state)
    {
        _http = http;
        _config = config;
        _state = state;

        InitializeComponent();

        Loaded += async (_, _) => { RefreshLoginLink(); await RunStartupAsync(); };
        Closing += (_, _) => { _closing = true; _cts.Cancel(); };
    }

    // ---------- window chrome ----------

    private void OnDragWindow(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private void OnMinimize(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    // ---------- startup ----------

    private async Task RunStartupAsync()
    {
        SelfUpdater.CleanupPreviousUpdate();
        AppPaths.EnsureDirs();

        try
        {
            SetStatus("Checking for updates…");
            var fetched = await new ManifestService(_http).FetchAsync(_config.ManifestUrl, _cts.Token);
            _manifest = fetched.Manifest;
            _manifestHash = fetched.Hash;
        }
        catch (Exception ex)
        {
            // Offline is not fatal: if we already know where the client is, the player should
            // still be able to play on whatever they last synced.
            SetStatus($"Could not reach the update server — {ex.Message}");
            Log.Write(ex.ToString());

            if (InstallLocator.IsValidInstall(_state.InstallPath))
            {
                _installPath = _state.InstallPath;
                ShowVersions(new ClientVersions(ClientVersionService.ReadInstalled(_installPath), null, null, true));
                EnablePlay("Playing offline with your current files.");
            }

            // Leave the check button live either way: the network coming back is exactly the
            // case where a player wants to retry without restarting the launcher.
            SetBusy(false);
            return;
        }

        Title = $"{_manifest.Realm.Name} Launcher";
        _ = LoadNewsAsync(_manifest);
        _ = RefreshRealmStatusAsync(_manifest);

        if (!string.IsNullOrWhiteSpace(_manifest.Realm.RegisterUrl))
        {
            RegisterLink.Visibility = Visibility.Visible;
            LinkSeparator.Visibility = Visibility.Visible;
        }

        if (SelfUpdater.UpdateAvailable(_manifest))
        {
            SetStatus("Updating the launcher…");
            var applied = await new SelfUpdater(_http)
                .TryApplyAsync(_manifest, new Progress<string>(SetStatus), _cts.Token);

            if (applied) { Application.Current.Shutdown(); return; }
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
            "Game client needed", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);

        if (choice == MessageBoxResult.Cancel) { Close(); return null; }
        if (choice == MessageBoxResult.No) return PickFolder();

        return await DownloadClientAsync(manifest);
    }

    private string? PickFolder()
    {
        while (true)
        {
            // WPF has no folder picker; on .NET 5+ this renders as the modern Vista dialog.
            using var dialog = new System.Windows.Forms.FolderBrowserDialog
            {
                Description = "Select your World of Warcraft 3.3.5a folder",
                UseDescriptionForTitle = true,
                ShowNewFolderButton = false,
            };

            if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return null;

            if (InstallLocator.IsValidInstall(dialog.SelectedPath))
            {
                _state.InstallPath = dialog.SelectedPath;
                _state.Save();
                return dialog.SelectedPath;
            }

            MessageBox.Show(
                "That folder does not look like a World of Warcraft install.\n\n" +
                "It needs to contain the game executable and a Data folder.",
                "Wrong folder", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task<string?> DownloadClientAsync(Manifest manifest)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "Choose where to install the game (about 17 GB, plus the same again while unpacking)",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
        };

        if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return null;

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
            Log.Write(ex.ToString());
            MessageBox.Show($"The game client could not be downloaded.\n\n{ex.Message}",
                "Download failed", MessageBoxButton.OK, MessageBoxImage.Error);
            SetStatus("Client download failed.");
            return null;
        }

        // The zip may unpack into a single nested folder rather than directly into the target.
        var root = InstallLocator.IsValidInstall(target)
            ? target
            : Directory.EnumerateDirectories(target).FirstOrDefault(InstallLocator.IsValidInstall);

        if (root is null)
        {
            MessageBox.Show("The client was downloaded but no game executable was found inside it.",
                "Unexpected archive", MessageBoxButton.OK, MessageBoxImage.Error);
            return null;
        }

        _state.InstallPath = root;
        _state.Save();

        // First install only: windowed at the desktop resolution, so a new player is not
        // dropped into a fullscreen mode their monitor may not like.
        try
        {
            await FirstRunConfigurator.ConfigureAsync(root, new Progress<string>(SetStatus), _cts.Token);
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex) { Log.Write($"first-run display config: {ex}"); }

        return root;
    }

    private async void OnChangeFolder(object sender, RoutedEventArgs e)
    {
        var picked = PickFolder();
        if (picked is null) return;

        _installPath = picked;
        _readyToPlay = false;
        PlayButton.IsEnabled = false;
        await SyncAndPrepareAsync();
    }

    // ---------- sync ----------

    private async Task SyncAndPrepareAsync()
    {
        if (_manifest is null || _installPath is null) return;

        // Captured up front: both can be reassigned from other handlers, and everything below
        // an await must be talking about the same manifest and folder it started with.
        var manifest = _manifest;
        var installPath = _installPath;

        if (GameProcess.IsRunning(_installPath))
        {
            SetStatus("World of Warcraft is already running — close it, then reopen the launcher.");
            MessageBox.Show(
                "World of Warcraft is running.\n\n" +
                "Files cannot be updated while the game is open. Close it and start the launcher again.",
                "Game is running", MessageBoxButton.OK, MessageBoxImage.Warning);
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
                "Permission needed", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        SetBusy(true);
        try
        {
            // Nothing below is worth doing against a release that is still going out: the
            // downloads would fail their checksums and the client we ended up with is one the
            // server's version gate kicks on login.
            if (!await EnsureReleasePublishedAsync(manifest, installPath)) return;

            SyncOutcome outcome;
            var attempt = 0;

            while (true)
            {
                try
                {
                    var reporter = new Progress<SyncProgress>(p =>
                    {
                        SetStatus($"{p.Status}  ({p.Completed}/{p.Total})");
                        SetProgress(p.Total == 0 ? 1 : (double)p.Completed / p.Total);
                    });

                    outcome = await new SyncService(_http)
                        .SyncAsync(installPath, manifest, _state, reporter, _cts.Token);
                }
                catch (OperationCanceledException) { return; }
                catch (Exception ex)
                {
                    Log.Write(ex.ToString());
                    SetStatus($"Update failed — {ex.Message}");
                    EnablePlay("You can still play, but your files may be out of date.");
                    return;
                }

                // Files that downloaded fine but hashed wrong are the CDN handing out the
                // previous release. The canary above only catches that when the release
                // bumped the client version, so this is the general case: wait for the
                // specific files that came back wrong, then fetch them again.
                if (!outcome.LooksLikeStaleHost || attempt++ >= MaxHostRetries) break;
                if (!await WaitForHostAsync(outcome.Mismatched)) break;
            }

            SetProgress(1);

            var realm = ClientConfigWriter.WriteRealmlist(
                installPath, manifest.Realm.Address, manifest.Realm.Name);
            foreach (var failure in realm.Failed) Log.Write($"realmlist: {failure}");

            AddOnsTxtEnforcer.Apply(installPath, manifest.ForceEnableAddOns, manifest.ForceDisableAddOns);

            if (manifest.HardenClient)
            {
                var hardened = ClientHardening.Apply(installPath);
                foreach (var note in hardened.Notes) Log.Write($"hardening: {note}");
            }

            if (manifest.LargeAddressAware)
            {
                var laa = Services.LargeAddressAware.Apply(installPath);
                if (laa.Changed) Log.Write($"large address aware: {laa.Detail}");
            }

            // Only worth clearing when something actually changed — it costs the player a slower
            // first login while the client refetches.
            if (outcome.ChangedAnything) WdbCleaner.Clear(installPath);

            // Re-read what landed on disk — this is the version the player is now actually
            // running. Off disk rather than over the network: the sync just verified every one
            // of these files against the manifest, so another round-trip would learn nothing.
            var installedNow = ClientVersionService.ReadInstalled(installPath);
            ShowVersions(_versions is null
                ? new ClientVersions(installedNow, null, null, true)
                : _versions with { Installed = installedNow });

            try
            {
                var sent = await new CrashReporter(_http)
                    .ReportNewCrashesAsync(installPath, manifest, _state, _cts.Token);
                if (sent > 0) Log.Write($"uploaded {sent} crash report(s)");
            }
            catch (OperationCanceledException) { }
            catch (Exception ex) { Log.Write($"crash reporting: {ex.Message}"); }

            if (outcome.Errors.Count > 0)
            {
                foreach (var e in outcome.Errors) Log.Write($"sync: {e}");
                // Deliberately not recorded as synced: a partial sync must be retried on the next
                // PLAY rather than skipped because the manifest hash happens to match.
                EnablePlay($"Ready, but {outcome.Errors.Count} file(s) failed to update. See launcher.log.");
            }
            else
            {
                _state.LastManifestHash = _manifestHash;
                _state.Save();

                EnablePlay(outcome.ChangedAnything
                    ? $"Updated {outcome.Downloaded} file(s)."
                    : "Up to date.");
            }

            // Otherwise the activity line is left reading "Checking your files (552/552)",
            // which looks like it stopped halfway rather than finished.
            SetStatus("Ready.");
        }
        finally { SetBusy(false); }
    }

    // ---------- publish gate ----------

    /// <summary>
    /// Asks GitHub what the current client version is, asks its CDN what it is handing out,
    /// and refuses to go any further while the two disagree.
    ///
    /// Returns true when it is safe to sync and play. Returns false only if the wait was
    /// abandoned, and PLAY is deliberately left off in that case: a client assembled from a
    /// half-published release gets kicked at the login screen, which is a much worse experience
    /// than a launcher that says "hang on a minute".
    /// </summary>
    private async Task<bool> EnsureReleasePublishedAsync(Manifest manifest, string installPath)
    {
        ClientVersions versions;
        try
        {
            versions = await new ClientVersionService(_http).CheckAsync(manifest, installPath, _cts.Token);
        }
        catch (OperationCanceledException) { return false; }

        ShowVersions(versions);

        if (versions.CdnCurrent) return true;

        // The CDN is behind, but this player already has the version being published — there
        // is nothing they need to download, so there is nothing to make them wait for.
        if (versions.Matches)
        {
            SetStatus("A release is still publishing, but your client is already current.");
            return true;
        }

        var file = ClientVersionService.FindVersionFile(manifest);
        return file is null || await WaitForHostAsync(new List<ManifestFile> { file });
    }

    /// <summary>
    /// Holds PLAY off until the file host is serving the files the manifest describes, polling
    /// until it catches up. GitHub's raw-file CDN caches for a few minutes, so this is normally
    /// a short wait right after a release goes out.
    /// </summary>
    private async Task<bool> WaitForHostAsync(IReadOnlyList<ManifestFile> files)
    {
        var target = _versions?.Latest is int latest ? $"v{latest}" : "the new version";

        // The status line is one narrow column: anything much longer than this is ellipsised
        // away mid-sentence, so the detail goes on the summary line, which wraps.
        BlockPlay($"Update {target} is publishing — please wait…");
        SetSummary($"PLAY is off until {target} has finished going out.");

        var waited = new Progress<TimeSpan>(elapsed =>
        {
            if (elapsed > TimeSpan.FromSeconds(20))
                SetStatus($"Waiting for {target} to publish ({elapsed:m\\:ss})…");

            // The bar becomes a timer against the give-up point, so a long wait still looks
            // like something in progress rather than a frozen window.
            SetProgress(Math.Min(elapsed.TotalSeconds / CdnGate.MaxWait.TotalSeconds, 0.98));
        });

        bool ready;
        try { ready = await new CdnGate(_http).WaitUntilCurrentAsync(files, waited, _cts.Token); }
        catch (OperationCanceledException) { return false; }

        if (!ready)
        {
            SetStatus("The update has not finished publishing.");
            SetSummary($"PLAY stays off until {target} is available — check again in a few minutes.");
            SetProgress(0);
            return false;
        }

        if (_manifest is not null && _installPath is not null)
        {
            try
            {
                ShowVersions(await new ClientVersionService(_http)
                    .CheckAsync(_manifest, _installPath, _cts.Token));
            }
            catch (OperationCanceledException) { return false; }
        }

        SetStatus($"{target} published — downloading it now.");
        return true;
    }

    // ---------- explicit update check ----------

    private async void OnCheckForUpdates(object sender, RoutedEventArgs e)
    {
        SetBusy(true);
        try { await CheckForUpdatesAsync(); }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Write(ex.ToString());
            SetStatus($"Update check failed — {ex.Message}");
        }
        finally { SetBusy(false); }
    }

    /// <summary>
    /// The manual half of everything the launcher does at startup: re-read the manifest, work
    /// out what the current client version is, and sync up to it. Also the way back in after a
    /// failed startup — an offline launch or a publish that was mid-flight — without making the
    /// player close and reopen the launcher.
    /// </summary>
    private async Task CheckForUpdatesAsync()
    {
        ManifestFetch fetched;
        try
        {
            SetStatus("Checking for updates…");
            fetched = await new ManifestService(_http).FetchAsync(_config.ManifestUrl, _cts.Token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception ex)
        {
            Log.Write($"update check: {ex.Message}");
            SetStatus($"Could not reach the update server — {ex.Message}");
            return;
        }

        var moved = !string.Equals(fetched.Hash, _manifestHash, StringComparison.OrdinalIgnoreCase);

        _manifest = fetched.Manifest;
        _manifestHash = fetched.Hash;

        if (moved) _ = LoadNewsAsync(_manifest);

        if (_installPath is null)
        {
            _installPath = await ResolveInstallAsync(_manifest);
            if (_installPath is null) return;
        }

        await SyncAndPrepareAsync();
    }

    /// <summary>
    /// Re-checks for updates when PLAY is pressed, so a launcher left open all day does not
    /// start a stale client.
    ///
    /// Compares the manifest's hash against the last one we synced: unchanged means nothing
    /// upstream moved, so this costs one HTTP request instead of a pass over every file, and
    /// PLAY stays effectively instant in the common case.
    ///
    /// Best-effort by design. If the update server is unreachable the player still gets to
    /// play on what they already have — being offline should not stop you launching a game.
    /// Launcher self-updates are deliberately left to startup; swapping the exe out from under
    /// someone who just pressed PLAY would be a poor trade.
    /// </summary>
    private async Task RefreshBeforeLaunchAsync()
    {
        if (_installPath is null) return;

        ManifestFetch fetched;
        try
        {
            SetStatus("Checking for updates…");
            fetched = await new ManifestService(_http).FetchAsync(_config.ManifestUrl, _cts.Token);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Log.Write($"pre-launch check failed: {ex.Message}");
            SetStatus("Could not check for updates — starting anyway.");
            return;
        }

        if (string.Equals(fetched.Hash, _state.LastManifestHash, StringComparison.OrdinalIgnoreCase))
            return;

        _manifest = fetched.Manifest;
        _manifestHash = fetched.Hash;

        SetStatus("Updates found — applying…");
        await SyncAndPrepareAsync();

        _ = LoadNewsAsync(_manifest);
    }

    // ---------- play ----------

    private async void OnPlay(object sender, RoutedEventArgs e)
    {
        if (!_readyToPlay || _installPath is null) return;

        var installPath = _installPath;

        if (GameProcess.IsRunning(installPath))
        {
            MessageBox.Show("World of Warcraft is already running.", "Already running",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        try
        {
            PlayButton.IsEnabled = false;
            await RefreshBeforeLaunchAsync();

            if (_closing) return;

            // The pre-launch check gets a veto: a release still going out, or a sync that
            // failed outright, both turn PLAY off and have already said why on screen.
            if (!_readyToPlay) return;

            PlayButton.IsEnabled = false;

            // The sync refuses while the game is up, and it may have taken a while, so
            // re-check rather than trusting the state from before the update.
            if (GameProcess.IsRunning(installPath))
            {
                PlayButton.IsEnabled = true;
                return;
            }

            // Exclusive fullscreen crashes this client on too many machines to leave to the
            // player's saved setting — and the client rewrites Config.wtf when it exits, so
            // anyone who switched in-game would be back in fullscreen next launch. Hence
            // every launch, not once at install.
            try
            {
                if (DisplayMode.ForceWindowed(installPath)) Log.Write("display: forced windowed mode");
            }
            catch (Exception ex) { Log.Write($"windowed mode: {ex.Message}"); }

            GameProcess.Launch(installPath);

            // Copied after launch so it lands on the clipboard while the player is heading
            // for the login screen, rather than sitting there through a long update.
            if (_credentials.HasPassword && ClipboardHelper.CopyTemporarily(_credentials.Password))
                SetStatus($"Password copied — paste it with Ctrl+V " +
                          $"(cleared in {ClipboardHelper.ClearAfter.TotalSeconds:0}s).");
            else
                SetStatus("Launched. Have fun.");

            // Stay open behind the game, then re-arm so a player who logs out can relaunch
            // without restarting the launcher.
            await Task.Delay(TimeSpan.FromSeconds(10), _cts.Token);
            if (_closing) return;
            PlayButton.IsEnabled = true;
            SetStatus("Running.");
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Write(ex.ToString());
            MessageBox.Show($"Could not start the game.\n\n{ex.Message}", "Launch failed",
                MessageBoxButton.OK, MessageBoxImage.Error);
            if (!_closing) PlayButton.IsEnabled = true;
        }
    }

    private void OnRegister(object sender, RoutedEventArgs e) => OpenUrl(_manifest?.Realm.RegisterUrl);

    private void OnSavedLogin(object sender, RoutedEventArgs e)
    {
        var dialog = new LoginWindow(_credentials) { Owner = this };
        if (dialog.ShowDialog() != true) return;

        _credentials = dialog.Result;
        RefreshLoginLink();

        // The client pre-fills the account name from Config.wtf, so writing it there saves
        // the player typing the half we can actually fill in for them.
        if (_installPath is not null && _credentials.HasAccountName)
        {
            try
            {
                ConfigWtf.Update(_installPath,
                    new Dictionary<string, string> { ["accountName"] = _credentials.AccountName });
            }
            catch (Exception ex) { Log.Write($"accountName: {ex.Message}"); }
        }
    }

    private void RefreshLoginLink() =>
        LoginLink.Content = _credentials.HasPassword ? "Saved login ✓" : "Saved login";

    // ---------- helpers ----------

    private async Task RefreshRealmStatusAsync(Manifest manifest)
    {
        var up = await RealmStatus.IsReachableAsync(
            manifest.Realm.Address, manifest.Realm.AuthPort, _cts.Token);

        if (_closing) return;

        Dispatcher.Invoke(() =>
        {
            RealmDot.Fill = (System.Windows.Media.Brush)FindResource(up ? "Online" : "Offline");
            // A TCP connect only proves authserver is listening, so this says "reachable"
            // rather than claiming a player count we have no way to read.
            RealmText.Text = up
                ? $"{manifest.Realm.Name} — realm reachable"
                : $"{manifest.Realm.Name} — not responding";
        });
    }

    private async Task LoadNewsAsync(Manifest manifest)
    {
        // Runs detached from startup: news is decoration, and a slow realm box must not hold
        // up the sync or the PLAY button.
        var items = await new NewsService(_http).LoadAsync(manifest, _cts.Token);

        if (_closing) return;

        Dispatcher.Invoke(() =>
        {
            NewsList.ItemsSource = items;

            if (items.Count > 0)
            {
                NewsList.SelectedIndex = 0;
            }
            else
            {
                DetailTitle.Text = "No news yet.";
                DetailBody.Text = "Updates to the realm will show up here.";
            }
        });
    }

    private void OnNewsSelected(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (NewsList.SelectedItem is not NewsItem item) return;

        DetailDate.Text = item.Date;
        DetailTitle.Text = item.Title;
        DetailBody.Text = string.IsNullOrWhiteSpace(item.Body)
            ? "No further details."
            : item.Body;
    }

    private void EnablePlay(string summary)
    {
        _readyToPlay = true;
        Dispatcher.Invoke(() => PlayButton.IsEnabled = true);
        SetSummary(summary);
    }

    private void BlockPlay(string reason)
    {
        _readyToPlay = false;
        Dispatcher.Invoke(() => PlayButton.IsEnabled = false);
        SetStatus(reason);
    }

    /// <summary>
    /// Locks both buttons while an update is in flight — two syncs writing the same game
    /// folder at once is a good way to corrupt an MPQ — and restores PLAY to whatever the
    /// update decided when it lets go.
    /// </summary>
    private void SetBusy(bool busy) => Dispatcher.Invoke(() =>
    {
        CheckButton.IsEnabled = !busy;
        PlayButton.IsEnabled = !busy && _readyToPlay;
    });

    private void ShowVersions(ClientVersions versions)
    {
        _versions = versions;
        Dispatcher.Invoke(() => VersionText.Text = versions.Describe());
    }

    /// <summary>What the launcher is doing right now. Overwritten constantly.</summary>
    private void SetStatus(string text) => Dispatcher.Invoke(() => StatusText.Text = text);

    /// <summary>
    /// What the last update actually did. Deliberately a separate line from the status: it has
    /// to survive launching the game, so that "Running." does not erase the only record of what
    /// changed.
    /// </summary>
    private void SetSummary(string text) => Dispatcher.Invoke(() => SummaryText.Text = text);

    private void SetProgress(double fraction) =>
        Dispatcher.Invoke(() => Progress.Value = Math.Clamp(fraction * 1000, 0, 1000));

    private static void OpenUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return;
        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch { /* no browser association; nothing sensible to do */ }
    }
}
