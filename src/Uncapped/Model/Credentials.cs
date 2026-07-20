using System.Text.Json;
using System.Text.Json.Serialization;

namespace Uncapped.Model;

/// <summary>
/// A remembered account name and password.
///
/// Stored in plain text, by decision. Two things follow from that, and both are deliberate:
///
/// - It lives in its own file rather than in state.json, so the state file can be shared for
///   debugging without handing over the password with it.
/// - The file carries a warning line, because the person most likely to stumble across it is
///   the player themselves.
///
/// The real risk here is not the game account: it is that people reuse passwords, so this
/// file may effectively hold the credentials to something that matters more. Worth saying out
/// loud to anyone who turns it on.
/// </summary>
public sealed class Credentials
{
    [JsonPropertyName("_warning")]
    public string Warning { get; set; } =
        "This file stores your realm password in plain text. Anything that can read your " +
        "files can read it. Do not reuse a password you care about.";

    [JsonPropertyName("accountName")] public string AccountName { get; set; } = "";
    [JsonPropertyName("password")] public string Password { get; set; } = "";

    [JsonIgnore] public bool HasPassword => !string.IsNullOrEmpty(Password);
    [JsonIgnore] public bool HasAccountName => !string.IsNullOrWhiteSpace(AccountName);

    private static string Path => System.IO.Path.Combine(AppPaths.DataDir, "credentials.json");

    private static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static Credentials Load()
    {
        try
        {
            if (File.Exists(Path))
                return JsonSerializer.Deserialize<Credentials>(File.ReadAllText(Path)) ?? new Credentials();
        }
        catch { /* unreadable or corrupt: behave as if nothing was saved */ }

        return new Credentials();
    }

    public void Save()
    {
        Directory.CreateDirectory(AppPaths.DataDir);
        File.WriteAllText(Path, JsonSerializer.Serialize(this, Options));
    }

    public static void Delete()
    {
        try { if (File.Exists(Path)) File.Delete(Path); }
        catch { /* nothing sensible to do */ }
    }
}
