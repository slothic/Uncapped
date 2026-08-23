<#
.SYNOPSIS
  Pulls the latest WDM addon zips from Trimitor's releases.

.DESCRIPTION
  Astrolabe, WDM and QuestHelper are maintained upstream at Trimitor/WDM-addons and are the
  versions that match the WDM dungeon-map patches. They land in Addons\upstream\, which
  Build-Payload.ps1 stages before anything else, so these win over any older copy sitting
  loose in Addons\.

  The MPQ patches are NOT downloaded here - the manifest points players straight at
  Trimitor's release assets. See external-files.json.
#>
[CmdletBinding()]
param(
    [string]$AddonsDir = 'C:\Wotlk\Addons',
    [string]$Repo      = 'Trimitor/WDM-addons',
    # Pin the tag so an upstream release cannot silently change what players get.
    [string]$Tag       = '1.0.9-stable',
    [string[]]$Assets  = @('Astrolabe.zip', 'WDM.zip', 'QuestHelper.zip'),
    # ★★ LA-11. The CONTENT pins. A tag is not a pin: GitHub lets a release asset be deleted
    # and re-uploaded under the same tag and the same name. See the file's own comment.
    [string]$Pins      = 'C:\Wotlk\Launcher\tools\upstream-pins.json'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest = Join-Path $AddonsDir 'upstream'
New-Item -ItemType Directory -Force $dest | Out-Null

Write-Host "Fetching $Repo @ $Tag" -ForegroundColor Cyan

# ★★ LA-11. THE PINS, AND WHY A SIZE CHECK WAS NOT ONE.
#
# This script used to verify each download with `$actual -ne $asset.size` -- the length on
# disk against the length the SAME GitHub API response reported for the SAME asset. That is
# a recording of what we were handed, not a check on it. GitHub permits an asset behind an
# existing tag to be deleted and re-uploaded, so the pinned tag does not fix the bytes; and
# whatever chooses the bytes chooses the length reported alongside them.
#
# What that costs if it ever happens: unreviewed third-party Lua staged by Build-Payload,
# hashed by New-Manifest as if it were ours, and shipped to every client -- with every
# downstream integrity check agreeing, because they all pin what this step produced.
#
# Every other external input in this tree carries an independently checked-in sha256. These
# now do too. A mismatch is a hard stop and the reviewer's cue, never a warning.
if (-not (Test-Path $Pins)) {
    throw "$Pins is missing. It carries the sha256 of each upstream addon zip; without it this script would stage third-party code that nothing has checked. It is checked in -- restore it rather than working around it."
}
$pinData = Get-Content $Pins -Raw | ConvertFrom-Json

if ($pinData.tag -ne $Tag) {
    throw @"
Tag mismatch: -Tag is '$Tag' but $(Split-Path -Leaf $Pins) pins '$($pinData.tag)'.
The pins below describe a different upstream release, so they cannot verify this one.
Moving to a new tag is deliberate: bump 'tag' in that file, re-run, and paste in the new
hashes it reports AFTER reviewing what changed.
Nothing was downloaded.
"@
}

$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/tags/$Tag" -TimeoutSec 30
$wc = New-Object Net.WebClient

foreach ($name in $Assets) {
    $asset = $release.assets | Where-Object { $_.name -eq $name }
    if (-not $asset) {
        Write-Warning "  $name not present in $Tag - skipping"
        continue
    }

    $pin = $pinData.assets.$name
    if (-not $pin) {
        throw "$name has no sha256 in $(Split-Path -Leaf $Pins). Refusing to stage an addon nothing pins. Add it after reviewing the zip."
    }

    # ⚠ Staged, not written over the live copy. A rejected download must not be able to leave
    # the previous good zip truncated or replaced -- Build-Payload reads this directory.
    $staged = Join-Path $dest ($name + '.incoming')
    $out    = Join-Path $dest $name

    try {
        $wc.DownloadFile($asset.browser_download_url, $staged)

        $actualHash = (Get-FileHash $staged -Algorithm SHA256).Hash.ToLower()
        if ($actualHash -ne $pin.ToLower()) {
            throw @"
$name does NOT match its pinned sha256.
  pinned   $($pin.ToLower())
  actual   $actualHash
  tag      $Tag
  url      $($asset.browser_download_url)
The asset behind this tag has been replaced since it was reviewed, or the pin is stale.
Settle WHICH before touching either. If the change is intended, READ THE DIFF first -- this
code runs inside every player's client -- then update $(Split-Path -Leaf $Pins).
$name was not staged; the previous copy is untouched.
"@
        }

        # Size is still worth asserting, but only as a consistency note now that the hash is
        # the actual check.
        $actual = (Get-Item $staged).Length
        if ($actual -ne $asset.size) {
            Write-Warning "  $name is $actual bytes but the release metadata says $($asset.size) -- hash matched, so this is a GitHub metadata oddity, not a bad download."
        }

        Move-Item -LiteralPath $staged -Destination $out -Force
    }
    finally {
        if (Test-Path $staged) { Remove-Item -LiteralPath $staged -Force -ErrorAction SilentlyContinue }
    }

    Write-Host ("  + {0,-20} {1,7} KB  sha256 pin verified" -f $name, [math]::Round($actual / 1KB)) -ForegroundColor Green
}

Write-Host "`nUpstream addons in $dest" -ForegroundColor Cyan
Write-Host "Next: .\Build-Payload.ps1 -Clean"
