using System.Security.Cryptography;
using Uncapped.Model;

namespace Uncapped.Services;

/// <summary>
/// Builds the runnable game client on the player's machine, from a pristine base file plus a
/// list of byte patches carried in the manifest.
///
/// WHY THE CLIENT IS DERIVED RATHER THAN DOWNLOADED
///
/// Every client-side hex patch used to be baked into UncappedClient.dat offline and published
/// as a whole file, so a handful of bytes cost every player a 7.7 MB re-download. Patching the
/// installed client in place instead is not an option either, and the reason is worth stating
/// because it is not obvious: <see cref="SyncService.IsCurrentAsync"/> re-hashes every manifest
/// file against its pin on EVERY launch, so a launcher that edited the client would find it
/// mismatched a moment later and re-download it, forever.
///
/// Splitting the two resolves it. The BASE is a manifest file like any other — pinned, synced,
/// verified, never touched after it lands. The runnable client is DERIVED from it here and is
/// not a manifest entry at all, so the sync has no opinion about it. A new patch is then a
/// manifest edit and zero bytes of client download.
///
/// WHAT MAKES IT SAFE
///
/// Three checks, and the work is thrown away if any of them fails:
///
///   1. the base must hash to <see cref="ClientPatchSpec.BaseSha256"/> before a byte is read;
///   2. every patch states the bytes it EXPECTS to find, and a mismatch aborts the whole
///      build. This is what makes a build-locked patch safe to apply on a machine we cannot
///      see — the mouse-cam fix is a set of hardcoded displacements correct for exactly one
///      build, and it cannot be written onto a different one;
///   3. the finished image must hash to <see cref="ClientPatchSpec.ResultSha256"/>, which is
///      computed by Build-ClientPatch.py from the same inputs. A patch list that is wrong in
///      any way produces a file that never reaches the player.
///
/// The existing client is only ever replaced by a file that passed all three. Nothing is
/// edited in place, so a failed build leaves the player exactly as they were rather than
/// halfway to somewhere — which is the difference between "try again" and "reinstall".
///
/// It carries no PE knowledge whatsoever, deliberately. Even the PE checksum arrives as an
/// ordinary byte patch that the build tool computed, so there is no second implementation of
/// anything here to drift out of step with the toolchain.
/// </summary>
public static class ClientPatcher
{
    public enum Outcome
    {
        /// <summary>No clientPatch block. Older manifests are not broken and must not say so.</summary>
        NotConfigured,

        /// <summary>The client on disk already hashes to the expected result.</summary>
        AlreadyCurrent,

        /// <summary>A fresh client was built and installed.</summary>
        Rebuilt,

        BaseMissing,
        BaseMismatch,
        PatchRefused,
        ResultMismatch,
        WriteFailed,
    }

    public sealed record Result(Outcome Outcome, string Detail)
    {
        /// <summary>
        /// True when the player must not be let through. Note that AlreadyCurrent and
        /// NotConfigured are both fine, and that a failure here is genuinely blocking: the
        /// alternative is launching a client we could not verify, which is the one thing this
        /// whole mechanism exists to avoid.
        /// </summary>
        public bool Blocks => Outcome is not (Outcome.NotConfigured or Outcome.AlreadyCurrent or Outcome.Rebuilt);
    }

    /// <summary>
    /// Suffix chosen so the partial file matches the baseline's tolerated "*.tmp" pattern, and
    /// deliberately NOT ".uncapped-tmp" — that belongs to ResilientDownload's resumable
    /// transfers, where a leftover is picked up as a byte-range to continue from. A file this
    /// code abandoned must never be mistaken for a half-finished download.
    /// </summary>
    private const string TempSuffix = ".patching.tmp";

