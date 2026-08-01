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
    [string]$RealmAddress    = '152.53.115.249',
    [string]$RealmName       = 'Uncapped',
    [int]   $AuthPort        = 3724,
    [string]$RegisterUrl     = 'http://152.53.115.249:8080',
    # Served straight from the registration site's document root, which is a live bind mount
    # (./webregistration:/var/www/html). Editing that file updates the news for everyone with
    # no rebuild, no restart and no release. Empty falls back to the manifest's news array.
    [string]$NewsUrl         = 'http://152.53.115.249:8080/news.json',
    # Discord webhook that client crash dumps get posted to. Kept in the manifest, not the
    # binary, so it can be rotated without cutting a release - which matters because a
    # webhook shipped in a public client can be extracted by anyone who looks.
    # Empty disables crash reporting entirely.
    [string]$CrashReportWebhook = '',
    # Rename the client executable and delete Repair.exe, so players cannot start an unsynced
    # client by double-clicking it.
    [bool]  $HardenClient    = $true,
    # Sets IMAGE_FILE_LARGE_ADDRESS_AWARE on the client: two bytes of the PE header, lifting
    # its address space from 2 GB to 4 GB on 64-bit Windows. No code is modified.
    [bool]  $LargeAddressAware = $true,
    # Addons to switch off on clients that already have them, for ones we shipped and then
    # pulled. Keep in step with $temporarilyDisabled, $retired and $licenceExcluded in
    # Build-Payload.ps1 - anything excluded from the payload that players may already have
    # installed belongs here, or it keeps loading forever on their client.
    [string[]]$ForceDisableAddOns = @('QuestHelper', '!Astrolabe', 'AckisRecipeList', 'Recount'),
    # Empty by default: a regen that omits these inherits whatever the current manifest
    # already advertises (see below) instead of resetting the pointer. Pass explicitly to
    # publish a new launcher release.
    [string]$LauncherVersion = '',
    [string]$LauncherUrl     = '',
    # Leave empty to have it computed from -LauncherExe, if that file exists.
    [string]$LauncherSha256  = '',
    [string]$LauncherExe     = 'C:\Wotlk\Launcher\src\Uncapped\bin\Release\net9.0-windows\win-x64\publish\Uncapped.exe',
    # Files served from somewhere other than this repo (the WDM MPQ patches, which live in
    # Trimitor's releases). Downloaded once to a cache purely so we can hash them.
    [string]$ExternalFiles = 'C:\Wotlk\Launcher\tools\external-files.json',
    # Zips fetched from someone else's host and unpacked into the install, for addons we are
    # not entitled to redistribute. Hashed here so the launcher can pin them.
    [string]$Archives      = 'C:\Wotlk\Launcher\tools\archives.json',
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

# --- Externally hosted archives ----------------------------------------------------------
# Zips we do not redistribute: the launcher downloads them from the author's own host and
# unpacks them into the install. Downloaded once here purely to hash and size them, so the
# launcher can verify what it gets and skip re-extracting an archive that has not changed.
$archiveEntries = @()
if (Test-Path $Archives) {
    $archiveDefs = Get-Content $Archives -Raw | ConvertFrom-Json
    if ($archiveDefs) {
        New-Item -ItemType Directory -Force $ExternalCache | Out-Null
        $awc = New-Object Net.WebClient
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Write-Host "`nExternally hosted archives (downloaded by the launcher, not shipped):" -ForegroundColor Cyan
        foreach ($a in $archiveDefs) {
            if (-not $a.name -or -not $a.url -or -not $a.extractTo) { continue }

            $cached = Join-Path $ExternalCache ("archive_" + ($a.name -replace '[\\/:*?"<>|]', '_') + '.zip')

            # Re-download only when absent. These are pinned to a specific upstream file id,
            # so the bytes behind a given URL do not change; delete the cache to force a refresh.
            if (-not (Test-Path $cached)) {
                Write-Host "  downloading $($a.name)..." -ForegroundColor DarkGray
                $awc.DownloadFile($a.url, $cached)
            }

            $item = Get-Item $cached
            if ($item.Length -eq 0) { throw "Archive $($a.name) downloaded as 0 bytes." }

            # Cheap sanity check: a 403/interstitial HTML page saved to disk is still a file,
            # and would otherwise be published as a perfectly valid hash of the wrong thing.
            $sig = [IO.File]::ReadAllBytes($cached)[0..1]
            if ($sig[0] -ne 0x50 -or $sig[1] -ne 0x4B) {
                throw "Archive $($a.name) is not a zip (first bytes $($sig[0]),$($sig[1])). The host probably served an error page."
            }

            $entry = [ordered]@{
                name      = $a.name
                url       = $a.url
                sha256    = (Get-FileHash $cached -Algorithm SHA256).Hash.ToLower()
                size      = $item.Length
                extractTo = $a.extractTo
            }
            if ($a.verifyPath) { $entry.verifyPath = $a.verifyPath }
            if ($a.label)      { $entry.label      = $a.label }

            $archiveEntries += $entry
            Write-Host ("  + {0,-24} {1,8} KB  -> {2}" -f $a.name, [math]::Round($item.Length / 1KB, 1), $a.extractTo) -ForegroundColor Green
        }
    }
}

# When a routine regen omits the launcher args, keep whatever the current manifest already
# advertises rather than falling back to the defaults. A publish that forgets -LauncherVersion
# used to silently downgrade every client's self-update pointer (e.g. 1.4.0 -> 1.0.0).
#
# The HASH is not carried over the same way. A stale sha is worse than no sha: paired with a
# NEW url it points every client at a download it is then guaranteed to reject, so self-update
# fails for everyone instead of merely going unverified. Inheriting is therefore allowed only
# while the version and url are ALSO inherited -- the moment a release names a new one, the
# hash is recomputed from the exe below. (v1.7.0 caught this: -LauncherVersion and
# -LauncherUrl were passed, -LauncherSha256 was not, and the manifest went out advertising
# 1.6.0's hash against the 1.7.0 url.)
$launcherRelease = [bool]$LauncherVersion -or [bool]$LauncherUrl

