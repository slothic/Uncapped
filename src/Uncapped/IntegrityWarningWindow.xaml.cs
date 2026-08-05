using System.Windows;
using Media = System.Windows.Media;
using Uncapped.Services;

namespace Uncapped;

/// <summary>
/// Shows what is wrong with the client and offers to put it right.
///
/// The wording changes with the severity, because the two cases are genuinely different and
/// blurring them would be dishonest:
///
///   * Files missing or altered — the client will not work correctly, PLAY is already off,
///     and Repair is the way forward.
///
///   * Only unrecognised extras — the install still runs. We say we cannot recognise it as a
///     legitimate Uncapped release and that they may hit problems, and then leave the decision
///     with them. PLAY stays on. Someone who deliberately keeps a file from another server is
///     entitled to, as long as they know what it means when something breaks.
/// </summary>
public partial class IntegrityWarningWindow : Window
{
    /// <summary>One row, shaped for the template rather than for the verifier.</summary>
    public sealed record Row(string Label, string Path, string Size, Media.Brush Colour);

    public bool RepairRequested { get; private set; }

    private static readonly Media.Brush Blocking = new Media.SolidColorBrush(Media.Color.FromRgb(0xE0, 0x6C, 0x75));
    private static readonly Media.Brush Extra    = new Media.SolidColorBrush(Media.Color.FromRgb(0xD8, 0xA6, 0x57));

    public IntegrityWarningWindow(IntegrityReport report)
    {
        InitializeComponent();

        var blocking = report.Blocking.ToList();
        var foreign  = report.Foreign.ToList();

        ProblemList.ItemsSource = blocking
            .Select(p => new Row(
                p.Fault == IntegrityFault.Missing ? "MISSING" : "ALTERED",
                p.Path, Describe(p.Size), Blocking))
            .Concat(foreign.Select(p => new Row(
                "NOT OURS", p.Path, Describe(p.Size), Extra)))
            .ToList();

        if (blocking.Count > 0)
        {
            Headline.Text = blocking.Count == 1
                ? "One of your game files is not right"
                : $"{blocking.Count} of your game files are not right";

            Explanation.Text =
                "These files are either missing or not the versions we published, so the game " +
                "would not work properly — most likely it would disconnect you shortly after " +
                "you log in. Repair downloads clean copies straight from our server.";

            RepairButton.Content = "Repair";
        }
        else
        {
            Headline.Text = "We cannot recognise this as a legitimate Uncapped client";

            Explanation.Text =
                "Your game folder contains files that are not part of any Uncapped release. " +
                "They are most likely left over from another private server. You can keep " +
                "playing, but they can cause missing textures, wrong models, odd item names " +
                "and crashes that look like realm bugs.\n\n" +
                "Repair moves them out of the way into Data\\_disabled, where the game stops " +
                "loading them and you can still get them back.";

            RepairButton.Content = "Repair";
        }

        var quarantined = foreign.Count(p => p.IsForeignArchive);
        var notes = new List<string>();

        if (blocking.Count > 0) notes.Add($"{blocking.Count} file(s) will be re-downloaded");
        if (quarantined > 0)    notes.Add($"{quarantined} file(s) will be moved to Data\\_disabled");

        // Named explicitly, because "Repair" on a game folder is exactly the kind of button
        // people expect to wipe their addons. It does not, and saying so is cheaper than
        // rebuilding someone's UI for them afterwards.
        notes.Add("your addons, settings and screenshots are not touched");

        Footnote.Text = string.Join(" · ", notes) + ".";
    }

    private static string Describe(long bytes) => bytes switch
    {
        <= 0 => "",
        < 1024 * 1024 => $"{bytes / 1024.0:0} KB",
        < 1024L * 1024 * 1024 => $"{bytes / (1024.0 * 1024):0} MB",
        _ => $"{bytes / (1024.0 * 1024 * 1024):0.0} GB",
    };

    private void OnRepair(object sender, RoutedEventArgs e)
    {
        RepairRequested = true;
        DialogResult = true;
        Close();
    }

    private void OnClose(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
