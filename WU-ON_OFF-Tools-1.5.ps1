# Windows Update ON/OFF v1.5
# Simple GUI for repair burn-in / 72-hour stability test workflows.

#requires -version 5.1

Set-StrictMode -Version 2.0

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -WorkingDirectory $PSScriptRoot -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ToolVersion = '1.5'
$script:StatePath = Join-Path $PSScriptRoot 'WU-ON_OFF-Tools-1.5.state.json'
$script:LogPath = Join-Path $PSScriptRoot 'WU-ON_OFF-Tools-1.5.log'
$modulePath = Join-Path $PSScriptRoot 'src\WUTool.Core.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

[System.Windows.Forms.Application]::EnableVisualStyles()

function Add-UiLog {
    param([Parameter(Mandatory = $true)][string]$Text)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Text"
    if ($null -ne $script:LogBox) {
        $script:LogBox.AppendText("$line`r`n")
        $script:LogBox.SelectionStart = $script:LogBox.TextLength
        $script:LogBox.ScrollToCaret()
    }
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
}

function Show-Info {
    param([string]$Text, [string]$Title = 'Windows Update ON/OFF v1.5')
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Information')
}

function Show-Warning {
    param([string]$Text, [string]$Title = 'Windows Update ON/OFF v1.5')
    [void][System.Windows.Forms.MessageBox]::Show($Text, $Title, 'OK', 'Warning')
}

function Confirm-Action {
    param([string]$Text)
    [System.Windows.Forms.MessageBox]::Show($Text, 'Windows Update ON/OFF v1.5', 'YesNo', 'Warning') -eq [System.Windows.Forms.DialogResult]::Yes
}

function Set-Busy {
    param([bool]$Busy)
    $script:BtnDisable.Enabled = -not $Busy
    $script:BtnRestore.Enabled = -not $Busy
    $script:BtnRefresh.Enabled = -not $Busy
    $script:Form.UseWaitCursor = $Busy
    [System.Windows.Forms.Application]::DoEvents()
}

function Add-ResultMessages {
    param([object]$Result)
    foreach ($service in @($Result.ServiceResults)) {
        $flag = if ($service.PSObject.Properties['StartDisabled']) {
            "Start=4: $($service.StartDisabled)"
        } else {
            "config restored: $($service.ConfigRestored)"
        }
        Add-UiLog "Service $($service.Name): $flag; runtime=$($service.RuntimeState)"
        foreach ($message in @($service.Messages)) { Add-UiLog "  warning: $message" }
    }
    foreach ($policy in @($Result.PolicyResults)) {
        $ok = if ($policy.PSObject.Properties['Applied']) { $policy.Applied } else { $policy.Restored }
        Add-UiLog "Policy $($policy.Name): success=$ok"
        if (-not [string]::IsNullOrWhiteSpace([string]$policy.Message)) { Add-UiLog "  warning: $($policy.Message)" }
    }
}

function Refresh-Status {
    try {
        $status = Get-WUToolStatus -StatePath $script:StatePath
        $script:ServiceList.BeginUpdate()
        $script:ServiceList.Items.Clear()
        foreach ($service in $status.Services) {
            $start = if ($null -eq $service.Start) { 'N/A' } else { "$($service.Start) ($($service.StartText))" }
            $original = if ($null -eq $service.OriginalStart) { $service.OriginalStartText } else { "$($service.OriginalStart) ($($service.OriginalStartText))" }
            $item = New-Object System.Windows.Forms.ListViewItem([string]$service.Name)
            [void]$item.SubItems.Add([string]$service.RuntimeState)
            [void]$item.SubItems.Add($start)
            [void]$item.SubItems.Add([string]$service.DelayedAutoStart)
            [void]$item.SubItems.Add($original)
            if ($service.Start -eq 4) { $item.ForeColor = [System.Drawing.Color]::DarkRed }
            [void]$script:ServiceList.Items.Add($item)
        }
        $script:ServiceList.EndUpdate()

        $policyLines = foreach ($policy in $status.Policies) {
            $value = if ($policy.Exists) { [string]$policy.Value } else { '<missing>' }
            $mark = if ($policy.Applied) { 'OK' } else { '--' }
            "[$mark] $($policy.Name) = $value (disable expects $($policy.Expected))"
        }
        $backupText = if ($status.BackupExists) {
            "Backup: available, created $($status.BackupCreatedAt)"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$status.BackupError)) {
            "Backup: INVALID - $($status.BackupError)"
        } else {
            'Backup: none (Restore will use the documented safe baseline)'
        }
        $script:BackupLabel.Text = $backupText
        $script:PolicyBox.Text = ($policyLines -join "`r`n")
    } catch {
        Add-UiLog "Refresh failed: $($_.Exception.Message)"
        $script:BackupLabel.Text = "Status error: $($_.Exception.Message)"
    }
}

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Windows Update ON/OFF v1.5 - 维修烤机工具'
$script:Form.StartPosition = 'CenterScreen'
$script:Form.Size = New-Object System.Drawing.Size(900, 690)
$script:Form.MinimumSize = New-Object System.Drawing.Size(780, 620)
$script:Form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$intro = New-Object System.Windows.Forms.Label
$intro.AutoSize = $false
$intro.Location = New-Object System.Drawing.Point(14, 12)
$intro.Size = New-Object System.Drawing.Size(850, 42)
$intro.Text = "v1.5 hard-disables the four core update services. A Windows Update Settings page error after Disable is expected.`r`n禁用后 Windows Update 设置页报错属于预期现象；首次禁用前会保存原始服务与策略值。"
$script:Form.Controls.Add($intro)