    public static async Task<Result> ApplyAsync(string installPath, Manifest manifest, CancellationToken ct)
    {
        var spec = manifest.ClientPatch;
        if (spec is null || !spec.IsUsable)
            return new Result(Outcome.NotConfigured, "manifest carries no client patch");

        var output = Path.Combine(installPath, spec.OutputPath);
        var basePath = Path.Combine(installPath, spec.BasePath);

        // The common case by a wide margin: nothing to do, and the player pays one hash for it.
        if (File.Exists(output) && await HashFileAsync(output, ct) == Normalise(spec.ResultSha256))
            return new Result(Outcome.AlreadyCurrent, "client is already fully patched");

        if (!File.Exists(basePath))
            return new Result(Outcome.BaseMissing,
                $"{spec.BasePath} is not in the game folder, so the client cannot be built");

        var image = await File.ReadAllBytesAsync(basePath, ct);

        var baseHash = Convert.ToHexString(SHA256.HashData(image)).ToLowerInvariant();
        if (baseHash != Normalise(spec.BaseSha256))
            return new Result(Outcome.BaseMismatch,
                $"{spec.BasePath} is not the file we published (got {baseHash[..12]}…, " +
                $"expected {Normalise(spec.BaseSha256)[..12]}…)");

        foreach (var patch in spec.Patches)
        {
            if (Refuse(image, patch) is { } refusal)
                return new Result(Outcome.PatchRefused, refusal);
        }

        var resultHash = Convert.ToHexString(SHA256.HashData(image)).ToLowerInvariant();
        if (resultHash != Normalise(spec.ResultSha256))
            return new Result(Outcome.ResultMismatch,
                $"the patched client hashed to {resultHash[..12]}… but the manifest expects " +
                $"{Normalise(spec.ResultSha256)[..12]}…");

        var temp = output + TempSuffix;
        try
        {
            // A leftover from an interrupted run is worthless — it is not resumable and its
            // contents are unknown. Always start from nothing.
            if (File.Exists(temp)) File.Delete(temp);

            await File.WriteAllBytesAsync(temp, image, ct);
            File.Move(temp, output, overwrite: true);
        }
        catch (Exception ex)
        {
            try { if (File.Exists(temp)) File.Delete(temp); } catch { /* best effort */ }

            // Much the likeliest cause is the game already running and holding the file open.
            return new Result(Outcome.WriteFailed, $"could not replace {spec.OutputPath}: {ex.Message}");
        }

        return new Result(Outcome.Rebuilt,
            $"built from {spec.BasePath} with {spec.Patches.Count} patch(es)");
    }

    /// <summary>
    /// Applies one patch, or returns why it will not. Writes into <paramref name="image"/> only
    /// when every check passes; a caller that sees a refusal must discard the whole image,
    /// since earlier patches in the list have already been written to it.
    /// </summary>
    private static string? Refuse(byte[] image, ClientBytePatch patch)
    {
        var id = string.IsNullOrWhiteSpace(patch.Id) ? "(unnamed)" : patch.Id;

        if (!TryParseOffset(patch.Offset, out var offset))
            return $"{id}: '{patch.Offset}' is not a valid offset";

        byte[] expect, write;
        try
        {
            expect = Convert.FromHexString(patch.Expect);
            write = Convert.FromHexString(patch.Write);
        }
        catch (FormatException)
        {
            return $"{id}: expect/write are not valid hex";
        }

        // Length-preserving is not a stylistic preference. A patch that changed the size would
        // move every following offset and invalidate the rest of the list.
        if (expect.Length != write.Length)
            return $"{id}: expect is {expect.Length} bytes but write is {write.Length}";

        if (expect.Length == 0)
            return $"{id}: patch is empty";

        if (offset < 0 || offset + expect.Length > image.Length)
            return $"{id}: offset 0x{offset:X} runs past the end of the base file";

        var found = image.AsSpan(offset, expect.Length);
        if (!found.SequenceEqual(expect))
            return $"{id}: expected {Convert.ToHexString(expect)} at 0x{offset:X} " +
                   $"but found {Convert.ToHexString(found)}";

        write.CopyTo(image.AsSpan(offset));
        return null;
    }

    private static bool TryParseOffset(string? text, out int offset)
    {
        offset = 0;
        if (string.IsNullOrWhiteSpace(text)) return false;

        var trimmed = text.Trim();
        var hex = trimmed.StartsWith("0x", StringComparison.OrdinalIgnoreCase);

        return hex
            ? int.TryParse(trimmed.AsSpan(2), System.Globalization.NumberStyles.HexNumber, null, out offset)
            : int.TryParse(trimmed, out offset);
    }

    private static string Normalise(string? sha) => (sha ?? "").Trim().ToLowerInvariant();

    private static async Task<string> HashFileAsync(string path, CancellationToken ct)
    {
        await using var stream = new FileStream(
            path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, useAsync: true);

        return Convert.ToHexString(await SHA256.HashDataAsync(stream, ct)).ToLowerInvariant();
    }
}
