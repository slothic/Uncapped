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
    # Where baseline.json is published -- the hashes of the stock client under our payload,
    # which is what lets the launcher tell a legitimate install from one carrying files from
    # another server. Regenerate it with New-Baseline.ps1; this only points at it.
    #
    # ⚠ Set to '' to turn the whole integrity check off for every player. That is the intended
    # off switch if it ever starts flagging something legitimate -- and it is also what an
    # accidental omission here would do, which is why it has a default rather than being
    # inherited from whatever happened to be in the previous manifest.
    [string]$BaselineUrl     = 'http://152.53.115.249/baseline.json',
    # Where the launcher's support button points. Empty hides the button outright, so this
    # is also the off switch. Published here rather than compiled into the exe because it
    # has already moved once (PayPal -> Ko-fi) and a URL in the binary makes that a release.
    [string]$DonateUrl       = 'https://ko-fi.com/uncapped',
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

    # Escape hatch for regenerating the manifest with no network (or before the release
    # asset has been uploaded). Skips the launcherUrl/launcherSha256 agreement check --
    # which is the check that catches a self-update that would fail for every player, so
    # do not make a habit of it.
    [switch]$SkipLauncherUrlCheck,
    [string]$LauncherExe     = 'C:\Wotlk\Launcher\src\Uncapped\bin\Release\net9.0-windows\win-x64\publish\Uncapped.exe',
    # Files served from somewhere other than this repo (the WDM MPQ patches, which live in
    # Trimitor's releases). Downloaded once to a cache purely so we can hash them.
    [string]$ExternalFiles = 'C:\Wotlk\Launcher\tools\external-files.json',
    # Skip the client-attestation release interlock. Only for a payload that does not
    # involve UncappedCT.dll at all -- see the check itself, near the top of the body.
    [switch]$SkipAttestCheck,
    # Zips fetched from someone else's host and unpacked into the install, for addons we are
    # not entitled to redistribute. Hashed here so the launcher can pin them.
    [string]$Archives      = 'C:\Wotlk\Launcher\tools\archives.json',
    # The server-generated client item cache. Externally hosted like the MPQs, but it is NOT a
    # manifest file entry -- see the block that reads it for why that distinction is the whole
    # design. Set "enabled": false in there to roll the feature back.
    [string]$ItemCache     = 'C:\Wotlk\Launcher\tools\itemcache.json',
    [string]$ExternalCache = 'C:\Wotlk\Launcher\.external-cache',
    [string]$Magnet          = 'magnet:?xt=urn:btih:2ba2833baf733ce0a16040d43ed09491f2bf2ab2&dn=ChromieCraft_3.3.5a.zip&tr=udp%3A%2F%2Ftracker.openbittorrent.com%3A80%2Fannounce&tr=http%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce&tr=udp%3A%2F%2Ftracker.uw0.xyz%3A6969%2Fannounce&tr=udp%3A%2F%2Ftracker.zerobytes.xyz%3A1337%2Fannounce',
    [string]$DirectDownloadUrl = $null
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $PayloadDir)) { throw "Payload not found at $PayloadDir. Run Build-Payload.ps1 first." }

