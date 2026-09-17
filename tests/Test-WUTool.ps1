# Side-effect-safe test suite for Windows Update ON/OFF v1.5.
# It never calls Invoke-DisableWindowsUpdate or Invoke-RestoreWindowsUpdate.

#requires -version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Failed = 0

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "PASS  $Name" -ForegroundColor Green
        $script:Passed++
    } catch {
        Write-Host "FAIL  $Name -- $($_.Exception.Message)" -ForegroundColor Red
        $script:Failed++
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'src\WUTool.Core.psm1'
$guiPath = Join-Path $root 'WU-ON_OFF-Tools-1.5.ps1'
$buildPath = Join-Path $root 'build-release.ps1'

Test-Case 'PowerShell syntax parses without errors' {
    foreach ($path in @($modulePath, $guiPath, $PSCommandPath, $buildPath)) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        Assert-True ($errors.Count -eq 0) "$path has parser errors: $($errors -join '; ')"
    }
}

Import-Module -Name $modulePath -Force

Test-Case 'Managed target sets are complete and unique' {
    $services = @(Get-WUToolServiceTargets)
    $policies = @(Get-WUToolPolicyTargets)
    Assert-True ($services.Count -eq 4) 'Expected four core services.'
    Assert-True (@($services.Name | Sort-Object -Unique).Count -eq 4) 'Service names are not unique.'
    foreach ($name in @('wuauserv', 'BITS', 'DoSvc', 'UsoSvc')) {
        Assert-True ($services.Name -contains $name) "Missing service $name."
    }
    Assert-True ($policies.Count -eq 6) 'Expected six policy values.'
    foreach ($name in @('DisableWindowsUpdateAccess','ExcludeWUDriversInQualityUpdate','NoAutoUpdate','NoAutoRebootWithLoggedOnUsers','NoAUShutdownOption','DetectionFrequencyEnabled')) {
        Assert-True ($policies.Name -contains $name) "Missing policy $name."
    }
}

Test-Case 'Service Start text conversion is stable' {
    Assert-True ((Convert-ServiceStartValueToText 2) -eq 'Automatic') 'Start=2 mismatch.'
    Assert-True ((Convert-ServiceStartValueToText 3) -eq 'Manual') 'Start=3 mismatch.'
    Assert-True ((Convert-ServiceStartValueToText 4) -eq 'Disabled') 'Start=4 mismatch.'
    Assert-True ((Convert-ServiceStartValueToText $null) -eq 'N/A') 'Null mismatch.'
}

Test-Case 'No-backup safe restore profile is explicit' {
    $profiles = @(Get-WUToolSafeRestoreProfiles)
    $expected = @{ wuauserv = 3; BITS = 3; DoSvc = 2; UsoSvc = 2 }
    Assert-True ($profiles.Count -eq 4) 'Expected four safe profiles.'
    foreach ($profile in $profiles) {
        Assert-True ($expected[[string]$profile.Name] -eq [int]$profile.Start) "Unexpected safe Start for $($profile.Name)."
    }
    $doSvc = @($profiles | Where-Object Name -eq 'DoSvc')[0]
    Assert-True ($doSvc.DelayedAutoStartExists -and [int]$doSvc.DelayedAutoStart -eq 1) 'DoSvc delayed baseline mismatch.'
}

Test-Case 'Synthetic backup validation accepts exact coverage' {
    $services = @(Get-WUToolServiceTargets)
    $policies = @(Get-WUToolPolicyTargets)
    $state = [pscustomobject]@{
        SchemaVersion = 1; ToolVersion = '1.5'; ComputerName = 'TEST-PC'; CreatedAt = '2026-01-01T00:00:00Z'
        Services = @($services | ForEach-Object { [pscustomobject]@{ Name=$_.Name; Exists=$true; Start=3; DelayedAutoStartExists=$false; DelayedAutoStart=$null; WasRunning=$false } })
        Policies = @($policies | ForEach-Object { [pscustomobject]@{ Path=$_.Path; Name=$_.Name; Exists=$false; Kind=$null; Value=$null } })
    }
    Assert-WUToolBackupState -State $state -ServiceTargets $services -PolicyTargets $policies -ComputerName 'TEST-PC'
}

