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

    /// <summary>What a legitimate client is made of. Null when the manifest publishes none.</summary>
    private Baseline? _baseline;

    /// <summary>
    /// The last verification result, kept so the REPAIR button knows what it is repairing
    /// without re-hashing 16 GB to find out again.
    /// </summary>
    private IntegrityReport? _report;

    /// <summary>
    /// Whether the player has already been shown, and dismissed, the warning about files that
    /// are not ours. Per-run rather than persisted: it is not nagging if it happens once per
    /// launcher start, and unlike the third-party addon warning this one describes a client
    /// that we genuinely cannot vouch for.
    /// </summary>
    private bool _foreignWarningShown;

    /// <summary>
    /// Guards SyncAndPrepareAsync against re-entering itself.
    ///
    /// Repair finishes by re-verifying, which means calling the sync — and the sync is what
    /// offers Repair in the first place. Without this, pressing Repair from the dialog runs a
    /// second sync inside the first one, two of them writing the same game folder at once.
    /// </summary>
    private bool _syncing;

    /// <summary>
    /// Set when the player asks for a repair from the warning dialog, and acted on only once
    /// the sync that raised the dialog has fully unwound.
    /// </summary>
    private bool _repairRequested;

    /// <summary>
    /// Whether a repair has already run without the player pressing anything since. Stops a
    /// fault the repair cannot actually fix from becoming a loop of
    /// verify -> warn -> repair -> verify. One automatic attempt, then it is their move.
    /// </summary>
    private bool _autoRepairUsed;

    public MainWindow(HttpClient http, LauncherConfig config, LauncherState state)
    {
        _http = http;
        _config = config;
        _state = state;

        InitializeComponent();

        // ToString(3) trims the trailing build field the assembly always carries
        // (1.7.1.0), so this reads as the version people are actually told about.
        LauncherVersionText.Text = $"v{AppPaths.CurrentVersion.ToString(3)}";

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
            // still be able to play on whatever they last synced. But "we cannot reach GitHub"
            // is not a reason to stop checking the files that are already on disk — that used
            // to enable PLAY on no evidence whatsoever, which made being offline the simplest
            // way to launch a client nothing had ever verified.
            SetStatus($"Could not reach the update server — {ex.Message}");
            Log.Write(ex.ToString());

            if (InstallLocator.IsValidInstall(_state.InstallPath))
            {
                _installPath = _state.InstallPath;
                ShowVersions(new ClientVersions(ClientVersionService.ReadInstalled(_installPath), null, null, true));
                await VerifyOfflineAsync();
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

        if (!string.IsNullOrWhiteSpace(_manifest.DonateUrl))
            DonatePanel.Visibility = Visibility.Visible;

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
            // Logged because "which folder did it decide to use" is the first thing worth
            // knowing about a client that will not start, and the launcher never used to say.
            Log.Write($"install: using {found.Path} ({found.Source})");
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

    /*
     * Offer a desktop shortcut, once, after a real install.
     *
     * Asked rather than assumed: putting an icon on someone's desktop uninvited is the kind
     * of thing installers get resented for. The answer is remembered either way, so declining
     * is not re-asked on every reinstall, and an existing shortcut is left alone.
     */
    private void OfferDesktopShortcut()
    {
        try
        {
            if (_config.DesktopShortcutAsked || DesktopShortcut.Exists()) return;

            _config.DesktopShortcutAsked = true;
            _config.Save();

            var answer = MessageBox.Show(
                "Add an Uncapped shortcut to your desktop?",
                "Desktop shortcut", MessageBoxButton.YesNo, MessageBoxImage.Question);

            if (answer != MessageBoxResult.Yes) return;

            if (!DesktopShortcut.Create())
                MessageBox.Show(
                    "The shortcut could not be created. You can still start the game from this launcher.",
                    "Shortcut", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        catch (Exception ex) { Log.Write($"desktop shortcut prompt: {ex}"); }
    }

    /*
     * Point out addons that are not ours, once.
     *
     * Nothing is disabled or removed. A player who installed something is entitled to keep
     * it; the value here is purely that when Lua errors start appearing they know which
     * addons we did not put there and can bisect from a shorter list.
     */
    private void WarnAboutForeignAddOns(string installPath, Manifest manifest)
    {
        try
        {
            if (_config.ForeignAddOnWarningDismissed) return;

            var foreign = ForeignAddOnScanner.Scan(installPath, manifest);
            if (foreign.Count == 0) return;

            Log.Write($"third-party addons: {string.Join(", ", foreign)}");

            var dialog = new AddOnWarningWindow(foreign) { Owner = this };
            dialog.ShowDialog();

            if (dialog.DoNotAskAgain)
            {
                _config.ForeignAddOnWarningDismissed = true;
                _config.Save();
            }
        }
        catch (Exception ex) { Log.Write($"third-party addon warning: {ex}"); }
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

            var check = InstallLocator.Validate(dialog.SelectedPath);
            if (check.Ok)
            {
                Log.Write($"install: using {dialog.SelectedPath} (picked)");
                _state.InstallPath = dialog.SelectedPath;
                _state.Save();
                return dialog.SelectedPath;
            }

            // The specific reason, not "that does not look like a WoW install". A player who
            // picked their Cataclysm folder needs to be told that, not left to guess.
            Log.Write($"install: rejected {dialog.SelectedPath} — {check.Reason}");
            MessageBox.Show(
                $"That folder cannot be used.\n\n{check.Reason}",
                "Wrong folder", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private async Task<string?> DownloadClientAsync(Manifest manifest)
    {
        /*
         * ★ THE BASELINE IS LOADED BEFORE THE CLIENT IS DOWNLOADED, NOT AFTER.
         *
         * It used to be fetched only on the verification pass, which ran after acquisition had
         * already finished. That ordering is what allowed the launcher to install a client from
         * a mirror and only then discover it was a different 3.3.5a build -- see the header of
         * ClientAcquirer. Acquisition now works from the same file list the verifier uses, so
         * it has to be in hand first. The ??= keeps this to one fetch per run.
         */
        _baseline ??= await new BaselineService(_http).LoadAsync(manifest, _cts.Token);

        if (!string.IsNullOrWhiteSpace(manifest.BaselineUrl) && _baseline is null)
        {
            /*
             * Refusing is the honest answer, and the cheap one to recover from.
             *
             * Without the baseline we do not know which files the client needs or what they
             * should hash to, so the best we could do is unpack a mirror and hope -- which is
             * precisely the behaviour being removed. A player who cannot reach the patch host
             * cannot play either, so stopping here costs them nothing and tells them something
             * true, instead of spending 17 GB of their bandwidth to fail later.
             */
            Log.Write("install: refusing to download a client — the baseline could not be fetched");
            MessageBox.Show(
                "The launcher could not reach the update server to find out which game files to " +
                "download.\n\nCheck your internet connection and try again. If it keeps happening, " +
                "the server may be down for a moment.",
                "Cannot download the game yet", MessageBoxButton.OK, MessageBoxImage.Error);
            SetStatus("Could not reach the update server.");
            return null;
        }

        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = "Choose where to install the game (about 17 GB, plus the same again while unpacking)",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
        };

        /*
         * Ask where to install, and keep asking until the player is happy.
         *
         * Two things this has to get right. The picker asks for a PARENT folder and a
         * "WoW335" subfolder is appended, so what the player chose and what they get are not
         * the same string -- someone picking their desktop had no way to know the game was
         * not going to land directly on it. And "Cancel" on the confirmation used to abandon
         * the whole install rather than let them choose somewhere else, so a wrong first
         * guess meant starting the launcher again.
         *
         * Loop instead: cancel means "not there", not "forget it". Backing out of the picker
         * itself is the way to actually stop.
         */
        string target;

        while (true)
        {
            if (dialog.ShowDialog() != System.Windows.Forms.DialogResult.OK) return null;

            /*
             * ★ DO NOT APPEND WoW335 TO A FOLDER THAT IS ALREADY WoW335.
             *
             * The picker reopens at the last location used, which after a failed
             * attempt is the WoW335 folder this code created. Accepting that gives
             * F:\...\WoW335\WoW335, and the next retry gives WoW335\WoW335\WoW335 --
             * one level deeper every time, each install stranded somewhere the
             * launcher will not look again.
             *
             * Seen in a player's log on 2026-08-11, alternating between
             * F:\Bryan wow\WoW335 and F:\Bryan wow\WoW335\WoW335 across four
             * attempts in twenty minutes.
             *
             * Someone who navigates INTO the folder they want to install to means
             * "here", and the confirmation dialog shows them the final path either
             * way, so this cannot silently install somewhere unexpected.
             */
            var chosen = dialog.SelectedPath.TrimEnd(Path.DirectorySeparatorChar,
                                                     Path.AltDirectorySeparatorChar);

            target = string.Equals(Path.GetFileName(chosen), "WoW335",
                        StringComparison.OrdinalIgnoreCase)
                ? chosen
                : Path.Combine(chosen, "WoW335");

            var confirm = MessageBox.Show(
                "The game will be installed to:" + Environment.NewLine + Environment.NewLine +
                target + Environment.NewLine + Environment.NewLine +
                "That needs about 17 GB, plus the same again briefly while it unpacks." +
                Environment.NewLine + Environment.NewLine +
                "Install here?",
                "Confirm install location", MessageBoxButton.YesNo, MessageBoxImage.Information);

            if (confirm == MessageBoxResult.Yes) break;
        }

        try
        {
            var acquirer = new ClientAcquirer(_http, _config.TorrentAllowInbound);
            var reporter = new Progress<AcquireProgress>(p =>
            {
                SetStatus($"{p.Status} — {p.Detail}");
                SetProgress(p.Fraction);
            });

            var baseFiles = ClientAcquirer.BaseFilesFrom(_baseline, manifest);
            Log.Write($"install: {baseFiles.Count} hosted base file(s) will be enforced after unpacking");

            await acquirer.AcquireAsync(manifest.Client, baseFiles, target, reporter, _cts.Token);
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
            // Says which part is wrong. The mirror ships the game and the language files as
            // two separate zips, so "downloaded but unusable" is most often the second one
            // having failed — and the old wording sent everyone looking for a missing .exe.
            var reason = InstallLocator.Validate(target).Reason;
            Log.Write($"install: downloaded client at {target} failed validation — {reason}");
            MessageBox.Show(
                $"The client was downloaded but cannot be used.\n\n{reason}\n\n" +
                "Deleting the folder and running the launcher again will re-download it.",
                "Incomplete download", MessageBoxButton.OK, MessageBoxImage.Error);
            return null;
        }

        _state.InstallPath = root;
        _state.Save();

        // First install only: windowed at the desktop resolution and the terms screens
        // pre-dismissed, written straight to Config.wtf. This used to start the game to make
        // the file exist; it no longer does.
        try
        {
            await FirstRunConfigurator.ConfigureAsync(root, new Progress<string>(SetStatus), _cts.Token);
        }
        catch (OperationCanceledException) { return null; }
        catch (Exception ex) { Log.Write($"first-run config: {ex}"); }

        OfferDesktopShortcut();

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

    /// <summary>
    /// Runs the sync, then acts on a repair the player asked for while it was running.
    ///
    /// Split from the body below so the repair starts only after this call has completely
    /// unwound — Repair re-verifies by calling back into the sync, and starting that from
    /// inside the sync's own try/finally had two of them updating the same folder at once.
    /// </summary>
    private async Task SyncAndPrepareAsync()
    {
        if (_syncing) return;

        _syncing = true;
        try { await SyncAndPrepareCoreAsync(); }
        finally { _syncing = false; }

        if (!_repairRequested) return;

        _repairRequested = false;

        // One automatic go. If the client is still broken afterwards the REPAIR CLIENT button
        // is on screen and says so; retrying forever would just hammer the patch host.
        if (_autoRepairUsed)
        {
            Log.Write("repair: already attempted once since the last player action; not retrying");
            return;
        }

        _autoRepairUsed = true;
        await RepairAsync();
    }

    private async Task SyncAndPrepareCoreAsync()
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

        /*
         * Which language the client is, decided once and used for everything below.
         *
         * The manifest describes our payload as Data/enUS/patch-enUS-*.mpq because that is
         * what the client we ship is. Installing those paths verbatim into an enGB client
         * creates a second, half-empty locale folder that stops the game booting, so the
         * paths are moved onto whatever locale is actually on disk.
         *
         * Logged unconditionally. A broken-client report always turns on this question and
         * launcher.log had no way to answer it.
         */
        var locale = ClientLocale.Detect(installPath);

        if (locale is null)
        {
            var reason = InstallLocator.Validate(installPath).Reason;
            Log.Write($"locale: none detected at {installPath} — {reason}");
            SetStatus("That game folder cannot be used.");
            MessageBox.Show(
                $"The game folder cannot be used.\n\n{reason}\n\n" +
                "Use \"Change game folder\" to point the launcher somewhere else.",
                "Game folder problem", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        Log.Write($"locale: {locale.Describe()}");

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
                        .SyncAsync(installPath, manifest, _state, locale, reporter, _cts.Token);
                }
                catch (OperationCanceledException) { return; }
                catch (Exception ex)
                {
                    // Previously: EnablePlay("You can still play, but your files may be out of
                    // date."). They could not, in any useful sense — an out-of-date payload is
                    // precisely what version_gate.lua disconnects them for, roughly 25 seconds
                    // after they reach the character screen. Letting them launch converted a
                    // clear launcher error into an unexplained kick from the realm.
                    Log.Write(ex.ToString());
                    BlockPlay($"Update failed — {ex.Message}");
                    SetSummary("PLAY is off until the update finishes. " +
                               "Press CHECK FOR UPDATES to try again.");
                    ShowRepair(true);
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
                installPath, manifest.Realm.Address, manifest.Realm.Name, locale);
            foreach (var failure in realm.Failed) Log.Write($"realmlist: {failure}");

            AddOnsTxtEnforcer.Apply(installPath, manifest.ForceEnableAddOns, manifest.ForceDisableAddOns);

            // After the sync, so the folder is in its final state: warning about an addon we
            // were about to install ourselves would be nonsense.
            WarnAboutForeignAddOns(installPath, manifest);

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

            // Unconditional, NOT gated on outcome.ChangedAnything. WDB is keyed by entry id and
            // is not namespaced per realm, so a player who also plays elsewhere brings that
            // server's item/creature/quest data back with them — and none of that changes our
            // payload, so a "did our sync touch anything" gate never fires for the case that
            // actually causes stale entries. Refetching is spread over play as entries are
            // encountered, not a burst at login, so clearing every time is worth it.
            //
            // Every cache but itemcache.wdb is still cleared on every launch for exactly that
            // reason. itemcache.wdb we now generate server-side and install, keyed on an epoch
            // token rather than a hash — see WdbCache. Never throws; every failure ends in the
            // old wipe.
            var wdb = await new WdbCache(_http).SyncAsync(installPath, manifest, locale, _cts.Token);
            Log.Write($"wdb: {wdb.Detail}; removed {wdb.Deleted} cached file(s)");

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
                //
                // This used to let the player through with "Ready, but N file(s) failed to
                // update." It is exactly the client the server's version gate then kicks 25
                // seconds after login, which reads as the realm being broken. A launcher that
                // cannot finish updating has not made a playable client, and saying so is the
                // whole point of the button.
                BlockPlay($"{outcome.Errors.Count} file(s) could not be updated.");
                SetSummary("PLAY is off until every file updates cleanly. " +
                           "Press CHECK FOR UPDATES to try again — launcher.log says what failed.");
                ShowRepair(true);
                return;
            }

            // Archives are counted separately from files: installing ArkInventory unpacks
            // 171 files the manifest never lists individually, so reporting only
            // outcome.Downloaded would say "Updated 0 file(s)." after real work happened.
            var summary = outcome.Downloaded > 0 ? $"Updated {outcome.Downloaded} file(s)." : "";
            if (outcome.ArchivesInstalled > 0)
                summary = (summary.Length > 0 ? summary + " " : "")
                        + $"Installed {outcome.ArchivesInstalled} addon(s).";

            if (!outcome.ChangedAnything) summary = "Up to date.";
            else if (summary.Length == 0) summary = "Updated.";

            // Everything above only proves our own payload is right. The client is 16 GB of
            // files we did not publish, and until 1.10 nothing looked at any of them.
            await VerifyAndDecideAsync(manifest, installPath, locale, summary);
        }
        finally { SetBusy(false); }
    }

    // ---------- integrity ----------

    /// <summary>
    /// Verifies an offline start against the last manifest and baseline we cached.
    ///
    /// Deliberately still a hard gate. The one thing being offline genuinely prevents is
    /// learning about a NEWER release — it does not prevent checking that the files already
    /// on disk are the ones we last published, and that is what decides whether the client
    /// works. With no cached manifest there is nothing to check against and nothing to
    /// honestly claim, so PLAY stays off until the network comes back.
    /// </summary>
    private async Task VerifyOfflineAsync()
    {
        if (_installPath is null) return;

        var cached = ManifestService.LoadCached();
        if (cached is null)
        {
            BlockPlay("Could not reach the update server, and nothing has been downloaded yet.");
            SetSummary("PLAY is off until the launcher can check your files at least once. " +
                       "Press CHECK FOR UPDATES when you are back online.");
            return;
        }

        _manifest = cached.Manifest;
        _manifestHash = cached.Hash;

        var locale = ClientLocale.Detect(_installPath);
        if (locale is null)
        {
            BlockPlay("That game folder cannot be used.");
            return;
        }

        Log.Write("integrity: offline start, verifying against the cached manifest and baseline");
        await VerifyAndDecideAsync(cached.Manifest, _installPath, locale, "Offline — using your current files.");
    }

    /// <summary>
    /// Verifies the whole client and decides whether PLAY is allowed.
    ///
    /// Three outcomes:
    ///
    ///   * Clean — PLAY on, nothing said beyond the usual summary.
    ///   * Files missing or altered — PLAY OFF, warning shown, REPAIR offered. This is the
    ///     case that used to reach the login screen and get kicked.
    ///   * Only unrecognised extras — PLAY stays ON, but the player is told once that we
    ///     cannot recognise their install as a legitimate Uncapped release, and REPAIR stays
    ///     available. An extra file is their business; it is not ours to refuse to launch over.
    ///
    /// A client with no published baseline verifies our payload alone, which is what every
    /// launcher before 1.10 did.
    /// </summary>
    private async Task VerifyAndDecideAsync(
        Manifest manifest, string installPath, ClientLocale? locale, string summary)
    {
        _report = null;

        _baseline ??= await new BaselineService(_http).LoadAsync(manifest, _cts.Token);

        if (_baseline is null)
        {
            // No baseline to check against. The payload sync above already succeeded, so this
            // is the old behaviour rather than a failure — but PLAY is granted on strictly
            // less evidence, and the log should say so when someone asks why a bad client
            // got through.
            Log.Write("integrity: no baseline available; verified manifest files only");
            _state.LastManifestHash = _manifestHash;
            _state.Save();
            ShowRepair(false);
            EnablePlay(summary);
            SetStatus("Ready.");
            return;
        }

        IntegrityReport report;
        try
        {
            var reporter = new Progress<SyncProgress>(p =>
            {
                SetStatus($"{p.Status}  ({p.Completed}/{p.Total})");
                SetProgress(p.Total == 0 ? 1 : (double)p.Completed / p.Total);
            });

            report = await new IntegrityVerifier(installPath, manifest, _baseline, locale, _state)
                .VerifyAsync(reporter, _cts.Token);
        }
        catch (OperationCanceledException) { return; }
        catch (Exception ex)
        {
            // A verifier that throws must not become a way to play unverified. It also must
            // not permanently brick a launcher over a bug in our own scanning code, so this
            // says plainly what happened and leaves CHECK FOR UPDATES as the way to retry.
            Log.Write($"integrity: verification failed — {ex}");
            BlockPlay("Your game files could not be checked.");
            SetSummary("PLAY is off because the file check did not finish. " +
                       "Press CHECK FOR UPDATES to try again — launcher.log has the details.");
            ShowRepair(true);
            return;
        }

        _report = report;
        SetProgress(1);

        Log.Write($"integrity: {report.Checked} checked, {report.Skipped} absent-and-optional, " +
                  $"{report.BytesHashed / (1024 * 1024)} MB hashed, {report.Problems.Count} problem(s)");

        foreach (var p in report.Problems.Take(40))
            Log.Write($"integrity: {p.Fault} {(p.Blocking ? "(blocking) " : "")}{p.Path}");

        if (report.Problems.Count > 40)
            Log.Write($"integrity: … and {report.Problems.Count - 40} more");

        if (report.Clean)
        {
            _state.LastManifestHash = _manifestHash;
            _state.Save();
            ShowRepair(false);
            EnablePlay(summary);
            SetStatus("Ready.");
            return;
        }

        ShowRepair(true);

        if (!report.CanPlay)
        {
            var n = report.Blocking.Count();
            BlockPlay($"{n} game file(s) are missing or altered.");
            SetSummary("PLAY is off until this is fixed. Press REPAIR CLIENT to download clean copies.");

            ShowIntegrityWarning(report);
            return;
        }

        // Foreign files only. Playable, but not something we can vouch for.
        _state.LastManifestHash = _manifestHash;
        _state.Save();

        var foreignCount = report.Foreign.Count();
        EnablePlay($"{summary} {foreignCount} file(s) in your game folder are not ours — press REPAIR CLIENT.".Trim());
        SetStatus("Ready.");

        ShowIntegrityWarning(report);
    }

    /// <summary>
    /// Shows the problem list, and runs the repair if that is what they choose.
    ///
    /// Shown at most once per launcher run for the playable case, so someone who has decided
    /// to keep a foreign file is not asked again every time they press PLAY. The blocking case
    /// is always shown: there, the dialog is the explanation for why the button is dead.
    /// </summary>
    private void ShowIntegrityWarning(IntegrityReport report)
    {
        if (report.CanPlay && _foreignWarningShown) return;
        _foreignWarningShown = true;

        var dialog = new IntegrityWarningWindow(report) { Owner = this };
        dialog.ShowDialog();

        // Recorded rather than acted on: see SyncAndPrepareAsync. Starting the repair from
        // here would re-enter the sync that is still on the stack above us.
        if (dialog.RepairRequested) _repairRequested = true;
    }

    private void ShowRepair(bool visible) => Dispatcher.Invoke(() =>
        RepairButton.Visibility = visible ? Visibility.Visible : Visibility.Collapsed);

    private async void OnRepair(object sender, RoutedEventArgs e)
    {
        // A deliberate press is always honoured, and re-arms the one automatic attempt.
        _autoRepairUsed = false;
        await RepairAsync();
    }

    /// <summary>
    /// Puts the client back to what a release actually is, then re-verifies.
    ///
    /// Re-verification is not optional: repair is only worth anything if the result is checked,
    /// and a download that silently failed would otherwise leave PLAY enabled on the strength
    /// of having tried.
    /// </summary>
    private async Task RepairAsync()
    {
        if (_installPath is null || _manifest is null) return;

        var installPath = _installPath;
        var manifest = _manifest;

        if (GameProcess.IsRunning(installPath))
        {
            MessageBox.Show(
                "World of Warcraft is running.\n\nClose it before repairing — game files cannot " +
                "be replaced while the client has them open.",
                "Game is running", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        // Re-verify first when we have nothing to go on. Pressing REPAIR after a launcher
        // restart should not be a no-op just because the report lives in memory.
        var report = _report;

        SetBusy(true);
        try
        {
            var locale = ClientLocale.Detect(installPath);
            var reporter = new Progress<SyncProgress>(p =>
            {
                SetStatus($"{p.Status}  ({p.Completed}/{p.Total})");
                SetProgress(p.Total == 0 ? 1 : (double)p.Completed / p.Total);
            });

            if (report is null && _baseline is not null)
            {
                SetStatus("Checking your game files…");
                report = await new IntegrityVerifier(installPath, manifest, _baseline, locale, _state)
                    .VerifyAsync(reporter, _cts.Token);
            }

            var repair = new RepairService(_http);
            var restored = 0;
            var quarantined = 0;
            var errors = new List<string>();

            if (report is not null)
            {
                var broken = report.Problems
                    .Where(p => p.Fault is IntegrityFault.Missing or IntegrityFault.Corrupt)
                    .ToList();

                if (broken.Count > 0)
                {
                    SetStatus($"Restoring {broken.Count} file(s)…");
                    var outcome = await repair.RestoreAsync(installPath, broken, _state, reporter, _cts.Token);
                    restored = outcome.Restored;
                    errors.AddRange(outcome.Errors);
                }

                // Moving someone's file is asked for separately and by name, even though they
                // already pressed a button called Repair. "Repair" does not obviously mean
                // "take this away", and the file may be the only copy they have.
                var archives = report.Problems.Where(p => p.IsForeignArchive).ToList();
                if (archives.Count > 0 && ConfirmQuarantine(archives))
                {
                    var outcome = repair.Quarantine(installPath, archives, _state);
                    quarantined = outcome.Quarantined;
                    errors.AddRange(outcome.Errors);
                }
            }

            foreach (var error in errors) Log.Write($"repair: {error}");

            Log.Write($"repair: restored {restored}, quarantined {quarantined}, {errors.Count} error(s)");

            // Whatever happened, the answer now comes from re-reading the disk rather than
            // from what we intended to do to it.
            SetStatus("Re-checking your game files…");
            await SyncAndPrepareAsync();

            if (restored > 0 || quarantined > 0)
            {
                var parts = new List<string>();
                if (restored > 0) parts.Add($"restored {restored} file(s)");
                if (quarantined > 0) parts.Add($"moved {quarantined} file(s) to Data\\_disabled");
                SetSummary($"Repair {string.Join(" and ", parts)}.");
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Write($"repair: {ex}");
            SetStatus($"Repair failed — {ex.Message}");
            MessageBox.Show($"The repair could not finish.\n\n{ex.Message}", "Repair failed",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally { SetBusy(false); }
    }

    private bool ConfirmQuarantine(IReadOnlyList<IntegrityProblem> archives)
    {
        var names = string.Join(Environment.NewLine,
            archives.Take(12).Select(a => "    " + a.Path));

        if (archives.Count > 12) names += $"{Environment.NewLine}    … and {archives.Count - 12} more";

        var answer = MessageBox.Show(
            "These files are not part of any Uncapped release:" + Environment.NewLine + Environment.NewLine +
            names + Environment.NewLine + Environment.NewLine +
            "They will be MOVED to Data\\_disabled inside your game folder, not deleted — the " +
            "game stops loading them and you can drag them back at any time." + Environment.NewLine +
            Environment.NewLine +
            "Move them?",
            "Files we do not recognise", MessageBoxButton.YesNo, MessageBoxImage.Question);

        return answer == MessageBoxResult.Yes;
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
        // A player action, so the single automatic repair attempt is available again.
        _autoRepairUsed = false;

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

            // View distance, once per install. Flying in the old world needs it, and fog is
            // never drawn past farclip — but unlike windowed mode this is a performance choice,
            // so it is applied a single time and then left to the player. See ViewDistance.
            if (!_state.ViewDistanceRaised)
            {
                try
                {
                    if (ViewDistance.RaiseToMax(installPath))
                        Log.Write($"display: view distance raised to {ViewDistance.Max}");
                    _state.ViewDistanceRaised = true;
                    _state.Save();
                }
                catch (Exception ex) { Log.Write($"view distance: {ex.Message}"); }
            }

            // Last thing before launching, and after the sync has had its chance to put the
            // file back. Import injection makes the DLL a hard loader dependency, so a
            // missing one is not a degraded client -- it is a client that will not start,
            // with an error message that blames nothing the player can act on.
            if (_manifest is not null &&
                InjectedRuntime.DescribeProblem(_manifest, installPath) is { } problem)
            {
                Log.Write($"launch blocked: {InjectedRuntime.DllName} missing from {installPath}");
                MessageBox.Show(problem, "Missing game file",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                SetStatus($"{InjectedRuntime.DllName} is missing — see the message above.");
                PlayButton.IsEnabled = true;
                return;
            }

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

    private void OnDonate(object sender, RoutedEventArgs e) => OpenUrl(_manifest?.DonateUrl);

    /// <summary>
    /// Opens launcher.log in whatever handles .log — Notepad on a default Windows install.
    ///
    /// The file is created empty if it does not exist yet, so the button never fails on a
    /// launcher that has had nothing to say. If the extension has no association, Explorer is
    /// opened with the file selected instead: the folder is the fallback answer, and it still
    /// beats reciting an environment variable in Discord.
    /// </summary>
    private void OnOpenLog(object sender, RoutedEventArgs e)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.DataDir);
            if (!File.Exists(AppPaths.LogFile)) File.WriteAllText(AppPaths.LogFile, "");

            Process.Start(new ProcessStartInfo { FileName = AppPaths.LogFile, UseShellExecute = true });
        }
        catch
        {
            try { Process.Start("explorer.exe", $"/select,\"{AppPaths.LogFile}\""); }
            catch (Exception ex) { Log.Write($"open log: {ex.Message}"); }
        }
    }

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
