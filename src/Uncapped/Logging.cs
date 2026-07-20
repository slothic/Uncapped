namespace Uncapped;

/// <summary>
/// Appends to %LOCALAPPDATA%\Uncapped\launcher.log. Deliberately free of any UI dependency so
/// the services can log without dragging the form in behind them.
/// </summary>
public static class Log
{
    private static readonly object Gate = new();

    public static void Write(string message)
    {
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(AppPaths.DataDir);
                File.AppendAllText(AppPaths.LogFile, $"{DateTime.Now:u}  {message}{Environment.NewLine}");
            }
        }
        catch { /* logging must never throw */ }
    }
}
