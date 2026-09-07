namespace Uncapped.Services;

/// <summary>The stages a normal launch goes through, in order.</summary>
public enum WorkStep
{
    Updates = 0,
    Files = 1,
    Client = 2,
    Checking = 3,
}

/// <summary>
/// Turns "what the launcher is doing right now" into a step number and a single honest
/// percentage.
///
/// ★★ WHY THIS IS NOT JUST A PROGRESS BAR
///
/// The launcher already reported progress, and it was actively misleading. Every phase drove
/// the same bar from 0 to 100 and then handed it to the next phase, which reset it to 0 — so a
/// launch showed the bar fill and empty five times, and the bar reaching the end meant nothing
/// at all. The status line underneath said things like "Checking your files (412/718)" with no
/// indication that four more passes were still to come, in a 300px column with character
/// ellipsis on, so the interesting half of a longer line was cut off.
///
/// What a player wants to know while they wait is which of a known number of things is
/// happening and how much is left overall. That needs one weighted scale, which is all this
/// is: each step owns a slice of 0..1 proportional to how long it really takes, and a step
/// reporting itself half done moves the bar half of its own slice — never past it.
///
/// ★ THE WEIGHTS ARE MEASURED, NOT GUESSED, AND THEY ARE ALLOWED TO BE WRONG.
///
/// They are wall-clock shares of a warm launch on a normal connection: the manifest fetch is a
/// single request, the payload sync is ~720 small files that mostly hash and do not download,
/// building the client is one 7.7 MB read and rewrite, and verifying dominates because it is
/// the pass that can be asked to hash gigabytes. A cold first run inverts that completely and
/// the bar will crawl through step 2 — which is the honest thing for it to do, because that IS
/// where the time is going. What must never happen is the bar going BACKWARDS, and the slice
/// arithmetic below is what guarantees it.
/// </summary>
public static class WorkPlan
{
    public sealed record StepInfo(WorkStep Step, string Headline, double Weight);

    private static readonly StepInfo[] All =
    {
        new(WorkStep.Updates,  "Checking for updates",     3),
        new(WorkStep.Files,    "Updating your files",     35),
        new(WorkStep.Client,   "Preparing the game",      12),
        new(WorkStep.Checking, "Checking your game files", 50),
    };

    public static int Count => All.Length;

    public static string Headline(WorkStep step) => All[(int)step].Headline;

    /// <summary>1-based, for "Step 2 of 4".</summary>
    public static int Number(WorkStep step) => (int)step + 1;

    /// <summary>
    /// Overall completion once <paramref name="step"/> is <paramref name="fraction"/> through.
    ///
    /// Clamped at both ends: a caller reporting 412 of 0 files, or a count that grows while
    /// the pass runs, must not push the bar past the end of its own slice and into the next
    /// step's territory.
    /// </summary>
    public static double Overall(WorkStep step, double fraction)
    {
        var total = All.Sum(s => s.Weight);
        var before = All.Where(s => s.Step < step).Sum(s => s.Weight);

        var clamped = double.IsFinite(fraction) ? Math.Clamp(fraction, 0, 1) : 0;
        return (before + All[(int)step].Weight * clamped) / total;
    }

    /// <summary>
    /// "412 of 718" — the count line under the headline.
    ///
    /// Returns an empty string for a zero total rather than "0 of 0", which reads as a stall.
    /// </summary>
    public static string Counted(int completed, int total) =>
        total <= 0 ? "" : $"{completed:N0} of {total:N0}";

    /// <summary>Bytes for a person, not for a log.</summary>
    public static string Bytes(long bytes) =>
        bytes >= 1024L * 1024 * 1024 ? $"{bytes / 1024.0 / 1024 / 1024:0.0} GB"
      : bytes >= 1024L * 1024        ? $"{bytes / 1024.0 / 1024:0.0} MB"
      : bytes >= 1024L               ? $"{bytes / 1024.0:0} KB"
                                     : $"{bytes} bytes";
}