Test-Case 'Synthetic backup validation rejects missing coverage' {
    $services = @(Get-WUToolServiceTargets)
    $policies = @(Get-WUToolPolicyTargets)
    $state = [pscustomobject]@{ SchemaVersion=1; ComputerName='TEST-PC'; Services=@(); Policies=@() }
    $threw = $false
    try { Assert-WUToolBackupState -State $state -ServiceTargets $services -PolicyTargets $policies -ComputerName 'TEST-PC' } catch { $threw = $true }
    Assert-True $threw 'Malformed backup should have been rejected.'
}

Test-Case 'Atomic state save/load works in a temporary directory' {
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("wu-tool-v15-test-" + [guid]::NewGuid().ToString('N'))
    $statePath = Join-Path $tempRoot 'state.json'
    try {
        $state = [pscustomobject]@{ SchemaVersion=1; ToolVersion='1.5'; ComputerName='TEST-PC'; Services=@(); Policies=@() }
        Save-WUToolStateAtomically -State $state -Path $statePath
        $loaded = Load-WUToolState -Path $statePath
        Assert-True ($loaded.ToolVersion -eq '1.5') 'State round-trip failed.'
        Assert-True (-not (Test-Path -LiteralPath "$statePath.tmp")) 'Temporary state file was left behind.'
    } finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

Test-Case 'Registry snapshots round-trip only inside temporary HKCU' {
    $testPath = "HKCU:\Software\Codex-WUTool-v15-Test-$([guid]::NewGuid().ToString('N'))"
    try {
        $missing = Get-RegistryValueSnapshot -Path $testPath -Name 'Probe'
        Assert-True (-not $missing.Exists) 'Initial value unexpectedly exists.'
        New-Item -Path $testPath -Force | Out-Null
        New-ItemProperty -Path $testPath -Name 'Probe' -PropertyType DWord -Value 7 -Force | Out-Null
        $present = Get-RegistryValueSnapshot -Path $testPath -Name 'Probe'
        Set-ItemProperty -Path $testPath -Name 'Probe' -Value 99
        Restore-RegistryValueSnapshot -Snapshot $present
        Assert-True (Test-RegistrySnapshotRestored -Snapshot $present) 'Existing DWORD was not restored exactly.'
        Restore-RegistryValueSnapshot -Snapshot $missing
        Assert-True (Test-RegistrySnapshotRestored -Snapshot $missing) 'Originally absent value was not removed.'
    } finally {
        if (Test-Path -LiteralPath $testPath) { Remove-Item -LiteralPath $testPath -Recurse -Force }
    }
}

Test-Case 'Registry writes do not use unsupported Set-ItemProperty -Type' {
    $coreText = Get-Content -LiteralPath $modulePath -Raw
    $bad = [regex]::Matches($coreText, '(?im)\bSet-ItemProperty\b[^\r\n]*\s-Type\s')
    Assert-True ($bad.Count -eq 0) 'Set-ItemProperty does not support -Type on Windows PowerShell 5.1.'
}
Test-Case 'Test suite contains no Disable or Restore invocation' {
    $text = Get-Content -LiteralPath $PSCommandPath -Raw
    $unsafeCalls = [regex]::Matches($text, '(?m)^\s*(Invoke-DisableWindowsUpdate|Invoke-RestoreWindowsUpdate)\s')
    Assert-True ($unsafeCalls.Count -eq 0) 'The test suite contains a mutating entry-point call.'
}

Write-Host "`nResult: $script:Passed passed, $script:Failed failed"
if ($script:Failed -ne 0) { exit 1 }