# --- Attestation release interlock -------------------------------------------------------
# The client-attestation variant set is regenerated every release, and the worldserver
# refuses to enforce against a client carrying a different one. So the DLL the manifest
# pins MUST be built from the same generator run as the worldserver tree. If it is not,
# attestation silently does nothing at best -- and if the mismatch goes the other way,
# every player on the realm fails at once.
#
# This is gated here, in New-Manifest, because the manifest is the only thing the launcher
# reads: nothing reaches a player until this script writes it. A check anywhere earlier can
# be skipped by running this directly.
#
# ⚠ It exists because the failure has already happened. UncappedCT-2026.08.09a.dll was
# built and published to the host on 2026-08-09 while external-files.json still pinned
# 08.07b, so a DLL nobody ever received sat live for a day and nothing noticed.
#
# -SkipAttestCheck is the deliberate override for a payload that genuinely does not touch
# the DLL. It is not a way past a red check on one that does.
if (-not $SkipAttestCheck) {
    $attestCheck = 'C:\Wotlk\Server\azerothcore-wotlk\tools\attestation\check_release.py'
    if (Test-Path $attestCheck) {
        Write-Host "`nAttestation release interlock:" -ForegroundColor Cyan
        & python $attestCheck
        if ($LASTEXITCODE -ne 0) {
            throw @"
Attestation release interlock FAILED (see above). No manifest was written.

The client DLL and the worldserver would disagree about the variant set, which means
attestation either does nothing or locks the realm out. Fix the mismatch it named, or
pass -SkipAttestCheck if this payload genuinely does not involve UncappedCT.dll.
"@
        }
    } else {
        Write-Warning "Attestation interlock script not found at $attestCheck - skipping (is the server repo present?)"
    }
}

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

            # The cache key includes the URL, not just the destination path.
            #
            # These used to be pinned to a release tag whose asset name never changed, so
            # "same path" implied "same bytes". They are now pinned to IMMUTABLE VERSIONED
            # URLs on our own host (patch-enUS-U-2026.08.04a.MPQ), where one path maps to
            # many different files over time. Keyed on path alone, publishing a new version
            # would silently reuse the previous version's cached copy and write the OLD
            # hash against the NEW url -- a manifest that every client is then guaranteed
            # to reject, for everyone, at once. Exactly the failure the launcherSha256
            # comment below describes, and worth spending twelve characters to prevent.
            $sha = [Security.Cryptography.SHA256]::Create()
            try {
                $urlKey = ([BitConverter]::ToString(
                    $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($e.url))
                ) -replace '-', '').Substring(0, 12).ToLower()
            } finally { $sha.Dispose() }
            $cached = Join-Path $ExternalCache (($e.path -replace '[\\/]', '_') + '.' + $urlKey)

            # Re-download only when absent. A given URL's bytes never change, so a cache
            # hit is always correct; delete the cache to force a refresh.
            if (-not (Test-Path $cached)) {
                Write-Host "  downloading $($e.path)..." -ForegroundColor DarkGray
                $wc.DownloadFile($e.url, $cached)
            }

            $item = Get-Item $cached
            if ($item.Length -eq 0) { throw "External file $($e.path) downloaded as 0 bytes." }

            # Same reasoning as the zip signature check on archives below: a 403 page, an
            # nginx 404 body or a truncated transfer is still a file, and would otherwise be
            # published as a perfectly valid hash of the wrong thing.
            #
            # The expected signature depends on what the entry is. This used to assume MPQ
            # for everything, which was true while the only externally hosted files were the
            # client patches -- the game executable and its injected DLL are now served the
            # same way, and they start with "MZ". An entry with no known extension is still
            # checked, against nothing being served at all, because a zero-length or
            # error-page response is the failure this exists to catch.
            $sig = [IO.File]::ReadAllBytes($cached)[0..3]
            $ext = [IO.Path]::GetExtension($e.path).ToLower()
            switch -Regex ($ext) {
                '^\.(exe|dll|dat)$' {
                    if ($sig[0] -ne 0x4D -or $sig[1] -ne 0x5A) {
                        throw "External file $($e.path) does not start with the MZ magic bytes (got $($sig -join ',')). The host probably served an error page."
                    }
                    Write-Host "    PE signature ok" -ForegroundColor DarkGray
                }
                default {
                    if ($sig[0] -ne 0x4D -or $sig[1] -ne 0x50 -or $sig[2] -ne 0x51 -or $sig[3] -ne 0x1A) {
                        throw "External file $($e.path) does not start with the MPQ magic bytes (got $($sig -join ',')). The host probably served an error page."
                    }
                }
            }

            $actualHash = (Get-FileHash $cached -Algorithm SHA256).Hash.ToLower()

            # An entry may pin the hash it expects. publish.sh prints it, so pasting the
            # snippet it gives you gets this for free. It turns "the host served me
            # something else" from a silent re-publish into a hard stop.
            if ($e.PSObject.Properties['sha256'] -and $e.sha256) {
                if ($e.sha256.ToLower() -ne $actualHash) {
                    throw @"
External file $($e.path) does not match the sha256 pinned in external-files.json.
  pinned   $($e.sha256.ToLower())
  actual   $actualHash
  url      $($e.url)
Either the host is serving different bytes than you published, or the pin is stale.
Nothing was written.
"@
                }
                Write-Host "    sha256 pin verified" -ForegroundColor DarkGray
            } else {
                Write-Warning "  $($e.path) has no sha256 pin in external-files.json - publishing whatever the host served."
            }

            $files += [ordered]@{
                path   = $e.path
                url    = $e.url
                sha256 = $actualHash
                size   = $item.Length
            }
            Write-Host ("  + {0,-32} {1,6} MB" -f $e.path, [math]::Round($item.Length / 1MB, 1)) -ForegroundColor Green
        }
    }
}

