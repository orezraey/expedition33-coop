<#
Applies the patches from ApplyCoopPatches in Program.cs (ControlRestorePatch.cs, RandomAssignmentPatch.cs, GamepadUiPatch.cs) to an
already installed (released) build of the mod.

Requires retoc.exe (https://github.com/trumank/retoc) and the .NET SDK.
The patched container is written to -OutputDir; copy it into Paks\~mods yourself after backing up the original files.

Example:
  .\scripts\Patch-InstalledMod.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Expedition 33" -Retoc .\retoc.exe -OutputDir .\patched

-ModSource is the folder with the unpatched expedition33_coop_P.* files (default: the game's Paks\~mods). Point it at a backup of the
original files when the installed mod is already patched.
#>
param(
    [Parameter(Mandatory)] [string] $GameDir,
    [Parameter(Mandatory)] [string] $Retoc,
    [Parameter(Mandatory)] [string] $OutputDir,
    [string] $ModSource
)
$ErrorActionPreference = 'Stop'

$repo = Split-Path $PSScriptRoot -Parent
$GameDir = (Resolve-Path $GameDir).Path
$paks = Join-Path $GameDir 'Sandfall\Content\Paks'
$mods = Join-Path $paks '~mods'
$Retoc = (Resolve-Path $Retoc).Path
if (-not $ModSource) { $ModSource = $mods }
$ModSource = (Resolve-Path $ModSource).Path
if (-not (Test-Path (Join-Path $ModSource 'expedition33_coop_P.utoc'))) { throw "The coop mod is not in $ModSource" }

# the game mounts every container below Paks, so never write the output (or a backup) there
$OutputDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
if (($OutputDir.TrimEnd('\') + '\').StartsWith($paks + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDir must not be inside $paks; copy the files into ~mods after backing up the originals"
}

# the mod's hooked game blueprints can only be converted when the game's containers are next to it,
# so build a container directory out of hard links (same volume as the game) and fall back to copies
$work = Join-Path ([IO.Path]::GetPathRoot($GameDir)) "expedition33-coop-patch-$PID"
$containers = Join-Path $work 'paks'
$legacy = Join-Path $work 'legacy'
New-Item -ItemType Directory -Force $containers | Out-Null
try {
    $files = @(Get-ChildItem $paks -File) + @(Get-ChildItem $ModSource -File -Filter 'expedition33_coop_P.*')
    foreach ($file in $files) {
        $link = Join-Path $containers $file.Name
        try {
            New-Item -ItemType HardLink -Path $link -Target $file.FullName -ErrorAction Stop | Out-Null
        } catch {
            Copy-Item $file.FullName $link
        }
    }

    $assets = @(
        'Coop/CoopConfig', 'Coop/CoopController', 'Coop/ModActor', 'Coop/ModDebugWidget', 'Coop/ModLibrary', 'Coop/PlayerIndicator', 'Coop/UserSwitchWidget',
        'jRPGTemplate/Blueprints/Basics/BP_jRPG_Character_Battle_Base', 'jRPGTemplate/Blueprints/Basics/BP_jRPG_Controller_World',
        'jRPGTemplate/Blueprints/Basics/BP_jRPG_GM_World', 'UI/Widgets/MainMenu/WBP_MM_MainMenu',
        'UI/Widgets/InGame_Menu/Team/WBP_TeamCard_CharacterStatus', 'UI/Widgets/InGame_Menu/Team/CharacterSelector/WBP_CharacterCardButton',
        'UI/Widgets/InGame_Menu/Settings/OptionsList/WBP_Settings_GeneralOptionsList'
    )
    $filters = $assets | ForEach-Object { '--filter'; "$_.uasset" }
    & $Retoc to-legacy $containers $legacy --version UE5_4 @filters
    if ($LASTEXITCODE -ne 0) { throw "retoc to-legacy failed with $LASTEXITCODE" }
    Remove-Item (Join-Path $legacy 'scriptobjects.bin') -ErrorAction SilentlyContinue

    # name filters also match similarly named game assets, keep only the mod's own
    $keep = $assets | ForEach-Object { (Join-Path $legacy "Sandfall/Content/$_").Replace('/', '\') }
    Get-ChildItem $legacy -Recurse -File | Where-Object { $keep -notcontains (Join-Path $_.DirectoryName $_.BaseName) } | Remove-Item
    foreach ($asset in $keep) {
        if (-not (Test-Path "$asset.uasset")) { throw "Missing $asset.uasset in the installed mod" }
    }

    Push-Location $repo
    try {
        dotnet run --project Expedition33Coop.csproj -c Release -- patch-legacy (Join-Path $legacy 'Sandfall\Content')
        if ($LASTEXITCODE -ne 0) { throw "patch-legacy failed with $LASTEXITCODE" }
    } finally { Pop-Location }

    New-Item -ItemType Directory -Force $OutputDir | Out-Null
    & $Retoc to-zen $legacy (Join-Path $OutputDir 'expedition33_coop_P.utoc') --version UE5_4
    if ($LASTEXITCODE -ne 0) { throw "retoc to-zen failed with $LASTEXITCODE" }
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "Patched mod written to $OutputDir"
