<#
.SYNOPSIS
  Generates baseline.json: the hash of every stock client file the launcher does not
  otherwise manage, plus a staging tree of those files under the versioned names the
  patch host serves them under.

.DESCRIPTION
  manifest.json describes the ~480 files we publish. It says nothing about the other
  17 GB, so a client carrying a foreign patch-enUS-X.MPQ from some other server, or a
  half-truncated common.MPQ, looked exactly like a healthy one to the launcher. This
  file is the other half: what a legitimate Uncapped client is made of.

  Together they are complete. Anything found under a checked root that is in neither
  is, by definition, not part of an Uncapped release.

  WHAT IS COVERED, AND WHY NOT EVERYTHING

    Data\**          every file, hashed. This is where a foreign MPQ lands and where
                     corruption actually breaks the client.
    <root>\*.exe     the stock Blizzard binaries, non-recursive.
    <root>\*.dll

    Interface\       deliberately NOT covered. Our own addons under Interface\AddOns
                     are already hashed by manifest.json, and everything else there is
                     the player's own business -- ForeignAddOnScanner already names
                     third-party addons once, and the standing rule is that we never
                     delete an addon we did not write. Treating someone's Dominos
                     install as evidence of an illegitimate client would be nonsense,
                     and the warning would fire for nearly everyone.

    Cache, WTF,      player-generated, excluded on the user's instruction. Logs,
    Logs, Errors,    Errors and Screenshots are the same kind of thing and are
    Screenshots      excluded for the same reason: a screenshot is not tampering.

  REQUIRED VS INFORMATIONAL

  There are two ways into a legitimate client -- the ChromieCraft torrent and the
  Internet Archive's split zips (see manifest.client) -- and they agree on every MPQ
  but not necessarily on the long tail of Credits.html / Documentation\ / *.url that
  ships beside them. So only files that determine whether the client RUNS are marked
  required. The rest are verified when they match and never block PLAY, which keeps a
  cosmetic difference between two legitimate installs from reading as tampering.

.EXAMPLE
  .\New-Baseline.ps1 -ClientDir 'C:\Wotlk\Client\ChromieCraft_3.3.5a - Copy' -Stage
  .\Publish-Baseline.ps1
#>
[CmdletBinding()]
param(
    # A client to read stock bytes from. Must be a legitimate install; anything wrong
    # in here is what every player gets told is correct, so prefer one that has never
    # been used for testing.
    [string]$ClientDir  = 'C:\Wotlk\Client\ChromieCraft_3.3.5a - Copy',

    # Our own published files, excluded from the baseline because they are already
    # hashed there -- and because their content changes on every release, which the
    # baseline must not.
    [string]$ManifestFile = 'C:\Wotlk\Launcher\manifest.json',

    [string]$OutFile    = 'C:\Wotlk\Launcher\baseline.json',

    # Where the patch host serves repair downloads from.
    [string]$BaseUrl    = 'http://152.53.115.249/base',

    # Copy every required file here under its versioned name, ready to upload. ~15 GB,
    # so it is opt-in: regenerating the hashes alone does not need it.
    [switch]$Stage,
    [string]$StageDir   = 'C:\Wotlk\Launcher\.baseline-stage',

    # Bumped when the stock client itself changes -- which is to say, essentially never.
    # It exists so a served filename is immutable and can be cached forever.
    [string]$ClientBuild = '12340',

    # The locale the hashes were taken from. Files under Data\<this>\ are locale-specific,
    # so a client in another language cannot be checked against them; the launcher skips
    # them rather than calling a legitimate deDE client foreign.
    [string]$Locale     = 'enUS'
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ClientDir))   { throw "Client not found at $ClientDir" }
if (-not (Test-Path $ManifestFile)) { throw "Manifest not found at $ManifestFile" }

$clientRoot = (Resolve-Path $ClientDir).Path

