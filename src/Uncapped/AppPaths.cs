using System.Reflection;

namespace Uncapped;

public static class AppPaths
{
    public const string AppName = "Uncapped";

    /// <summary>%LOCALAPPDATA%\Uncapped — no admin needed, and self-update works cleanly here.</summary>
    public static string DataDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);

    public static string StateFile => Path.Combine(DataDir, "state.json");
    public static string LogFile => Path.Combine(DataDir, "launcher.log");
    public static string DownloadDir => Path.Combine(DataDir, "downloads");
    public static string TorrentCacheDir => Path.Combine(DataDir, "torrent");

    /// <summary>
    /// The running executable. Environment.ProcessPath is the only reliable answer under
    /// PublishSingleFile, where Assembly.Location returns an empty string.
    /// </summary>
    public static string ExePath { get; } =
        Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, AppName + ".exe");

    public static string ExeDir => Path.GetDirectoryName(ExePath) ?? AppContext.BaseDirectory;

    public static string ConfigFile => Path.Combine(ExeDir, "uncapped.config.json");

    public static Version CurrentVersion { get; } =
        Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);

    public static void EnsureDirs()
    {
        Directory.CreateDirectory(DataDir);
        Directory.CreateDirectory(DownloadDir);
    }
}
