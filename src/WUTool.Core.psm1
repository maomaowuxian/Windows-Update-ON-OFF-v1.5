# Windows Update ON/OFF v1.5 core
# Importing this module is side-effect free. System mutations only happen through
# Invoke-DisableWindowsUpdate or Invoke-RestoreWindowsUpdate.

Set-StrictMode -Version 2.0

function Get-WUToolServiceTargets {
    @(
        [pscustomobject]@{ Name = 'wuauserv'; ClearDelayedOnDisable = $false }
        [pscustomobject]@{ Name = 'BITS';     ClearDelayedOnDisable = $false }
        [pscustomobject]@{ Name = 'DoSvc';    ClearDelayedOnDisable = $true  }
        [pscustomobject]@{ Name = 'UsoSvc';   ClearDelayedOnDisable = $false }
    )
}

function Get-WUToolPolicyTargets {
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $au = Join-Path $wu 'AU'
    @(
        [pscustomobject]@{ Path = $wu; Name = 'DisableWindowsUpdateAccess';       DisabledValue = 1 }
        [pscustomobject]@{ Path = $wu; Name = 'ExcludeWUDriversInQualityUpdate'; DisabledValue = 1 }
        [pscustomobject]@{ Path = $au; Name = 'NoAutoUpdate';                    DisabledValue = 1 }
        [pscustomobject]@{ Path = $au; Name = 'NoAutoRebootWithLoggedOnUsers';   DisabledValue = 1 }
        [pscustomobject]@{ Path = $au; Name = 'NoAUShutdownOption';              DisabledValue = 1 }
        [pscustomobject]@{ Path = $au; Name = 'DetectionFrequencyEnabled';       DisabledValue = 0 }
    )
}

function Get-WUToolSafeRestoreProfiles {
    # Explicit conservative baseline for current Windows 10/11 when no backup exists.
    # It is deliberately described as a safe baseline, not an exact factory reset.
    @(
        [pscustomobject]@{ Name = 'wuauserv'; Start = 3; DelayedAutoStartExists = $false; DelayedAutoStart = $null }
        [pscustomobject]@{ Name = 'BITS';     Start = 3; DelayedAutoStartExists = $false; DelayedAutoStart = $null }
        [pscustomobject]@{ Name = 'DoSvc';    Start = 2; DelayedAutoStartExists = $true;  DelayedAutoStart = 1 }
        [pscustomobject]@{ Name = 'UsoSvc';   Start = 2; DelayedAutoStartExists = $true;  DelayedAutoStart = 1 }
    )
}

function Get-ServiceRegistryPath {
    param([Parameter(Mandatory = $true)][string]$Name)
    "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
}

function Convert-ServiceStartValueToText {
    param([object]$Start)
    if ($null -eq $Start) { return 'N/A' }
    switch ([int]$Start) {
        0 { 'Boot' }
        1 { 'System' }
        2 { 'Automatic' }
        3 { 'Manual' }
        4 { 'Disabled' }
        default { "Unknown($Start)" }
    }
}

function Get-RegistryValueSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $result = [ordered]@{ Path = $Path; Name = $Name; Exists = $false; Kind = $null; Value = $null }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$result }
    $key = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($key.GetValueNames() -contains $Name) {
        $result.Exists = $true
        $result.Kind = $key.GetValueKind($Name).ToString()
        $result.Value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    [pscustomobject]$result
}

function Convert-RegistryValueByKind {
    param([object]$Value, [string]$Kind)
    switch ($Kind) {
        'DWord'        { [int]$Value }
        'QWord'        { [long]$Value }
        'Binary'       { [byte[]]$Value }
        'MultiString'  { [string[]]$Value }
        'ExpandString' { [string]$Value }
        'String'       { [string]$Value }
        default        { $Value }
    }
}

