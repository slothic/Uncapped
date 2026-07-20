using System.Net;
using Uncapped.Model;

namespace Uncapped;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();

        // A second copy syncing the same folder is a good way to corrupt an MPQ.
        using var single = new Mutex(true, @"Global\UncappedLauncher", out var isOnly);
        if (!isOnly)
        {
            MessageBox.Show("The Uncapped launcher is already open.", "Already running",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
        {
            MainForm.Log($"FATAL: {e.ExceptionObject}");
            MessageBox.Show(
                $"Something went wrong.\n\n{e.ExceptionObject}\n\nDetails were written to:\n{AppPaths.LogFile}",
                "Uncapped Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
        };

        using var handler = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
            // The sync downloads several files at once; without headroom here they would
            // queue behind a smaller default connection pool and undo the parallelism.
            MaxConnectionsPerServer = 12,
        };
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd($"UncappedLauncher/{AppPaths.CurrentVersion}");

        var config = LauncherConfig.Load();
        var state = LauncherState.Load();

        Application.Run(new MainForm(http, config, state));
    }
}
