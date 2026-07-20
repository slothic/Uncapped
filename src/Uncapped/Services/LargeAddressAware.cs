namespace Uncapped.Services;

/// <summary>
/// Sets IMAGE_FILE_LARGE_ADDRESS_AWARE on the game client.
///
/// The 3.3.5a client is 32-bit and ships without this flag, so Windows caps it at a 2 GB
/// address space. Setting one bit in the PE header lifts that to 4 GB on 64-bit Windows,
/// which buys headroom for a large addon set and high view distance.
///
/// This edits two bytes of the header and the checksum. No code is touched, so it does not
/// change what the client does — only how much address space the loader grants it. It is
/// idempotent and reversible: clearing the bit restores the original behaviour.
///
/// Worth being clear about what it is not: this does not fix crashes caused by client bugs.
/// It only helps when the client is genuinely running out of address space.
/// </summary>
public static class LargeAddressAware
{
    private const ushort LargeAddressAwareFlag = 0x0020;
    private const int PeSignatureOffsetLocation = 0x3C;
    private const uint PeSignature = 0x00004550; // "PE\0\0"
    private const ushort Machine32BitX86 = 0x014C;

    public sealed record Result(bool Changed, string Detail);

    public static Result Apply(string installPath)
    {
        var exe = ClientExecutable.Find(installPath);
        if (exe is null) return new Result(false, "no game executable found");

        try
        {
            using var stream = new FileStream(exe, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            using var reader = new BinaryReader(stream, System.Text.Encoding.UTF8, leaveOpen: true);
            using var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, leaveOpen: true);

            stream.Position = PeSignatureOffsetLocation;
            var peOffset = reader.ReadInt32();
            if (peOffset <= 0 || peOffset > stream.Length - 24)
                return new Result(false, "not a PE file");

            stream.Position = peOffset;
            if (reader.ReadUInt32() != PeSignature) return new Result(false, "PE signature missing");

            // COFF header follows the signature: Machine, NumberOfSections, ... then
            // Characteristics at offset 18.
            stream.Position = peOffset + 4;
            var machine = reader.ReadUInt16();
            if (machine != Machine32BitX86)
                return new Result(false, $"not 32-bit x86 (machine 0x{machine:X4}) - flag is pointless");

            var characteristicsPosition = peOffset + 4 + 18;
            stream.Position = characteristicsPosition;
            var characteristics = reader.ReadUInt16();

            if ((characteristics & LargeAddressAwareFlag) != 0)
                return new Result(false, "already large address aware");

            stream.Position = characteristicsPosition;
            writer.Write((ushort)(characteristics | LargeAddressAwareFlag));
            writer.Flush();

            // The optional header's CheckSum sits 64 bytes past the PE signature. Windows only
            // validates it for drivers and a few system images, so a stale value would almost
            // certainly go unnoticed - but leaving a knowingly wrong checksum in a file we
            // just edited is the kind of thing that makes a later problem hard to diagnose.
            RewriteChecksum(stream, peOffset + 4 + 20 + 64);

            return new Result(true, "enabled (2 GB -> 4 GB address space)");
        }
        catch (Exception ex)
        {
            return new Result(false, $"could not patch: {ex.Message}");
        }
    }

    /// <summary>
    /// Recomputes the PE checksum the way CheckSumMappedFile does: a folded 16-bit sum over
    /// the whole file with the checksum field itself treated as zero, plus the file length.
    /// </summary>
    private static void RewriteChecksum(FileStream stream, long checksumPosition)
    {
        stream.Position = 0;
        var bytes = new byte[stream.Length];
        var read = 0;
        while (read < bytes.Length)
        {
            var n = stream.Read(bytes, read, bytes.Length - read);
            if (n == 0) break;
            read += n;
        }

        // Zero the existing checksum for the calculation.
        for (var i = 0; i < 4; i++) bytes[checksumPosition + i] = 0;

        ulong sum = 0;
        for (long i = 0; i + 1 < bytes.Length; i += 2)
        {
            sum += (ulong)(bytes[i] | (bytes[i + 1] << 8));
            if (sum > 0xFFFFFFFFUL) sum = (sum & 0xFFFFFFFFUL) + (sum >> 32);
        }

        // A trailing odd byte still contributes.
        if ((bytes.Length & 1) != 0) sum += bytes[^1];

        sum = (sum & 0xFFFF) + (sum >> 16);
        sum += sum >> 16;
        sum &= 0xFFFF;
        sum += (ulong)bytes.Length;

        stream.Position = checksumPosition;
        stream.Write(BitConverter.GetBytes((uint)sum), 0, 4);
        stream.Flush();
    }

    /// <summary>Reads the current flag without modifying anything.</summary>
    public static bool IsEnabled(string installPath)
    {
        var exe = ClientExecutable.Find(installPath);
        if (exe is null) return false;

        try
        {
            using var stream = new FileStream(exe, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var reader = new BinaryReader(stream);

            stream.Position = PeSignatureOffsetLocation;
            var peOffset = reader.ReadInt32();
            if (peOffset <= 0 || peOffset > stream.Length - 24) return false;

            stream.Position = peOffset;
            if (reader.ReadUInt32() != PeSignature) return false;

            stream.Position = peOffset + 4 + 18;
            return (reader.ReadUInt16() & LargeAddressAwareFlag) != 0;
        }
        catch { return false; }
    }
}
