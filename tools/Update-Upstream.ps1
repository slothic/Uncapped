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
    [string[]]$Assets  = @('Astrolabe.zip', 'WDM.zip', 'QuestHelper.zip')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$dest = Join-Path $AddonsDir 'upstream'
New-Item -ItemType Directory -Force $dest | Out-Null

Write-Host "Fetching $Repo @ $Tag" -ForegroundColor Cyan

$release = Invoke-RestMethod "https://api.github.com/repos/$Repo/releases/tags/$Tag" -TimeoutSec 30
$wc = New-Object Net.WebClient

foreach ($name in $Assets) {
    $asset = $release.assets | Where-Object { $_.name -eq $name }
    if (-not $asset) {
        Write-Warning "  $name not present in $Tag - skipping"
        continue
    }

    $out = Join-Path $dest $name
    $wc.DownloadFile($asset.browser_download_url, $out)

    $actual = (Get-Item $out).Length
    if ($actual -ne $asset.size) {
        throw "$name downloaded $actual bytes but the release says $($asset.size)."
    }

    Write-Host ("  + {0,-20} {1,7} KB" -f $name, [math]::Round($actual / 1KB)) -ForegroundColor Green
}

Write-Host "`nUpstream addons in $dest" -ForegroundColor Cyan
Write-Host "Next: .\Build-Payload.ps1 -Clean"