if ((-not $LauncherVersion -or -not $LauncherUrl -or -not $LauncherSha256) -and (Test-Path $OutFile)) {
    try {
        $prevManifest = Get-Content $OutFile -Raw | ConvertFrom-Json
        if (-not $LauncherVersion -and $prevManifest.launcherVersion) { $LauncherVersion = $prevManifest.launcherVersion }
        if (-not $LauncherUrl     -and $prevManifest.launcherUrl)     { $LauncherUrl     = $prevManifest.launcherUrl }
        if (-not $LauncherSha256 -and -not $launcherRelease -and $prevManifest.launcherSha256) {
            $LauncherSha256 = $prevManifest.launcherSha256
        }
    } catch { Write-Warning "Could not read existing manifest to preserve launcher fields." }
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

$newsUrlValue = $null
if ($NewsUrl) { $newsUrlValue = $NewsUrl }

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
    largeAddressAware  = $LargeAddressAware

    newsUrl = $newsUrlValue
    news    = $news
    files   = @($files)

    # Zips the launcher fetches from their author's own host and unpacks. Not in files[] and
    # not in payload\: we do not redistribute these. See tools\archives.json.
    archives = @($archiveEntries)

    # Force-ticked in AddOns.txt on every launch. StatFeed is the reason the launcher exists;
    # without it players see no stat-gain messages at all.
    forceEnableAddOns = @('StatFeed', 'ReagentBankCraft', 'UncappedMythic', 'UncappedRewards', 'UncappedAlerts', 'UncappedVersion', 'UncappedGCD', 'UncappedOptions', 'UncappedVault', 'UncappedTransmog', 'UncappedForge', 'UncappedChat', 'UncappedQuests')

    # Switched off in AddOns.txt on clients that already have them. Needed because dropping
    # an addon from the payload does not uninstall it - the launcher never deletes
    # third-party addons, so a broken one would keep loading and keep throwing errors.
    # Keep in step with $temporarilyDisabled in Build-Payload.ps1.
    forceDisableAddOns = @($ForceDisableAddOns)

    # Only paths under here are pruned when they leave the manifest. Third-party addons are
    # install-only and never deleted - we do not remove addons we did not write.
    #
    # Data/enUS is owned because the custom server patches there (patch-enUS-Q/M/N/Z/...) are
    # OURS -- server-authored content, not third-party addons. Listing it lets a patch we pull
    # from the manifest be cleaned off players' clients. Prune only ever touches files this
    # launcher itself placed and recorded, so the base client's own patch-enUS/-2/-3 are never
    # affected. This is what claws back the retired camel test patch (patch-enUS-Y).
    ownedPaths = @(
        'Data/enUS',
        'Interface/AddOns/StatFeed',
        'Interface/AddOns/ReagentBankCraft',
        'Interface/AddOns/UncappedAlerts',
        'Interface/AddOns/UncappedRewards',
        'Interface/AddOns/UncappedMythic',
        'Interface/AddOns/UncappedVersion',
        'Interface/AddOns/UncappedGCD',
        'Interface/AddOns/UncappedHotzones',
        'Interface/AddOns/Uncapped64bitUI',
        'Interface/AddOns/UncappedOptions',
        'Interface/AddOns/UncappedVault',
        'Interface/AddOns/UncappedTransmog',
        'Interface/AddOns/UncappedForge',
        # These three were shipping WITHOUT being listed here, which meant they could
        # never be pruned or renamed -- the list had drifted behind the payload.
        'Interface/AddOns/UncappedScrolls',
        'Interface/AddOns/UncappedItemCustomize',
        'Interface/AddOns/UncappedPanel',
        'Interface/AddOns/UncappedAnima',
        'Interface/AddOns/UncappedChat',
        'Interface/AddOns/UncappedQuests',
        # devUncapped64 was renamed to Uncapped64bitUI. It has to stay listed so the
        # old folder is actually deleted from players' clients -- otherwise both copies
        # load side by side and every overlay, filter and hook runs twice.
        'Interface/AddOns/devUncapped64',
        # UncappedTempo was renamed to UncappedAnima one release after it shipped, so
        # the same rule applies: listed purely so the old folder is removed. Leaving it
        # behind would register /tempo a second time and build a duplicate window.
        'Interface/AddOns/UncappedTempo'
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
# Same reasoning as the files check above: an archive that silently failed to serialise would
# publish a manifest that simply stops shipping the addon, with nothing to notice at generation
# time. (The @() wrapper on the property is what keeps a single entry a JSON array rather than
# a bare object -- verified, but cheap to keep honest.)
$writtenArchives = @($check.archives).Count
if ($writtenArchives -ne $archiveEntries.Count) {
    throw "Wrote $OutFile but it contains $writtenArchives archive entries, expected $($archiveEntries.Count)."
}

# $files holds ordered hashtables, whose keys are not properties Measure-Object can see.
$totalMb = [math]::Round((($files | ForEach-Object { $_.size } | Measure-Object -Sum).Sum) / 1MB, 2)
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "  $($files.Count) files, $totalMb MB"
Write-Host "  base url: $BaseUrl"
if (-not $LauncherUrl) {
    Write-Host "  note: launcherUrl empty -> self-update disabled until you set it." -ForegroundColor Yellow
}