# ---------------------------------------------------------------------------
# What our own manifest already covers.
#
# Compared case-insensitively with forward slashes, and with the locale folder
# normalised, so Data/enGB/patch-enGB-Q.MPQ in a manifest generated against another
# locale still matches Data/enUS/patch-enUS-Q.MPQ here.
# ---------------------------------------------------------------------------
$manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json
$managed  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($f in $manifest.files) { [void]$managed.Add(($f.path -replace '\\', '/')) }

# Also managed: anything the launcher itself creates or renames into place.
$launcherArtefacts = @(
    'UncappedClient.dat',   # manifest ships the patched client under this name
    'UncappedCT.dll',       # manifest ships the runtime DLL
    'Uncapped.exe',         # the launcher, when installed into the game folder
    'uncapped.config.json',
    'realmlist.wtf',
    'Wow.exe',              # renamed to UncappedClient.dat by ClientHardening
    'Repair.exe'            # deleted by ClientHardening
)

# Working files that are never part of a release and must not become baseline entries.
$ignoredPatterns = @(
    '*.log', '*.bak', '*.tmp', '*.uncapped-tmp',
    '*.retired-*',          # patches we pulled; the launcher leaves them on disk
    '*.disabled-for-testing',
    '*-backup', '*.live-backup', '*.prod-backup', '*.vps-backup',
    'Thumbs.db', 'desktop.ini'
)

# Folders never descended into. Cache and WTF on the user's instruction; the other
# three are the same class of player-generated data. Interface is excluded for the
# reason in the header comment.
$skipRoots = @('Cache', 'WTF', 'Logs', 'Errors', 'Screenshots', 'Interface')

function Test-Ignored([string]$name) {
    foreach ($p in $ignoredPatterns) { if ($name -like $p) { return $true } }
    return $false
}

# A file whose absence or corruption stops the client working. Everything else is
# documentation that ships beside it.
function Test-Required([string]$relative) {
    if ($relative -match '\.(mpq)$')      { return $true }
    if ($relative -match '\.(exe|dll)$')  { return $true }
    return $false
}

# The name the patch host serves this under. Versioned, so the bytes behind a URL
# never change and nginx can cache it forever -- the same rule the MPQ patches follow.
function Get-ServedName([string]$relative, [string]$build) {
    $leaf = Split-Path $relative -Leaf
    $stem = [IO.Path]::GetFileNameWithoutExtension($leaf)
    $ext  = [IO.Path]::GetExtension($leaf)
    # Flatten the path into the name: Data/enUS/base-enUS.MPQ and a hypothetical
    # Data/base-enUS.MPQ must not collide in a single flat directory.
    $dir  = (Split-Path $relative -Parent) -replace '[\\/]', '-'
    if ($dir) { return "$dir-$stem-$build$ext" }
    return "$stem-$build$ext"
}

# ---------------------------------------------------------------------------
# Collect.
# ---------------------------------------------------------------------------
$candidates = New-Object System.Collections.Generic.List[object]

# Data\, recursively.
$dataDir = Join-Path $clientRoot 'Data'
if (Test-Path $dataDir) {
    foreach ($f in Get-ChildItem $dataDir -Recurse -File) {
        $candidates.Add($f)
    }
} else {
    throw "No Data folder under $clientRoot -- that is not a client install."
}

# Client root, non-recursive, executables and libraries only. A loose .txt in the game
# folder is not evidence of anything.
foreach ($f in Get-ChildItem $clientRoot -File) {
    if ($f.Extension -in '.exe', '.dll') { $candidates.Add($f) }
}

Write-Host "Scanning $($candidates.Count) candidate file(s) under $clientRoot" -ForegroundColor Cyan

$entries  = New-Object System.Collections.Generic.List[object]
$skipped  = New-Object System.Collections.Generic.List[string]
$totalBytes = 0L
$done = 0