# --- The server-generated item cache -----------------------------------------------------
# Externally hosted like the MPQs, but deliberately NOT one of $files.
#
# THE CLIENT REWRITES Cache\WDB\<locale>\itemcache.wdb CONTINUOUSLY DURING PLAY. As a manifest
# file entry it would be hash-compared on every launch, never match, re-download 1.7 MB every
# time forever -- and, worse, be reported Corrupt by the integrity check, which BLOCKS PLAY.
# It gets its own manifest block with an epoch token instead, which the launcher compares
# against a sentinel file it writes beside the cache and the client never touches.
#
# Absent block == feature off == the launcher wipes Cache\WDB and installs nothing, which is
# what it did before this existed. That is the rollback, and it is one edit in itemcache.json.
$itemCacheEntry = $null
if (Test-Path $ItemCache) {
    $ic = Get-Content $ItemCache -Raw | ConvertFrom-Json

    if (-not $ic.enabled) {
        Write-Host "`nItem cache: DISABLED in $(Split-Path -Leaf $ItemCache) - no itemCache block written." -ForegroundColor Yellow
        Write-Host "  Clients will wipe Cache\WDB and install nothing, as before." -ForegroundColor DarkGray
    }
    else {
        Write-Host "`nServer-generated item cache:" -ForegroundColor Cyan

        foreach ($required in 'epoch', 'url', 'sha256', 'contentSha256') {
            if (-not $ic.$required) { throw "itemcache.json is enabled but has no '$required'." }
        }

        # Same URL-keyed cache as the external files: these filenames are immutable, so a hit
        # is always correct, and keying on the URL means a new epoch is always re-fetched.
        New-Item -ItemType Directory -Force $ExternalCache | Out-Null
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $urlKey = ([BitConverter]::ToString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($ic.url))
            ) -replace '-', '').Substring(0, 12).ToLower()
        } finally { $sha.Dispose() }
        $cached = Join-Path $ExternalCache ("itemcache." + $urlKey + ".gz")

        if (-not (Test-Path $cached)) {
            Write-Host "  downloading $($ic.url)..." -ForegroundColor DarkGray
            $wc2 = New-Object Net.WebClient
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $wc2.DownloadFile($ic.url, $cached)
        }

        $icItem = Get-Item $cached
        if ($icItem.Length -eq 0) { throw "Item cache downloaded as 0 bytes." }

        # An nginx 404 body is still a file. Prove it is a gzip before trusting anything else.
        $icSig = [IO.File]::ReadAllBytes($cached)[0..1]
        if ($icSig[0] -ne 0x1F -or $icSig[1] -ne 0x8B) {
            throw "Item cache does not start with the gzip magic bytes (got $($icSig -join ',')). The host probably served an error page."
        }

        $icHash = (Get-FileHash $cached -Algorithm SHA256).Hash.ToLower()
        if ($icHash -ne $ic.sha256.ToLower()) {
            throw @"
Item cache does not match the sha256 pinned in itemcache.json.
  pinned   $($ic.sha256.ToLower())
  actual   $icHash
  url      $($ic.url)
Either the host is serving different bytes than you published, or the pin is stale.
Nothing was written.
"@
        }

        # And check what comes OUT of the gzip, because that is the file the client parses and
        # the transport hash says nothing about it. This is also the only place the WDB layout
        # is asserted before players get the bytes: 24-byte header starting "BDIW", client
        # build 12340, terminated by eight zero bytes.
        $plain = Join-Path $ExternalCache ("itemcache." + $urlKey + ".wdb")
        if (-not (Test-Path $plain)) {
            $in  = [IO.File]::OpenRead($cached)
            $gz  = New-Object IO.Compression.GzipStream($in, [IO.Compression.CompressionMode]::Decompress)
            $out = [IO.File]::Create($plain)
            try { $gz.CopyTo($out) } finally { $out.Dispose(); $gz.Dispose(); $in.Dispose() }
        }

        $plainItem = Get-Item $plain
        $plainHash = (Get-FileHash $plain -Algorithm SHA256).Hash.ToLower()
        if ($plainHash -ne $ic.contentSha256.ToLower()) {
            throw "Decompressed item cache hashes $plainHash, itemcache.json pins $($ic.contentSha256.ToLower())."
        }
        if ($ic.contentSize -and $plainItem.Length -ne $ic.contentSize) {
            throw "Decompressed item cache is $($plainItem.Length) bytes, itemcache.json says $($ic.contentSize)."
        }

        $head = New-Object byte[] 8
        $tail = New-Object byte[] 8
        $fs = [IO.File]::OpenRead($plain)
        try {
            [void]$fs.Read($head, 0, 8)
            [void]$fs.Seek(-8, [IO.SeekOrigin]::End)
            [void]$fs.Read($tail, 0, 8)
        } finally { $fs.Dispose() }

        if ([Text.Encoding]::ASCII.GetString($head, 0, 4) -ne 'BDIW') {
            throw "Item cache is not a WDB file (magic '$([Text.Encoding]::ASCII.GetString($head,0,4))', expected 'BDIW')."
        }
        $icBuild = [BitConverter]::ToUInt32($head, 4)
        if ($icBuild -ne 12340) { throw "Item cache is for client build $icBuild, expected 12340." }
        if ($tail | Where-Object { $_ -ne 0 }) {
            throw "Item cache does not end in the eight-zero-byte terminator."
        }

        $icLocales = if ($ic.locales) { @($ic.locales) } else { @('enUS') }

        $itemCacheEntry = [ordered]@{
            epoch         = $ic.epoch
            url           = $ic.url
            sha256        = $icHash
            size          = $icItem.Length
            contentSha256 = $plainHash
            contentSize   = $plainItem.Length
            # ⚠ [string[]] IS LOad-BEARING. ConvertTo-Json serialises a ONE-element
            # array as a bare scalar -- "locales": "enUS" instead of ["enUS"] --
            # and the launcher's ItemCacheSpec.Locales is a List<string>, so every
            # client that parsed it threw and showed "Could not reach the update
            # server". @() alone does NOT survive the round trip; the cast does.
            locales       = [string[]]$icLocales
        }

        Write-Host ("  + epoch {0}  {1} MB gz -> {2} MB  [{3}]" -f `
            $ic.epoch, [math]::Round($icItem.Length / 1MB, 2),
            [math]::Round($plainItem.Length / 1MB, 2), ($icLocales -join ',')) -ForegroundColor Green
        Write-Host "    gzip + sha256 + content sha256 + WDB header/terminator verified" -ForegroundColor DarkGray
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

# PROVE the launcher triple is self-consistent instead of trusting that whoever ran this
# passed a matching set.
#
# The carry-forward above defends the two failure modes that had already happened. It could
# not defend the one that had not: v1.8.4 was published with -LauncherVersion and
# -LauncherSha256 but WITHOUT -LauncherUrl, so the url was inherited from v1.8.2 while the
# version and hash moved on. The manifest then advertised 1.8.4, pinned 1.8.4's bytes, and
# pointed at 1.8.2's download. Every client older than 1.8.4 fetched 1.8.2, failed the hash
# check, and refused to update -- self-update was dead realm-wide, silently, for three days.
#
# Fetching 2 MB at publish time settles every permutation of that at once, and turns a
# realm-wide silent failure into a local hard stop. Same principle as the external-file pins.
if ($LauncherUrl -and $launcherHash -and -not $SkipLauncherUrlCheck) {
    Write-Host "`nVerifying launcherUrl serves launcherSha256..." -ForegroundColor Cyan
    $probe = Join-Path $env:TEMP ("uncapped-launcher-check-" + [guid]::NewGuid().ToString('N') + ".bin")
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        (New-Object Net.WebClient).DownloadFile($LauncherUrl, $probe)
        $served = (Get-FileHash $probe -Algorithm SHA256).Hash.ToLower()
        if ($served -ne $launcherHash.ToLower()) {
            throw @"
launcherUrl does not serve the bytes launcherSha256 pins.
  version  $LauncherVersion
  url      $LauncherUrl
  pinned   $($launcherHash.ToLower())
  served   $served
Self-update would download that file, fail its hash check and refuse to update -- for every
player at once, with nothing on screen to say so. Either upload this build to the release the
url names, or pass the -LauncherUrl that matches it.
Nothing was written.
"@
        }
        Write-Host "  launcherUrl and launcherSha256 agree" -ForegroundColor DarkGray
    } finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
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

