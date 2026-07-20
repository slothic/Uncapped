<#
.SYNOPSIS
  Stages everything the launcher ships into a flat payload tree.

.DESCRIPTION
  The payload mirrors the WoW install root, so a manifest entry's path is literally where
  the file lands. Mixed .zip / extracted addon sources are normalised to extracted folders
  here, which is what makes per-file hashing and delta sync work naturally.

  Sources:
    - Server\azerothcore-wotlk\client_addons\*   -> Interface\AddOns\*   (our own addons)
    - Addons\*.zip and extracted folders          -> Interface\AddOns\*   (third-party)
    - Client\...\Data\enUS\patch-enUS-*.mpq       -> Data\enUS\*          (custom patches)

  Collisions are reported rather than silently overwritten - several of the addon zips are
  duplicates of each other.
#>
[CmdletBinding()]
param(
    [string]$Root       = 'C:\Wotlk',
    [string]$PayloadDir = 'C:\Wotlk\Launcher\payload',
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if ($Clean -and (Test-Path $PayloadDir)) {
    Write-Host "Clearing $PayloadDir" -ForegroundColor DarkGray
    Remove-Item $PayloadDir -Recurse -Force
}

$addonsOut = Join-Path $PayloadDir 'Interface\AddOns'
$dataOut   = Join-Path $PayloadDir 'Data\enUS'
New-Item -ItemType Directory -Force $addonsOut, $dataOut | Out-Null

# Tracks which source claimed each addon folder, so duplicates surface instead of hiding.
$claimed = @{}

# Addons whose own files explicitly reserve all rights. Redistributing these in the payload
# would be shipping someone else's work against their stated terms, so they are excluded and
# players install them by hand. See ADDON-LICENCES.md for the quoted evidence.
# To ship one anyway, get the author's permission first, then remove it from this list.
$licenceExcluded = @{
    'AckisRecipeList'   = 'LICENSE.txt: "All Rights Reserved unless otherwise explicitly stated"'
    'ArkInventory'      = 'ArkInventory.lua:1: "(c) 2009-2010, all rights reserved."'
    'ArkInventoryRules' = 'ArkInventoryRules.lua:1: "(c) 2009-2010, all rights reserved."'
}

function Add-AddonFolder {
    param([string]$Name, [string]$SourceLabel)

    # Blizzard's stock UI addons ship with every client and are Blizzard's property. They
    # must never end up in the payload. Nothing currently feeds them in, but this keeps that
    # true if the script is ever pointed at a client's Interface\AddOns folder.
    if ($Name -like 'Blizzard_*') {
        Write-Host "  - $Name (Blizzard stock addon, never redistributed)" -ForegroundColor DarkGray
        return $false
    }

    if ($licenceExcluded.ContainsKey($Name)) {
        Write-Host "  - $Name (licence: $($licenceExcluded[$Name]))" -ForegroundColor Yellow
        return $false
    }

    if ($claimed.ContainsKey($Name)) {
        Write-Warning "  '$Name' already provided by $($claimed[$Name]); skipping $SourceLabel"
        return $false
    }
    $claimed[$Name] = $SourceLabel
    return $true
}

# --- 1. Our own addons. These take priority over anything third-party with the same name. ---
$customSrc = Join-Path $Root 'Server\azerothcore-wotlk\client_addons'
if (Test-Path $customSrc) {
    Write-Host "`nCustom addons (ours):" -ForegroundColor Cyan
    foreach ($dir in Get-ChildItem $customSrc -Directory) {
        if (-not (Add-AddonFolder -Name $dir.Name -SourceLabel 'client_addons')) { continue }
        Copy-Item $dir.FullName -Destination $addonsOut -Recurse -Force
        Write-Host "  + $($dir.Name)" -ForegroundColor Green
    }
} else {
    Write-Warning "client_addons not found at $customSrc"
}

# --- 1b. Upstream WDM addons. Staged before the loose copies in Addons\ so the versions
#         that match the WDM dungeon-map patches win. Refresh with Update-Upstream.ps1. ---
$upstream = Join-Path $Root 'Addons\upstream'
if (Test-Path $upstream) {
    Write-Host "`nUpstream addons (Trimitor/WDM-addons):" -ForegroundColor Cyan
    foreach ($zip in Get-ChildItem $upstream -Filter '*.zip' -File) {
        $archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try {
            $roots = $archive.Entries |
                     ForEach-Object { ($_.FullName -split '/')[0] } |
                     Where-Object { $_ } | Select-Object -Unique
        } finally { $archive.Dispose() }

        $wanted = $roots | Where-Object { Add-AddonFolder -Name $_ -SourceLabel "upstream/$($zip.Name)" }
        if (-not $wanted) { continue }

        $temp = Join-Path ([IO.Path]::GetTempPath()) ("uncapped-" + [Guid]::NewGuid().ToString('N'))
        try {
            [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $temp)
            foreach ($name in $wanted) {
                $src = Join-Path $temp $name
                if (Test-Path $src) {
                    Copy-Item $src -Destination $addonsOut -Recurse -Force
                    Write-Host "  + $name" -ForegroundColor Green
                }
            }
        } finally { Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# --- 2. Third-party addons: extracted folders first, then zips. ---
$thirdParty = Join-Path $Root 'Addons'
if (Test-Path $thirdParty) {
    Write-Host "`nThird-party addons (already extracted):" -ForegroundColor Cyan
    foreach ($dir in Get-ChildItem $thirdParty -Directory | Where-Object { $_.Name -ne 'upstream' }) {
        # felbite folders wrap the real addon one level down; find the folder with a .toc.
        $tocDirs = Get-ChildItem $dir.FullName -Recurse -Filter '*.toc' -File |
                   Select-Object -ExpandProperty Directory -Unique

        foreach ($t in $tocDirs) {
            if (-not (Add-AddonFolder -Name $t.Name -SourceLabel $dir.Name)) { continue }
            Copy-Item $t.FullName -Destination $addonsOut -Recurse -Force
            Write-Host "  + $($t.Name)" -ForegroundColor Green
        }
    }

    Write-Host "`nThird-party addons (from .zip):" -ForegroundColor Cyan
    foreach ($zip in Get-ChildItem $thirdParty -Filter '*.zip' -File) {
        $archive = [IO.Compression.ZipFile]::OpenRead($zip.FullName)
        try {
            # Every one of these zips carries the addon folder at its root.
            $roots = $archive.Entries |
                     ForEach-Object { ($_.FullName -split '/')[0] } |
                     Where-Object { $_ } | Select-Object -Unique
        } finally { $archive.Dispose() }

        $wanted = $roots | Where-Object { Add-AddonFolder -Name $_ -SourceLabel $zip.Name }
        if (-not $wanted) { continue }

        $temp = Join-Path ([IO.Path]::GetTempPath()) ("uncapped-" + [Guid]::NewGuid().ToString('N'))
        try {
            [IO.Compression.ZipFile]::ExtractToDirectory($zip.FullName, $temp)
            foreach ($name in $wanted) {
                $src = Join-Path $temp $name
                if (Test-Path $src) {
                    Copy-Item $src -Destination $addonsOut -Recurse -Force
                    Write-Host "  + $name" -ForegroundColor Green
                }
            }
        } finally {
            Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- 3. Custom MPQ patches from the working client. ---
Write-Host "`nCustom patches:" -ForegroundColor Cyan
$clientData = Join-Path $Root 'Client\ChromieCraft_3.3.5a\Data\enUS'
$stock = @(
    'patch-enUS.MPQ','patch-enUS-2.MPQ','patch-enUS-3.MPQ',
    'patch-enUS-M.MPQ','patch-enUS-N.MPQ','backup-enUS.MPQ','base-enUS.MPQ'
)

if (Test-Path $clientData) {
    $custom = Get-ChildItem $clientData -Filter 'patch-enUS-*.mpq' -File |
              Where-Object { $stock -notcontains $_.Name }

    if ($custom) {
        foreach ($p in $custom) {
            Copy-Item $p.FullName -Destination $dataOut -Force
            Write-Host "  + $($p.Name)  ($([math]::Round($p.Length/1KB,1)) KB)" -ForegroundColor Green
        }
    } else {
        Write-Host "  (none beyond the stock ChromieCraft archives)" -ForegroundColor DarkGray
    }
} else {
    Write-Warning "Client data folder not found at $clientData"
}

$count = (Get-ChildItem $PayloadDir -Recurse -File | Measure-Object).Count
$bytes = (Get-ChildItem $PayloadDir -Recurse -File | Measure-Object -Sum Length).Sum

Write-Host "`nPayload staged: $count files, $([math]::Round($bytes/1MB,1)) MB" -ForegroundColor Cyan
Write-Host "  $PayloadDir"
Write-Host "`nNext: .\New-Manifest.ps1 -BaseUrl https://raw.githubusercontent.com/OWNER/REPO/main/payload"
