using System.Net;
using System.Net.Http;
using System.Windows;
using Uncapped.Model;

namespace Uncapped;

public partial class App : Application
{
    private Mutex? _single;
    private HttpClient? _http;
    private HttpClientHandler? _handler;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        // A second copy syncing the same folder is a good way to corrupt an MPQ.
        _single = new Mutex(true, @"Global\UncappedLauncher", out var isOnly);
        if (!isOnly)
        {
            MessageBox.Show("The Uncapped launcher is already open.", "Already running",
                MessageBoxButton.OK, MessageBoxImage.Information);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, args) =>
        {
            Log.Write($"FATAL: {args.Exception}");
            MessageBox.Show(
                $"Something went wrong.\n\n{args.Exception.Message}\n\nDetails were written to:\n{AppPaths.LogFile}",
                "Uncapped Launcher", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Write($"FATAL: {args.ExceptionObject}");

        _handler = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            // The sync downloads several files at once; without headroom here they would
            // queue behind a smaller default connection pool and undo the parallelism.
            MaxConnectionsPerServer = 12,
        };
        _http = new HttpClient(_handler) { Timeout = TimeSpan.FromMinutes(30) };
        _http.DefaultRequestHeaders.UserAgent.ParseAdd($"UncappedLauncher/{AppPaths.CurrentVersion}");

        new MainWindow(_http, LauncherConfig.Load(), LauncherState.Load()).Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _http?.Dispose();
        _handler?.Dispose();
        _single?.Dispose();
        base.OnExit(e);
    }
}