$donateUrlValue = $null
if ($DonateUrl) { $donateUrlValue = $DonateUrl }

$baselineUrlValue = $null
if ($BaselineUrl) { $baselineUrlValue = $BaselineUrl }

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
        # HTTP fallback, used only when BitTorrent fails outright.
        #
        # ★ 2026-08-13: THIS LIST IS NOW ONE ENTRY, SERVED BY US. Two separate
        # failures drove that, and both are worth knowing before anyone adds a
        # third-party URL back.
        #
        # 1. Common.zip was REMOVED, not repointed. The Archive's copy of 3.3.5a
        #    is a DIFFERENT BUILD from the one baseline.json was generated
        #    against -- six files differ (common, common-2, expansion, lichking,
        #    patch-2, Scan.dll) -- so the launcher downloaded a client and then
        #    its own integrity check declared it corrupt and disabled PLAY. The
        #    acquirer now pulls every required base file from our own host after
        #    unpacking, which makes acquisition and verification agree by
        #    construction. Common.zip is redundant against that.
        #
        # 2. enUS.zip is MIRRORED ON OUR HOST. It is the only source of the
        #    cinematics, which the baseline does not cover, so it could not
        #    simply be dropped. But a player's log showed four consecutive
        #    install failures and every one was a TLS stream dying mid-transfer
        #    against archive.org -- never against this host. Mirroring removes
        #    the last third party from the install path.
        #
        # The mirrored bytes were verified against the baseline entry by entry
        # before being served. Size is the real Content-Length.
        directDownloadUrls = @(
            [ordered]@{
                url   = 'http://152.53.115.249/patches/3.3.5-12340_enUS.zip'
                name  = '3.3.5-12340_enUS.zip'
                bytes = 2628185615
            }
        )
        # The torrent's payload is this single zip.
        archiveName       = 'ChromieCraft_3.3.5a.zip'
        archiveBytes      = $archiveBytes
        installedBytes    = $installedBytes
    }
    crashReportWebhook = $crashWebhookValue
    hardenClient       = $HardenClient
    largeAddressAware  = $LargeAddressAware

    baselineUrl = $baselineUrlValue

    newsUrl = $newsUrlValue
    # Null hides the launcher's support button rather than pointing it nowhere.
    donateUrl = $donateUrlValue
    news    = $news
    files   = @($files)

    # Zips the launcher fetches from their author's own host and unpacks. Not in files[] and
    # not in payload\: we do not redistribute these. See tools\archives.json.
    archives = @($archiveEntries)

    # The server-generated itemcache.wdb, or absent when itemcache.json says enabled:false.
    # Absent is the off switch AND the rollback -- the launcher then wipes Cache\WDB and
    # installs nothing, exactly as it did before this existed. See tools\itemcache.json.
    itemCache = $itemCacheEntry

    # Force-ticked in AddOns.txt on every launch. StatFeed is the reason the launcher exists;
    # without it players see no stat-gain messages at all.
    forceEnableAddOns = @('StatFeed', 'ReagentBankCraft', 'UncappedMythic', 'UncappedRewards', 'UncappedAlerts', 'UncappedVersion', 'UncappedGCD', 'UncappedOptions', 'UncappedUI', 'UncappedDashboard', 'UncappedChat', 'UncappedQuests', 'UncappedBugReporter', 'UncappedShieldBar')

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
        'Interface/AddOns/UncappedBugReporter',
        # [#522] Shield bar. Listed from its FIRST release, so it never joins the
        # group above that shipped unlisted and became impossible to prune.
        'Interface/AddOns/UncappedShieldBar',
        # The Dashboard bundles Forge/Soulforge/Anima/Vault/Transmog/Scrolls as folders
        # inside itself, so it is the only one of them still installed as an addon.
        # The six standalone entries above are deliberately KEPT listed even though they
        # no longer ship: that is the only thing that deletes them from players' clients.
        # Leaving them behind would load every one of those files twice -- same rule as
        # devUncapped64 and UncappedTempo below.
        'Interface/AddOns/UncappedDashboard',
        'Interface/AddOns/UncappedUI',
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
# The item cache is one object rather than a list, and a silently dropped epoch would leave
# every client believing it is already up to date with whatever it last installed -- a
# no-op release that looks like a successful one.
if ($itemCacheEntry -and $check.itemCache.epoch -ne $itemCacheEntry.epoch) {
    throw "Wrote $OutFile but its itemCache epoch is '$($check.itemCache.epoch)', expected '$($itemCacheEntry.epoch)'."
}
if (-not $itemCacheEntry -and $check.itemCache) {
    throw "Wrote $OutFile but it carries an itemCache block that should not be there."
}

# $files holds ordered hashtables, whose keys are not properties Measure-Object can see.
$totalMb = [math]::Round((($files | ForEach-Object { $_.size } | Measure-Object -Sum).Sum) / 1MB, 2)
Write-Host "Wrote $OutFile" -ForegroundColor Green
Write-Host "  $($files.Count) files, $totalMb MB"
Write-Host "  base url: $BaseUrl"
if (-not $LauncherUrl) {
    Write-Host "  note: launcherUrl empty -> self-update disabled until you set it." -ForegroundColor Yellow
}
