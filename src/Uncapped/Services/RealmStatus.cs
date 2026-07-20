using System.Net.Sockets;

namespace Uncapped.Services;

/// <summary>
/// A TCP connect to the auth port. That only proves authserver is accepting connections —
/// it says nothing about worldserver — so the UI reports it as "reachable", not "online with
/// N players". Reading real population would need a server-side endpoint that does not exist
/// yet.
/// </summary>
public static class RealmStatus
{
    public static async Task<bool> IsReachableAsync(string host, int port, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(host)) return false;

        try
        {
            using var client = new TcpClient();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(TimeSpan.FromSeconds(4));

            await client.ConnectAsync(host, port, timeout.Token);
            return client.Connected;
        }
        catch { return false; }
    }
}