function Restore-RegistryValueSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    $path = [string]$Snapshot.Path
    $name = [string]$Snapshot.Name
    if ([bool]$Snapshot.Exists) {
        New-Item -Path $path -Force -ErrorAction Stop | Out-Null
        $value = Convert-RegistryValueByKind -Value $Snapshot.Value -Kind ([string]$Snapshot.Kind)
        New-ItemProperty -LiteralPath $path -Name $name -Value $value `
            -PropertyType ([string]$Snapshot.Kind) -Force -ErrorAction Stop | Out-Null
    } elseif (Test-Path -LiteralPath $path) {
        Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction SilentlyContinue
    }
}

function Test-RegistrySnapshotRestored {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    $actual = Get-RegistryValueSnapshot -Path ([string]$Snapshot.Path) -Name ([string]$Snapshot.Name)
    if ([bool]$actual.Exists -ne [bool]$Snapshot.Exists) { return $false }
    if (-not [bool]$Snapshot.Exists) { return $true }
    if ([string]$actual.Kind -ne [string]$Snapshot.Kind) { return $false }
    $expected = Convert-RegistryValueByKind -Value $Snapshot.Value -Kind ([string]$Snapshot.Kind)
    (($actual.Value | ConvertTo-Json -Compress -Depth 8) -ceq ($expected | ConvertTo-Json -Compress -Depth 8))
}

function Get-ServiceRuntimeState {
    param([Parameter(Mandatory = $true)][string]$Name)
    try { [string](Get-Service -Name $Name -ErrorAction Stop).Status } catch { 'Unavailable' }
}

function Get-ServiceConfigSnapshot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Get-ServiceRegistryPath -Name $Name
    $result = [ordered]@{
        Name = $Name; Exists = $false; Start = $null
        DelayedAutoStartExists = $false; DelayedAutoStart = $null; WasRunning = $false
    }
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]$result }
    $key = Get-Item -LiteralPath $path -ErrorAction Stop
    $names = @($key.GetValueNames())
    if ($names -notcontains 'Start') { throw "Service $Name has no Start registry value." }
    $result.Exists = $true
    $result.Start = [int]$key.GetValue('Start')
    if ($names -contains 'DelayedAutoStart') {
        $result.DelayedAutoStartExists = $true
        $result.DelayedAutoStart = [int]$key.GetValue('DelayedAutoStart')
    }
    $result.WasRunning = ((Get-ServiceRuntimeState -Name $Name) -eq 'Running')
    [pscustomobject]$result
}

function Invoke-ServiceConfigCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateRange(0, 4)][int]$Start
    )
    $token = @('boot', 'system', 'auto', 'demand', 'disabled')[$Start]
    $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
    $output = & $sc config $Name 'start=' $token 2>&1
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config failed ($LASTEXITCODE): $($output -join ' ')" }
}

function Set-ServiceStartValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateRange(0, 4)][int]$Start
    )
    $path = Get-ServiceRegistryPath -Name $Name
    if (-not (Test-Path -LiteralPath $path)) { throw "Service $Name does not exist." }
    $warnings = @()
    try { Invoke-ServiceConfigCommand -Name $Name -Start $Start } catch { $warnings += $_.Exception.Message }

    # v1.2-style hard fallback: write the numeric Start value directly and verify it.
    New-ItemProperty -LiteralPath $path -Name 'Start' -Value $Start -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    $actual = [int](Get-ItemPropertyValue -LiteralPath $path -Name 'Start' -ErrorAction Stop)
    if ($actual -ne $Start) { throw "Service $Name Start expected $Start but read back $actual." }
    @($warnings)
}

function Set-DelayedAutoStartSnapshotValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$Exists,
        [object]$Value
    )
    $path = Get-ServiceRegistryPath -Name $Name
    if ($Exists) {
        New-ItemProperty -LiteralPath $path -Name 'DelayedAutoStart' -Value ([int]$Value) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $path -Name 'DelayedAutoStart' -Force -ErrorAction SilentlyContinue
    }
}

function Stop-ServiceBestEffort {
    param([Parameter(Mandatory = $true)][string]$Name, [int]$WaitSeconds = 8)
    $messages = @()
    try { Stop-Service -Name $Name -Force -ErrorAction Stop } catch {
        $messages += "Stop-Service: $($_.Exception.Message)"
        try {
            $sc = Join-Path $env:SystemRoot 'System32\sc.exe'
            $output = & $sc stop $Name 2>&1
            if ($LASTEXITCODE -ne 0) { $messages += "sc.exe stop ($LASTEXITCODE): $($output -join ' ')" }
        } catch { $messages += "sc.exe stop: $($_.Exception.Message)" }
    }
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $state = Get-ServiceRuntimeState -Name $Name
        if ($state -in @('Stopped', 'Unavailable')) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    [pscustomobject]@{ Name = $Name; State = (Get-ServiceRuntimeState -Name $Name); Messages = @($messages) }
}

function Disable-ServiceHard {
    param([Parameter(Mandatory = $true)][object]$Target)
    $name = [string]$Target.Name
    $messages = @()
    $before = Get-ServiceConfigSnapshot -Name $name
    if (-not $before.Exists) {
        return [pscustomobject]@{ Name = $name; Exists = $false; StartDisabled = $true; RuntimeState = 'Unavailable'; Messages = @('Service is not installed.') }
    }
    try { $messages += @(Set-ServiceStartValue -Name $name -Start 4) } catch { $messages += $_.Exception.Message }
    if ([bool]$Target.ClearDelayedOnDisable) {
        try { Set-DelayedAutoStartSnapshotValue -Name $name -Exists $true -Value 0 } catch { $messages += "DelayedAutoStart: $($_.Exception.Message)" }
    }
    $stop = Stop-ServiceBestEffort -Name $name
    $messages += @($stop.Messages)
    $after = Get-ServiceConfigSnapshot -Name $name
    [pscustomobject]@{
        Name = $name; Exists = [bool]$after.Exists
        StartDisabled = ([bool]$after.Exists -and [int]$after.Start -eq 4)
        RuntimeState = [string]$stop.State
        Messages = @($messages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}

function Restore-ServiceSnapshot {
    param([Parameter(Mandatory = $true)][object]$Snapshot)
    $name = [string]$Snapshot.Name
    $messages = @()
    if (-not [bool]$Snapshot.Exists) {
        return [pscustomobject]@{ Name = $name; ConfigRestored = $true; RuntimeState = 'Unavailable'; Messages = @() }
    }
    try { $messages += @(Set-ServiceStartValue -Name $name -Start ([int]$Snapshot.Start)) } catch { $messages += $_.Exception.Message }
    try {
        Set-DelayedAutoStartSnapshotValue -Name $name -Exists ([bool]$Snapshot.DelayedAutoStartExists) -Value $Snapshot.DelayedAutoStart
    } catch { $messages += "DelayedAutoStart: $($_.Exception.Message)" }

    try {
        $state = Get-ServiceRuntimeState -Name $name
        if ([bool]$Snapshot.WasRunning -and $state -ne 'Running') { Start-Service -Name $name -ErrorAction Stop }
        elseif (-not [bool]$Snapshot.WasRunning -and $state -eq 'Running') { Stop-Service -Name $name -Force -ErrorAction Stop }
    } catch { $messages += "Runtime state: $($_.Exception.Message)" }

    $after = Get-ServiceConfigSnapshot -Name $name
    $delayedOk = ([bool]$after.DelayedAutoStartExists -eq [bool]$Snapshot.DelayedAutoStartExists)
    if ($delayedOk -and [bool]$Snapshot.DelayedAutoStartExists) {
        $delayedOk = ([int]$after.DelayedAutoStart -eq [int]$Snapshot.DelayedAutoStart)
    }
    [pscustomobject]@{
        Name = $name
        ConfigRestored = ([bool]$after.Exists -and [int]$after.Start -eq [int]$Snapshot.Start -and $delayedOk)
        RuntimeState = (Get-ServiceRuntimeState -Name $name)
        Messages = @($messages | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}

function Restore-ServiceSafeProfile {
    param([Parameter(Mandatory = $true)][object]$Profile)
    $snapshot = [pscustomobject]@{
        Name = [string]$Profile.Name; Exists = $true; Start = [int]$Profile.Start
        DelayedAutoStartExists = [bool]$Profile.DelayedAutoStartExists
        DelayedAutoStart = $Profile.DelayedAutoStart; WasRunning = $false
    }
    Restore-ServiceSnapshot -Snapshot $snapshot
}

function Set-PolicyDwordBestEffort {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    try {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $actual = Get-RegistryValueSnapshot -Path $Path -Name $Name
        $ok = ([bool]$actual.Exists -and [string]$actual.Kind -eq 'DWord' -and [int]$actual.Value -eq $Value)
        [pscustomobject]@{ Name = $Name; Applied = $ok; Message = $(if ($ok) { $null } else { 'Immediate readback differs; hard-disable result is evaluated separately.' }) }
    } catch {
        [pscustomobject]@{ Name = $Name; Applied = $false; Message = $_.Exception.Message }
    }
}

function New-WUToolBackupState {
    param(
        [Parameter(Mandatory = $true)][object[]]$ServiceTargets,
        [Parameter(Mandatory = $true)][object[]]$PolicyTargets,
        [string]$ToolVersion = '1.5'
    )
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        ToolVersion = $ToolVersion
        ComputerName = $env:COMPUTERNAME
        CreatedAt = (Get-Date).ToString('o')
        Services = @($ServiceTargets | ForEach-Object { Get-ServiceConfigSnapshot -Name ([string]$_.Name) })
        Policies = @($PolicyTargets | ForEach-Object { Get-RegistryValueSnapshot -Path ([string]$_.Path) -Name ([string]$_.Name) })
    }
}

function Save-WUToolStateAtomically {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (Test-Path -LiteralPath $Path) { throw "Backup already exists: $Path" }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null }
    $temporary = "$Path.tmp"
    try {
        $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8 -Force -ErrorAction Stop
        [void](Get-Content -LiteralPath $temporary -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop)
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Load-WUToolState {
    param([Parameter(Mandatory = $true)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Assert-WUToolBackupState {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][object[]]$ServiceTargets,
        [Parameter(Mandatory = $true)][object[]]$PolicyTargets,
        [string]$ComputerName = $env:COMPUTERNAME
    )
    if ([int]$State.SchemaVersion -ne 1) { throw "Unsupported backup schema: $($State.SchemaVersion)" }
    if ([string]$State.ToolVersion -ne '1.5') { throw "Backup belongs to a different tool version: $($State.ToolVersion)" }
    if ([string]$State.ComputerName -ne $ComputerName) { throw "Backup belongs to another computer: $($State.ComputerName)" }
    foreach ($target in $ServiceTargets) {
        $match = @($State.Services | Where-Object { [string]$_.Name -eq [string]$target.Name })
        if ($match.Count -ne 1) { throw "Backup must contain exactly one service snapshot for $($target.Name)." }
    }
    foreach ($target in $PolicyTargets) {
        $match = @($State.Policies | Where-Object { [string]$_.Path -eq [string]$target.Path -and [string]$_.Name -eq [string]$target.Name })
        if ($match.Count -ne 1) { throw "Backup must contain exactly one policy snapshot for $($target.Path)\$($target.Name)." }
    }
}

function Get-OrCreateWUToolBackup {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][object[]]$ServiceTargets,
        [Parameter(Mandatory = $true)][object[]]$PolicyTargets
    )
    if (Test-Path -LiteralPath $StatePath) {
        $state = Load-WUToolState -Path $StatePath
        Assert-WUToolBackupState -State $state -ServiceTargets $ServiceTargets -PolicyTargets $PolicyTargets
        return [pscustomobject]@{ State = $state; Created = $false }
    }
    $state = New-WUToolBackupState -ServiceTargets $ServiceTargets -PolicyTargets $PolicyTargets
    Assert-WUToolBackupState -State $state -ServiceTargets $ServiceTargets -PolicyTargets $PolicyTargets
    Save-WUToolStateAtomically -State $state -Path $StatePath
    [pscustomobject]@{ State = $state; Created = $true }
}

function Invoke-DisableWindowsUpdate {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    $services = @(Get-WUToolServiceTargets)
    $policies = @(Get-WUToolPolicyTargets)

    # Backup is completed and validated before the first system mutation.
    $backup = Get-OrCreateWUToolBackup -StatePath $StatePath -ServiceTargets $services -PolicyTargets $policies
    $serviceResults = @($services | ForEach-Object { Disable-ServiceHard -Target $_ })
    $policyResults = @($policies | ForEach-Object {
        Set-PolicyDwordBestEffort -Path ([string]$_.Path) -Name ([string]$_.Name) -Value ([int]$_.DisabledValue)
    })
    $hardDisabled = (@($serviceResults | Where-Object { -not $_.StartDisabled }).Count -eq 0)
    $stopped = (@($serviceResults | Where-Object { $_.RuntimeState -notin @('Stopped', 'Unavailable') }).Count -eq 0)
    [pscustomobject]@{
        PrimarySuccess = $hardDisabled
        AllStopped = $stopped
        BackupCreated = [bool]$backup.Created
        ServiceResults = $serviceResults
        PolicyResults = $policyResults
    }
}

function Invoke-RestoreWindowsUpdate {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    $services = @(Get-WUToolServiceTargets)
    $policies = @(Get-WUToolPolicyTargets)
    $usedBackup = Test-Path -LiteralPath $StatePath
    $serviceResults = @()
    $policyResults = @()

    if ($usedBackup) {
        $state = Load-WUToolState -Path $StatePath
        Assert-WUToolBackupState -State $state -ServiceTargets $services -PolicyTargets $policies
        $serviceResults = @($state.Services | ForEach-Object { Restore-ServiceSnapshot -Snapshot $_ })
        $policyResults = @($state.Policies | ForEach-Object {
            $message = $null
            try { Restore-RegistryValueSnapshot -Snapshot $_ } catch { $message = $_.Exception.Message }
            $ok = $false
            if ($null -eq $message) { $ok = Test-RegistrySnapshotRestored -Snapshot $_ }
            if (-not $ok -and $null -eq $message) { $message = 'Readback does not match the saved value.' }
            [pscustomobject]@{ Name = [string]$_.Name; Restored = $ok; Message = $message }
        })
    } else {
        $serviceResults = @(Get-WUToolSafeRestoreProfiles | ForEach-Object { Restore-ServiceSafeProfile -Profile $_ })
        $policyResults = @($policies | ForEach-Object {
            $snapshot = [pscustomobject]@{ Path = $_.Path; Name = $_.Name; Exists = $false; Kind = $null; Value = $null }
            $message = $null
            try { Restore-RegistryValueSnapshot -Snapshot $snapshot } catch { $message = $_.Exception.Message }
            $ok = ($null -eq $message -and (Test-RegistrySnapshotRestored -Snapshot $snapshot))
            if (-not $ok -and $null -eq $message) { $message = 'Managed value is still present after removal.' }
            [pscustomobject]@{ Name = [string]$_.Name; Restored = $ok; Message = $message }
        })
    }

    $servicesOk = (@($serviceResults | Where-Object { -not $_.ConfigRestored }).Count -eq 0)
    $policiesOk = (@($policyResults | Where-Object { -not $_.Restored }).Count -eq 0)
    $consumed = $false
    if ($usedBackup -and $servicesOk -and $policiesOk) {
        Remove-Item -LiteralPath $StatePath -Force -ErrorAction Stop
        $consumed = $true
    }
    [pscustomobject]@{
        Success = ($servicesOk -and $policiesOk)
        UsedBackup = $usedBackup
        BackupConsumed = $consumed
        ServiceResults = $serviceResults
        PolicyResults = $policyResults
    }
}

function Get-WUToolStatus {
    param([Parameter(Mandatory = $true)][string]$StatePath)
    $services = @(Get-WUToolServiceTargets)
    $policies = @(Get-WUToolPolicyTargets)
    $backup = $null
    $backupError = $null
    if (Test-Path -LiteralPath $StatePath) {
        try {
            $backup = Load-WUToolState -Path $StatePath
            Assert-WUToolBackupState -State $backup -ServiceTargets $services -PolicyTargets $policies
        } catch { $backupError = $_.Exception.Message }
    }
    $serviceStatus = foreach ($target in $services) {
        $current = Get-ServiceConfigSnapshot -Name ([string]$target.Name)
        $original = $null
        if ($null -ne $backup) { $original = @($backup.Services | Where-Object { $_.Name -eq $target.Name })[0] }
        [pscustomobject]@{
            Name = [string]$target.Name
            RuntimeState = (Get-ServiceRuntimeState -Name ([string]$target.Name))
            Start = $current.Start
            StartText = (Convert-ServiceStartValueToText -Start $current.Start)
            DelayedAutoStart = $(if ($current.DelayedAutoStartExists) { [string]$current.DelayedAutoStart } else { '<missing>' })
            OriginalStart = $(if ($null -ne $original) { $original.Start } else { $null })
            OriginalStartText = $(if ($null -ne $original) { Convert-ServiceStartValueToText -Start $original.Start } else { 'No backup' })
        }
    }
    $policyStatus = foreach ($target in $policies) {
        $current = Get-RegistryValueSnapshot -Path ([string]$target.Path) -Name ([string]$target.Name)
        [pscustomobject]@{
            Path = [string]$target.Path; Name = [string]$target.Name
            Exists = [bool]$current.Exists; Value = $current.Value; Expected = [int]$target.DisabledValue
            Applied = ([bool]$current.Exists -and [string]$current.Kind -eq 'DWord' -and [int]$current.Value -eq [int]$target.DisabledValue)
        }
    }
    [pscustomobject]@{
        BackupExists = ($null -ne $backup)
        BackupError = $backupError
        BackupCreatedAt = $(if ($null -ne $backup) { [string]$backup.CreatedAt } else { $null })
        Services = @($serviceStatus)
        Policies = @($policyStatus)
    }
}

Export-ModuleMember -Function *
