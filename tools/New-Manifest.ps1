<#
.SYNOPSIS
  Generates manifest.json by hashing everything in the payload tree.

.DESCRIPTION
  Run after Build-Payload.ps1. Publishing an update is then:
      .\Build-Payload.ps1 -Clean
      .\New-Manifest.ps1 -BaseUrl https://raw.githubusercontent.com/OWNER/REPO/main/payload
      git add -A; git commit -m "addons: ..."; git push

  Existing news entries in the current manifest.json are preserved, so regenerating does not
  wipe the changelog.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseUrl,
    [string]$PayloadDir      = 'C:\Wotlk\Launcher\payload',
    [string]$OutFile         = 'C:\Wotlk\Launcher\manifest.json',
    [string]$RealmAddress    = '91.100.105.22',
    [string]$RealmName       = 'Uncapped',
    [int]   $AuthPort        = 3724,
    [string]$RegisterUrl     = 'http://91.100.105.22:8080',
    # Discord webhook that client crash dumps get posted to. Kept in the manifest, not the
    # binary, so it can be rotated without cutting a release - which matters because a
    # webhook shipped in a public client can be extracted by anyone who looks.
    # Empty disables crash reporting entirely.
    [string]$CrashReportWebhook = '',
    # Rename the client executable and delete Repair.exe, so players cannot start an unsynced
    # client by double-clicking it.
    [bool]  $HardenClient    = $true,
    # Addons to switch off on clients that already have them, for ones we shipped and then
    # pulled. Keep in step with $temporarilyDisabled in Build-Payload.ps1.
    [string[]]$ForceDisableAddOns = @('QuestHelper'),
    [string]$LauncherVersion = '1.0.0',
    [string]$LauncherUrl     = '',
    # Leave empty to have it computed from -LauncherExe, if that file exists.
    [string]$LauncherSha256  = '',
    [string]$LauncherExe     = 'C:\Wotlk\Launcher\src\Uncapped\bin\Release\net9.0-windows\win-x64\publish\Uncapped.exe',
    # Files served from somewhere other than this repo (the WDM MPQ patches, which live in
    # Trimitor's releases). Downloaded once to a cache purely so we can hash them.
    [string]$ExternalFiles = 'C:\Wotlk\Launcher\tools\external-files.json',
    [string]$ExternalCache = 'C:\Wotlk\Launcher\.external-cache',
    [string]$Magnet          = 'magnet:?xt=urn:btih:2ba2833baf733ce0a16040d43ed09491f2bf2ab2&dn=ChromieCraft_3.3.5a.zip&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80%2Fannounce&tr=http%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.uw0.xyz%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.zerobytes.xyz%3A1337%2Fannounce',
    [string]$DirectDownloadUrl = $null
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PayloadDir)) { throw "Payload not found at $PayloadDir. Run Build-Payload.ps1 first." }

$BaseUrl = $BaseUrl.TrimEnd('/')
$payloadRoot = (Resolve-Path $PayloadDir).Path

