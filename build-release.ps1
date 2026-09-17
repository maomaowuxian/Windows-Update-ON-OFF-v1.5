# Build a directly usable script release. No network access or external module is required.

#requires -version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$releaseRoot = Join-Path $projectRoot 'release'
$packageName = 'Windows-Update-ON-OFF-v1.5'
$packageDir = Join-Path $releaseRoot $packageName
$zipPath = Join-Path $releaseRoot "$packageName.zip"

if (-not (Test-Path -LiteralPath $releaseRoot)) {
    New-Item -ItemType Directory -Path $releaseRoot -Force | Out-Null
}
if (Test-Path -LiteralPath $packageDir) { Remove-Item -LiteralPath $packageDir -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

New-Item -ItemType Directory -Path (Join-Path $packageDir 'src') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $projectRoot 'WU-ON_OFF-Tools-1.5.ps1') -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $projectRoot '点我运行.bat') -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') -Destination $packageDir
Copy-Item -LiteralPath (Join-Path $projectRoot 'src\WUTool.Core.psm1') -Destination (Join-Path $packageDir 'src')

Compress-Archive -LiteralPath $packageDir -DestinationPath $zipPath -CompressionLevel Optimal
$hash = Get-FileHash -LiteralPath $zipPath -Algorithm SHA256
Write-Host "Release directory: $packageDir"
Write-Host "ZIP: $zipPath"
Write-Host "SHA256: $($hash.Hash)"
