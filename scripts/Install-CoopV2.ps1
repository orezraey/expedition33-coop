<#
.SYNOPSIS
Installs or updates the E33CoopV2 UE4SS runtime mod into Clair Obscur: Expedition 33.

.DESCRIPTION
Deploys ue4ss\Mods\E33CoopV2 into <GameDir>\Sandfall\Binaries\Win64\ue4ss\Mods\E33CoopV2,
preserves any existing config.json, and enables E33CoopV2 in mods.txt.

Optionally pass -BasePakDir pointing to a folder containing the UNPATCHED upstream
expedition33_coop_P.{pak,ucas,utoc} files to install/restore them cleanly into Paks\~mods.

.EXAMPLE
  .\scripts\Install-CoopV2.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Expedition 33"

.EXAMPLE
  .\scripts\Install-CoopV2.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Expedition 33" -BasePakDir "C:\backups\coop-upstream"
#>
param(
    [Parameter(Mandatory)]
    [string] $GameDir,

    [string] $BasePakDir,

    [switch] $DisableDiag
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$sourceMod = Join-Path $repoRoot 'ue4ss\Mods\E33CoopV2'
if (-not (Test-Path (Join-Path $sourceMod 'Scripts\main.lua'))) {
    throw "Missing source mod at $sourceMod"
}

$GameDir = (Resolve-Path $GameDir).Path
$ue4ssDir = Join-Path $GameDir 'Sandfall\Binaries\Win64\ue4ss'
$modsDir = Join-Path $ue4ssDir 'Mods'
$paksModsDir = Join-Path $GameDir 'Sandfall\Content\Paks\~mods'

if (-not (Test-Path $modsDir)) {
    throw "UE4SS Mods directory not found at $modsDir. Install UE4SS first."
}

# Optional: restore/install clean unpatched upstream base .utoc/.ucas/.pak
if ($BasePakDir) {
    $BasePakDir = (Resolve-Path $BasePakDir).Path
    $baseFiles = Get-ChildItem $BasePakDir -File -Filter 'expedition33_coop_P.*'
    if ($baseFiles.Count -lt 3) {
        throw "Expected expedition33_coop_P.{pak,ucas,utoc} in $BasePakDir"
    }
    New-Item -ItemType Directory -Force $paksModsDir | Out-Null
    foreach ($f in $baseFiles) {
        Copy-Item $f.FullName (Join-Path $paksModsDir $f.Name) -Force
    }
    Write-Host "Installed clean base coop pak files from $BasePakDir into $paksModsDir"
}

if (-not (Test-Path (Join-Path $paksModsDir 'expedition33_coop_P.utoc'))) {
    Write-Warning "Base mod expedition33_coop_P.utoc not found in $paksModsDir. E33CoopV2 requires the unpatched base coop mod assets."
}

# Deploy UE4SS Lua scripts while preserving existing config.json
$targetMod = Join-Path $modsDir 'E33CoopV2'
$targetScripts = Join-Path $targetMod 'Scripts'
New-Item -ItemType Directory -Force $targetMod | Out-Null

if (Test-Path $targetScripts) {
    Remove-Item $targetScripts -Recurse -Force
}
Copy-Item (Join-Path $sourceMod 'Scripts') $targetScripts -Recurse -Force
Copy-Item (Join-Path $sourceMod 'enabled.txt') (Join-Path $targetMod 'enabled.txt') -Force

# Update mods.txt cleanly (keep Keybinds at the bottom as required by UE4SS)
$modsTxt = Join-Path $modsDir 'mods.txt'
if (Test-Path $modsTxt) {
    $lines = [System.Collections.Generic.List[string]]::new([string[]](Get-Content $modsTxt))
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*E33CoopV2\s*:') {
            $lines[$i] = 'E33CoopV2 : 1'
            $found = $true
        }
        if ($DisableDiag -and $lines[$i] -match '^\s*E33CoopDiag\s*:') {
            $lines[$i] = 'E33CoopDiag : 0'
        }
    }
    if (-not $found) {
        $insertAt = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*Keybinds\s*:') {
                $insertAt = $i
                break
            }
            $insertAt = $i + 1
        }
        $lines.Insert($insertAt, 'E33CoopV2 : 1')
    }
    Set-Content -Path $modsTxt -Value $lines -Encoding UTF8
} else {
    Set-Content -Path $modsTxt -Value @('E33CoopV2 : 1', '', '; Built-in keybinds, do not move up!', 'Keybinds : 1') -Encoding UTF8
}

Write-Host ""
Write-Host "E33CoopV2 installed successfully!" -ForegroundColor Green
Write-Host "  Mod scripts : $targetScripts"
Write-Host "  Config file : $(Join-Path $targetMod 'config.json') (created on first run, preserved across updates)"
Write-Host "  UE4SS log   : $(Join-Path $ue4ssDir 'UE4SS.log')"
