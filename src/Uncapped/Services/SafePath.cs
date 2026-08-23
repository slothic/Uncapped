namespace Uncapped.Services;

/// <summary>
/// The containment test both extraction loops depend on.
///
/// ★★ IT LIVES HERE BECAUSE THERE ARE TWO OF THEM, AND THERE WERE TWO COPIES OF THE BUG.
///
/// Until 2026-08-22 <see cref="SyncService"/> and <see cref="ClientAcquirer"/> each carried a
/// hand-written zip-slip guard -- `destination.StartsWith(Path.GetFullPath(targetDir))` -- and
/// the same hole in it. Path.GetFullPath does not leave a trailing separator, so that test is a
/// STRING prefix rather than a PATH one, and a sibling folder whose name merely begins with the
/// target's name satisfies it. With the target `…\WoW335`, anything resolving into
/// `…\WoW335-anything\` was "inside" as far as that check was concerned, and got written.
///
/// It never reached arbitrary locations -- rooted entries and real upward traversal were and are
/// refused -- but a write landing outside the install root escapes EVERY safety net we own:
/// IntegrityVerifier, PruneOrphans and EnsureBaseFilesAsync are all scoped to under that root, so
/// such a file is never hashed, never flagged foreign, never repaired and never removed. It
/// survives a repair, a reinstall and every future release.
///
/// ⚠ Do not re-inline this. A guard that lives in two places is a guard that gets fixed in one.
/// </summary>
public static class SafePath
{
    /// <summary>
    /// True when <paramref name="candidate"/> really is somewhere under <paramref name="root"/>.
    ///
    /// Both sides are canonicalised first, so `..`, `.` and mixed slashes are already resolved,
    /// and the root is compared WITH its trailing separator -- which is the entire point:
    /// `X\` is a prefix of `X\sub\file` and is NOT a prefix of `X-evil\file`.
    ///
    /// OrdinalIgnoreCase because this is Windows-only and the filesystem is case-insensitive; an
    /// ordinal-sensitive test would wave through anything that varied the casing of the root.
    ///
    /// The root itself is deliberately NOT "inside" itself: every caller is placing a file under
    /// a directory, and a zip entry resolving onto the directory it is being unpacked into is a
    /// malformed archive, not a legitimate one.
    /// </summary>
    public static bool IsInside(string root, string candidate)
    {
        var full = Path.GetFullPath(root);

        // A drive root ("C:\") already carries one, and appending a second would match nothing.
        if (!full.EndsWith(Path.DirectorySeparatorChar))
            full += Path.DirectorySeparatorChar;

        return Path.GetFullPath(candidate).StartsWith(full, StringComparison.OrdinalIgnoreCase);
    }
}