$files = foreach ($f in Get-ChildItem $payloadRoot -Recurse -File) {
    $relative = $f.FullName.Substring($payloadRoot.Length + 1) -replace '\\', '/'
    $hash = (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower()

    # Each segment is escaped separately so that '/' stays a separator but spaces and '!'
    # (as in the !Astrolabe addon) survive the trip through raw.githubusercontent.com.
    $encoded = ($relative -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'

    [ordered]@{
        path   = $relative
        url    = "$BaseUrl/$encoded"
        sha256 = $hash
        size   = $f.Length
    }
}

# --- Externally hosted files -------------------------------------------------------------
# These are not in payload\ and are never committed here. We download each once to hash it,
# then publish the upstream URL. Players fetch them straight from the source.
if (Test-Path $ExternalFiles) {
    $external = Get-Content $ExternalFiles -Raw | ConvertFrom-Json
    if ($external) {
        New-Item -ItemType Directory -Force $ExternalCache | Out-Null
        $wc = New-Object Net.WebClient
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Write-Host "`nExternally hosted files:" -ForegroundColor Cyan
        foreach ($e in $external) {
            if (-not $e.path -or -not $e.url) { continue }

            $cached = Join-Path $ExternalCache ($e.path -replace '[\\/]', '_')

            # Re-download only when absent. These are pinned to release tags, so the bytes
            # behind a given URL do not change; delete the cache to force a refresh.
            if (-not (Test-Path $cached)) {
                Write-Host "  downloading $($e.path)..." -ForegroundColor DarkGray
                $wc.DownloadFile($e.url, $cached)
            }

            $item = Get-Item $cached
            if ($item.Length -eq 0) { throw "External file $($e.path) downloaded as 0 bytes." }

            $files += [ordered]@{
                path   = $e.path
                url    = $e.url
                sha256 = (Get-FileHash $cached -Algorithm SHA256).Hash.ToLower()
                size   = $item.Length
            }
            Write-Host ("  + {0,-32} {1,6} MB" -f $e.path, [math]::Round($item.Length / 1MB, 1)) -ForegroundColor Green
        }
    }
}

# Resolve the launcher hash. Self-update verifies the downloaded exe against this before
# swapping it in, so publishing a URL without a hash would skip that check entirely.
$launcherHash = $LauncherSha256
if (-not $launcherHash -and $LauncherUrl -and (Test-Path $LauncherExe)) {
    $launcherHash = (Get-FileHash $LauncherExe -Algorithm SHA256).Hash.ToLower()
    Write-Host "  launcher hash from $LauncherExe" -ForegroundColor DarkGray
}
if ($LauncherUrl -and -not $launcherHash) {
    Write-Warning "launcherUrl is set but no hash could be determined - self-update will not verify the download."
}

# Preserve any news already written by hand.
$news = @()
if (Test-Path $OutFile) {
    try {
        $existing = Get-Content $OutFile -Raw | ConvertFrom-Json
        if ($existing.news) { $news = $existing.news }
    } catch { Write-Warning "Could not read existing manifest for news; starting empty." }
}

# Checked separately: the .zip lands on the %LOCALAPPDATA% drive, the extracted game on the
# install drive, and those are often not the same disk. Both figures carry a little headroom.
$archiveBytes   = 18GB
$installedBytes = 18GB

# Resolve these BEFORE the hashtable literal. Windows PowerShell 5.1 mis-parses an `if`
# expression used as a value inside a multi-line hashtable literal: the entire literal
# evaluates to $null, ConvertTo-Json happily serialises that to nothing, and the script goes
# on to report success while writing a 0-byte manifest. Keep statements out of the literal.
$launcherUrlValue = $null
if ($LauncherUrl) { $launcherUrlValue = $LauncherUrl }

$launcherHashValue = $null
if ($launcherHash) { $launcherHashValue = $launcherHash }

$crashWebhookValue = $null
if ($CrashReportWebhook) { $crashWebhookValue = $CrashReportWebhook }

$manifest = [ordered]@{
    manifestVersion = 1
    launcherVersion = $LauncherVersion
    launcherUrl     = $launcherUrlValue
    launcherSha256  = $launcherHashValue
    realm = [ordered]@{
        name        = $RealmName
        address     = $RealmAddress
        authPort    = $AuthPort
        registerUrl = $RegisterUrl
    }
    client = [ordered]@{
        magnet            = $Magnet
        directDownloadUrl = $DirectDownloadUrl
        # The torrent's payload is this single zip.
        archiveName       = 'ChromieCraft_3.3.5a.zip'
        archiveBytes      = $archiveBytes
        installedBytes    = $installedBytes
    }
    crashReportWebhook = $crashWebhookValue
    hardenClient       = $HardenClient

    news  = $news
    files = @($files)

    # Force-ticked in AddOns.txt on every launch. StatFeed is the reason the launcher exists;
    # without it players see no stat-gain messages at all.
    forceEnableAddOns = @('StatFeed', 'ReagentBankCraft')

    # Switched off in AddOns.txt on clients that already have them. Needed because dropping
    # an addon from the payload does not uninstall it - the launcher never deletes
    # third-party addons, so a broken one would keep loading and keep throwing errors.
    # Keep in step with $temporarilyDisabled in Build-Payload.ps1.
    forceDisableAddOns = @($ForceDisableAddOns)

    # Only paths under here are pruned when they leave the manifest. Third-party addons are
    # install-only and never deleted - we do not remove addons we did not write.
    ownedPaths = @(
        'Interface/AddOns/StatFeed',
        'Interface/AddOns/ReagentBankCraft'
    )
}

$json = $manifest | ConvertTo-Json -Depth 8

# Never write a manifest we cannot vouch for. A silently empty or truncated file here becomes
# a broken launcher for every player, and the failure is invisible at generation time.
if (-not $json) { throw "Serialisation produced no output - refusing to write $OutFile." }

# UTF-8 *without* BOM. Windows PowerShell's `-Encoding utf8` emits a BOM, which several JSON
# parsers choke on. .NET's HttpClient happens to strip it, so the launcher copes either way,
# but there is no reason to ship a manifest that only some readers can parse.
[IO.File]::WriteAllText($OutFile, $json, (New-Object Text.UTF8Encoding($false)))

# Read it back and parse it. Cheap, and it is the only check that proves what landed on disk
# is what the launcher will actually be able to consume.
$written = Get-Content $OutFile -Raw
$check = $null
try { $check = $written | ConvertFrom-Json } catch { throw "Wrote $OutFile but it does not parse as JSON: $_" }
if (-not $check.files -or $check.files.Count -ne $files.Count) {
    throw "Wrote $OutFile but it contains $($check.files.Count) file entries, expected $($files.Count)."
}

# $files holds ordered hashtables, whose keys are not properties Measure-Object can see.
$totalMb = [math]::Round((($files | ForEach-Object { $_.size } | Measure-Object -Sum).Sum) / 1MB, 2)
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "  $($files.Count) files, $totalMb MB"
Write-Host "  base url: $BaseUrl"
if (-not $LauncherUrl) {
    Write-Host "  note: launcherUrl empty -> self-update disabled until you set it." -ForegroundColor Yellow
}
