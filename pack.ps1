<#
.SYNOPSIS
    Builds dist\<folder>-<version>.zip from src\<folder>.

.DESCRIPTION
    Reads mod.json. The zip holds the mod folder at its root:

        ChiRenBlade\
            enabled.txt
            Scripts\main.lua
            Scripts\config.lua

    Extract that folder into <game>\platform\steam\ue4ss\Mods\.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\pack.ps1
#>
$ErrorActionPreference = "Stop"

$mod = Get-Content (Join-Path $PSScriptRoot "mod.json") -Raw | ConvertFrom-Json
$source = Join-Path $PSScriptRoot "src\$($mod.folder)"
if (-not (Test-Path (Join-Path $source "Scripts\main.lua"))) {
    throw "$source\Scripts\main.lua not found."
}

$dist = Join-Path $PSScriptRoot "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip = Join-Path $dist "$($mod.folder)-$($mod.version).zip"
if (Test-Path $zip) {
    Remove-Item $zip
}

Compress-Archive -Path $source -DestinationPath $zip -CompressionLevel Optimal
Write-Host "Packed $zip" -ForegroundColor Green