foreach ($f in $candidates) {
    $relative = $f.FullName.Substring($clientRoot.Length + 1)
    $slashed  = $relative -replace '\\', '/'
    $leaf     = $f.Name

    $top = ($slashed -split '/')[0]
    if ($skipRoots -contains $top)      { continue }
    if (Test-Ignored $leaf)             { $skipped.Add("$slashed (working file)"); continue }
    if ($launcherArtefacts -contains $leaf) { $skipped.Add("$slashed (launcher-managed)"); continue }
    if ($managed.Contains($slashed))    { $skipped.Add("$slashed (in manifest.json)"); continue }

    $done++
    Write-Progress -Activity 'Hashing client' -Status $slashed `
                   -PercentComplete ([Math]::Min(100, 100 * $done / $candidates.Count))

    $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $f.FullName).Hash.ToLowerInvariant()
    $required = Test-Required $slashed

    # Locale-specific files can only be checked on a client of the same language.
    $isLocale = $slashed -match "^Data/$Locale/"

    $entry = [ordered]@{
        path     = $slashed
        sha256   = $sha
        size     = $f.Length
        required = $required
    }
    if ($isLocale) { $entry.locale = $true }
    if ($required) {
        $served  = Get-ServedName $slashed $ClientBuild
        $entry.url    = "$($BaseUrl.TrimEnd('/'))/$served"
        $entry.served = $served
    }

    $entries.Add([pscustomobject]$entry)
    $totalBytes += $f.Length
}

Write-Progress -Activity 'Hashing client' -Completed

$requiredEntries = @($entries | Where-Object { $_.required })
$requiredBytes   = ($requiredEntries | Measure-Object -Property size -Sum).Sum

$baseline = [ordered]@{
    baselineVersion = 1
    generated       = (Get-Date -Format 'yyyy-MM-dd')
    clientBuild     = $ClientBuild
    locale          = $Locale

    # Where the launcher looks, and what it leaves alone. Published rather than compiled
    # in so the scope can be narrowed without a launcher release if it turns out to be
    # flagging something legitimate.
    checkedRoots    = @('Data')
    checkRootFiles  = @('.exe', '.dll')
    skipRoots       = $skipRoots

    # Files that may be present without being foreign: the launcher renames or removes
    # these itself, so finding one is normal rather than suspicious.
    toleratedNames  = $launcherArtefacts
    toleratedPatterns = $ignoredPatterns

    files           = $entries
}

$json = $baseline | ConvertTo-Json -Depth 6

# No BOM. Set-Content -Encoding utf8 emits one on PowerShell 5.1, and a BOM in front of
# the opening brace makes System.Text.Json throw on the launcher side.
[IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "baseline.json written to $OutFile" -ForegroundColor Green
Write-Host ("  {0,5} files    {1,8:N1} GB total" -f $entries.Count, ($totalBytes / 1GB))
Write-Host ("  {0,5} required {1,8:N1} GB to host" -f $requiredEntries.Count, ($requiredBytes / 1GB))
Write-Host ("  {0,5} skipped" -f $skipped.Count)

if ($skipped.Count -gt 0) {
    Write-Host ''
    Write-Host 'Skipped:' -ForegroundColor DarkGray
    foreach ($s in $skipped) { Write-Host "  $s" -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# Stage the required files under their served names, ready to upload.
# ---------------------------------------------------------------------------
if ($Stage) {
    Write-Host ''
    Write-Host "Staging $($requiredEntries.Count) file(s) to $StageDir" -ForegroundColor Cyan

    New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

    $n = 0
    foreach ($e in $requiredEntries) {
        $n++
        $source = Join-Path $clientRoot ($e.path -replace '/', '\')
        $dest   = Join-Path $StageDir $e.served

        Write-Progress -Activity 'Staging' -Status $e.served `
                       -PercentComplete (100 * $n / $requiredEntries.Count)

        # Skip a copy that is already correct: this is 15 GB and re-running the script
        # should not mean re-writing all of it.
        if (Test-Path $dest) {
            $existing = Get-Item $dest
            if ($existing.Length -eq $e.size) { continue }
        }

        Copy-Item -LiteralPath $source -Destination $dest -Force
    }

    Write-Progress -Activity 'Staging' -Completed
    Write-Host "Staged. Upload with Publish-Baseline.ps1" -ForegroundColor Green
}
