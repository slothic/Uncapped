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

    private Credentials _credentials = Credentials.Load();
    private Manifest? _manifest;
    private string? _manifestHash;
    private string? _installPath;
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
                EnablePlay("Playing offline with your current files.");
            }
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

        SyncOutcome outcome;
        try
        {
            var reporter = new Progress<SyncProgress>(p =>
            {
                SetStatus($"{p.Status}  ({p.Completed}/{p.Total})");
                SetProgress(p.Total == 0 ? 1 : (double)p.Completed / p.Total);
            });

            outcome = await new SyncService(_http)
                .SyncAsync(_installPath, _manifest, _state, reporter, _cts.Token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception ex)
        {
            Log.Write(ex.ToString());
            SetStatus($"Update failed — {ex.Message}");
            EnablePlay("You can still play, but your files may be out of date.");
            return;
        }

        SetProgress(1);

        var realm = ClientConfigWriter.WriteRealmlist(
            _installPath, _manifest.Realm.Address, _manifest.Realm.Name);
        foreach (var failure in realm.Failed) Log.Write($"realmlist: {failure}");

        AddOnsTxtEnforcer.Apply(_installPath, _manifest.ForceEnableAddOns, _manifest.ForceDisableAddOns);

        if (_manifest.HardenClient)
        {
            var hardened = ClientHardening.Apply(_installPath);
            foreach (var note in hardened.Notes) Log.Write($"hardening: {note}");
        }

        if (_manifest.LargeAddressAware)
        {
            var laa = Services.LargeAddressAware.Apply(_installPath);
            if (laa.Changed) Log.Write($"large address aware: {laa.Detail}");
        }

        // Only worth clearing when something actually changed — it costs the player a slower
        // first login while the client refetches.
        if (outcome.ChangedAnything) WdbCleaner.Clear(_installPath);

        try
        {
            var sent = await new CrashReporter(_http)
                .ReportNewCrashesAsync(_installPath, _manifest, _state, _cts.Token);
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
                ? $"Updated {outcome.Downloaded} file(s). Ready to play."
                : "Up to date.");
        }
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

        if (GameProcess.IsRunning(_installPath))
        {
            MessageBox.Show("World of Warcraft is already running.", "Already running",
                MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        try
        {
            PlayButton.IsEnabled = false;
            await RefreshBeforeLaunchAsync();

            // The sync refuses while the game is up, and it may have taken a while, so
            // re-check rather than trusting the state from before the update.
            if (_closing) return;
            if (GameProcess.IsRunning(_installPath))
            {
                PlayButton.IsEnabled = true;
                return;
            }

            GameProcess.Launch(_installPath);

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

    private void EnablePlay(string status)
    {
        _readyToPlay = true;
        Dispatcher.Invoke(() => PlayButton.IsEnabled = true);
        SetStatus(status);
    }

    private void SetStatus(string text) => Dispatcher.Invoke(() => StatusText.Text = text);

    private void SetProgress(double fraction) =>
        Dispatcher.Invoke(() => Progress.Value = Math.Clamp(fraction * 1000, 0, 1000));

    private static void OpenUrl(string? url)
    {
        if (string.IsNullOrWhiteSpace(url)) return;
        try { Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true }); }
        catch { /* no browser association; nothing sensible to do */ }
    }
}
