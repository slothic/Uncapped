using System.Windows;
using System.Windows.Threading;

namespace Uncapped.Services;

/// <summary>
/// Puts the password on the clipboard so the player can paste it at the login screen, then
/// takes it back off again.
///
/// The clipboard is readable by every process on the machine, so leaving a password sitting
/// there indefinitely would be worse than not storing it at all. It is cleared after a short
/// window — and only if it still holds what we put there, so we never wipe something the
/// player copied in the meantime.
/// </summary>
public static class ClipboardHelper
{
    public static readonly TimeSpan ClearAfter = TimeSpan.FromSeconds(45);

    /// <summary>
    /// Copies the text and schedules a clear. Returns false if the clipboard could not be
    /// written — another process can hold it open, and that is not worth failing a launch for.
    /// </summary>
    public static bool CopyTemporarily(string text)
    {
        if (!TrySet(text)) return false;

        var timer = new DispatcherTimer { Interval = ClearAfter };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            ClearIfUnchanged(text);
        };
        timer.Start();

        return true;
    }

    private static bool TrySet(string text)
    {
        // The clipboard is a shared, single-owner resource; a transient failure while another
        // app holds it is normal, so retry briefly before giving up.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            try
            {
                Clipboard.SetText(text);
                return true;
            }
            catch
            {
                Thread.Sleep(60);
            }
        }

        Log.Write("clipboard: could not copy the password (another app may be holding it)");
        return false;
    }

    private static void ClearIfUnchanged(string expected)
    {
        try
        {
            if (Clipboard.ContainsText() && Clipboard.GetText() == expected)
                Clipboard.Clear();
        }
        catch { /* nothing sensible to do; it will be overwritten eventually */ }
    }
}