$script:BtnDisable = New-Object System.Windows.Forms.Button
$script:BtnDisable.Text = 'Disable Windows Update'
$script:BtnDisable.Location = New-Object System.Drawing.Point(14, 62)
$script:BtnDisable.Size = New-Object System.Drawing.Size(240, 38)
$script:BtnDisable.BackColor = [System.Drawing.Color]::MistyRose
$script:Form.Controls.Add($script:BtnDisable)

$script:BtnRestore = New-Object System.Windows.Forms.Button
$script:BtnRestore.Text = 'Enable / Restore Windows Update'
$script:BtnRestore.Location = New-Object System.Drawing.Point(265, 62)
$script:BtnRestore.Size = New-Object System.Drawing.Size(270, 38)
$script:BtnRestore.BackColor = [System.Drawing.Color]::Honeydew
$script:Form.Controls.Add($script:BtnRestore)

$script:BtnRefresh = New-Object System.Windows.Forms.Button
$script:BtnRefresh.Text = 'Refresh Status'
$script:BtnRefresh.Location = New-Object System.Drawing.Point(546, 62)
$script:BtnRefresh.Size = New-Object System.Drawing.Size(160, 38)
$script:Form.Controls.Add($script:BtnRefresh)

$script:BackupLabel = New-Object System.Windows.Forms.Label
$script:BackupLabel.AutoSize = $false
$script:BackupLabel.Location = New-Object System.Drawing.Point(14, 108)
$script:BackupLabel.Size = New-Object System.Drawing.Size(850, 24)
$script:Form.Controls.Add($script:BackupLabel)

$serviceLabel = New-Object System.Windows.Forms.Label
$serviceLabel.Text = 'Core services / 核心服务'
$serviceLabel.Location = New-Object System.Drawing.Point(14, 136)
$serviceLabel.AutoSize = $true
$script:Form.Controls.Add($serviceLabel)

$script:ServiceList = New-Object System.Windows.Forms.ListView
$script:ServiceList.Location = New-Object System.Drawing.Point(14, 158)
$script:ServiceList.Size = New-Object System.Drawing.Size(850, 145)
$script:ServiceList.Anchor = 'Top,Left,Right'
$script:ServiceList.View = 'Details'
$script:ServiceList.FullRowSelect = $true
$script:ServiceList.GridLines = $true
[void]$script:ServiceList.Columns.Add('Service', 120)
[void]$script:ServiceList.Columns.Add('Runtime', 110)
[void]$script:ServiceList.Columns.Add('Current Start', 170)
[void]$script:ServiceList.Columns.Add('DelayedAutoStart', 150)
[void]$script:ServiceList.Columns.Add('Original Start', 200)
$script:Form.Controls.Add($script:ServiceList)

$policyLabel = New-Object System.Windows.Forms.Label
$policyLabel.Text = 'Managed policies / 策略状态'
$policyLabel.Location = New-Object System.Drawing.Point(14, 311)
$policyLabel.AutoSize = $true
$script:Form.Controls.Add($policyLabel)

