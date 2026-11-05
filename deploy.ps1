<#
.SYNOPSIS
    Copies src\<folder> into the game's ue4ss\Mods\<folder>.

.DESCRIPTION
    Reads mod.json. The target is <game folder>\<win64Path>\ue4ss\Mods\<folder>.
    The game folder comes from -GameDir, else $env:UE5_GAMES_DIR\<gameFolder>.

    An existing Scripts\config.lua in the game stays (it holds your settings);
    -ResetConfig copies the shipped one over it.

    UE4SS loads Lua mods when the game starts, so a change shows after the next start.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy.ps1 -GameDir "D:\steam\steamapps\common\PBZ"
#>
param(
    [string]$GameDir,
    [string]$ModsDir,
    [switch]$ResetConfig
)

$ErrorActionPreference = "Stop"

$mod = Get-Content (Join-Path $PSScriptRoot "mod.json") -Raw | ConvertFrom-Json
$source = Join-Path $PSScriptRoot "src\$($mod.folder)"
if (-not (Test-Path (Join-Path $source "Scripts\main.lua"))) {
    throw "$source\Scripts\main.lua not found."
}

if (-not $ModsDir) {
    if (-not $GameDir) {
        if (-not $env:UE5_GAMES_DIR) {
            throw "The game folder is unknown: pass -GameDir or set UE5_GAMES_DIR."
        }
        $GameDir = Join-Path $env:UE5_GAMES_DIR $mod.gameFolder
    }
    $ue4ss = Join-Path (Join-Path $GameDir $mod.win64Path) "ue4ss"
    if (-not (Test-Path (Join-Path $ue4ss "UE4SS.dll"))) {
        throw "UE4SS is not installed in the game ($ue4ss\UE4SS.dll is missing)."
    }
    $ModsDir = Join-Path $ue4ss "Mods"
}

$target = Join-Path $ModsDir $mod.folder
$keepConfig = (-not $ResetConfig) -and (Test-Path (Join-Path $target "Scripts\config.lua"))
$options = @("/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
if ($keepConfig) {
    $options += @("/XF", "config.lua")
}

robocopy $source $target @options | Out-Null
$code = $LASTEXITCODE
if ($code -ge 8) {
    throw "robocopy failed with exit code $code"
}
if ($code -eq 0) {
    Write-Host "Already up to date: $target" -ForegroundColor Green
} else {
    Write-Host "Deployed $($mod.name) $($mod.version) to $target (active from the next game start)" -ForegroundColor Green
}
if ($keepConfig) {
    Write-Host "Kept the game's Scripts\config.lua; -ResetConfig copies the shipped one."
}
exit 0