$script:PolicyBox = New-Object System.Windows.Forms.TextBox
$script:PolicyBox.Location = New-Object System.Drawing.Point(14, 333)
$script:PolicyBox.Size = New-Object System.Drawing.Size(850, 132)
$script:PolicyBox.Anchor = 'Top,Left,Right'
$script:PolicyBox.Multiline = $true
$script:PolicyBox.ReadOnly = $true
$script:PolicyBox.ScrollBars = 'Vertical'
$script:PolicyBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$script:Form.Controls.Add($script:PolicyBox)

$logLabel = New-Object System.Windows.Forms.Label
$logLabel.Text = 'Log / 日志（同时写入工具目录）'
$logLabel.Location = New-Object System.Drawing.Point(14, 473)
$logLabel.AutoSize = $true
$script:Form.Controls.Add($logLabel)

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Location = New-Object System.Drawing.Point(14, 495)
$script:LogBox.Size = New-Object System.Drawing.Size(850, 145)
$script:LogBox.Anchor = 'Top,Bottom,Left,Right'
$script:LogBox.Multiline = $true
$script:LogBox.ReadOnly = $true
$script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 8.5)
$script:Form.Controls.Add($script:LogBox)

$script:BtnDisable.Add_Click({
    if (-not (Confirm-Action "Disable Windows Update now?`r`n`r`nThis stops and sets wuauserv, BITS, DoSvc and UsoSvc to Start=4. The original values are backed up first.")) { return }
    Set-Busy $true
    try {
        Add-UiLog 'Disable requested. Creating/validating the original-state backup before changes.'
        $result = Invoke-DisableWindowsUpdate -StatePath $script:StatePath
        Add-ResultMessages -Result $result
        if ($result.PrimarySuccess) {
            $policyWarnings = @($result.PolicyResults | Where-Object { -not $_.Applied }).Count
            Add-UiLog "Primary hard-disable succeeded. allStopped=$($result.AllStopped); policyWarnings=$policyWarnings"
            Show-Info "Core update services are hard-disabled (Start=4).`r`n`r`nWindows Update Settings may now show an error; this is expected.`r`nPolicy readback warnings, if any, are shown in the log and do not negate a successful hard-disable."
        } else {
            Show-Warning 'Hard-disable was incomplete. Review the service rows and log. The original-state backup has been retained.'
        }
    } catch {
        Add-UiLog "Disable aborted/failed: $($_.Exception.Message)"
        Show-Warning "Disable failed before or during hard-disable:`r`n$($_.Exception.Message)`r`n`r`nThe backup is retained when available."
    } finally {
        Refresh-Status
        Set-Busy $false
    }
})

$script:BtnRestore.Add_Click({
    $hasBackup = Test-Path -LiteralPath $script:StatePath
    $prompt = if ($hasBackup) {
        'Restore the exact original service Start/DelayedAutoStart values and managed policies from backup?'
    } else {
        "No backup exists.`r`n`r`nRestore will use the documented SAFE BASELINE (not an exact factory reset):`r`nwuauserv=Manual, BITS=Manual, DoSvc=Automatic/Delayed, UsoSvc=Automatic/Delayed; managed policy values will be removed.`r`n`r`nContinue?"
    }
    if (-not (Confirm-Action $prompt)) { return }
    Set-Busy $true
    try {
        Add-UiLog $(if ($hasBackup) { 'Exact restore requested.' } else { 'No backup: safe-baseline restore requested.' })
        $result = Invoke-RestoreWindowsUpdate -StatePath $script:StatePath
        Add-ResultMessages -Result $result
        if ($result.Success) {
            if ($result.UsedBackup) { Add-UiLog 'Exact restore succeeded; consumed backup removed.' }
            else { Add-UiLog 'Safe-baseline restore succeeded. This was not an exact factory reset.' }
            Show-Info $(if ($result.UsedBackup) { 'Windows Update configuration was restored exactly from the saved backup.' } else { 'Windows Update was restored to the documented safe baseline because no backup existed.' })
        } else {
            Show-Warning 'Restore was incomplete. Review the log. Any existing backup was retained.'
        }
    } catch {
        Add-UiLog "Restore failed: $($_.Exception.Message)"
        Show-Warning "Restore failed:`r`n$($_.Exception.Message)`r`n`r`nAny existing backup was retained."
    } finally {
        Refresh-Status
        Set-Busy $false
    }
})

$script:BtnRefresh.Add_Click({
    Add-UiLog 'Status refreshed (read-only).'
    Refresh-Status
})

$script:Form.Add_Shown({
    Add-UiLog 'Windows Update ON/OFF v1.5 opened. No update setting has been changed.'
    Refresh-Status
})

[void]$script:Form.ShowDialog()
