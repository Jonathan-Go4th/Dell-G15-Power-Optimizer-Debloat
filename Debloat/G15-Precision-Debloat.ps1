#requires -Version 5.1

<#
.SYNOPSIS
    Reversible, inventory-driven debloat for a Dell G15 5530 running Windows 11.

.DESCRIPTION
    This script targets active optional components found in the audit:
      * Reports the OEM-protected Intel Graphics Software service but leaves it unchanged
      * NVIDIA App background container/PresentMon (not the display driver or Control Panel container)
      * Windows cross-device resume, consumer-content promotion, Recall, and Click to Do
      * Two nonessential Office background tasks; protected Windows tasks are reported but not modified

    It does not remove Appx packages, drivers, services, scheduled tasks, or user data.
    Apply creates a complete state backup before changing anything. Restore replays that state.

.EXAMPLE
    .\G15-Precision-Debloat.ps1 -Preview

.EXAMPLE
    .\G15-Precision-Debloat.ps1 -Apply

.EXAMPLE
    .\G15-Precision-Debloat.ps1 -Diagnose

.EXAMPLE
    .\G15-Precision-Debloat.ps1 -RestoreLatest
#>

[CmdletBinding(DefaultParameterSetName = 'Preview')]
param(
    [Parameter(ParameterSetName = 'Preview')]
    [switch]$Preview,

    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [switch]$Apply,

    [Parameter(Mandatory, ParameterSetName = 'Diagnose')]
    [switch]$Diagnose,

    [Parameter(Mandatory, ParameterSetName = 'RestoreLatest')]
    [switch]$RestoreLatest,

    [Parameter(Mandatory, ParameterSetName = 'RestoreFrom')]
    [ValidateNotNullOrEmpty()]
    [string]$RestoreFrom,

    # Keeps the NVIDIA App service running. The NVIDIA display driver and
    # NVDisplay.ContainerLocalSystem are always preserved regardless.
    [Parameter(ParameterSetName = 'Preview')]
    [Parameter(ParameterSetName = 'Apply')]
    [switch]$KeepNvidiaApp
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.2'
$StateRoot = Join-Path $env:ProgramData 'G15-Precision-Debloat'

$ProtectedServiceNotes = @(
    [pscustomobject]@{
        Name        = 'IntelGraphicsSoftwareService'
        Reason      = 'OEM-protected on this machine (Access denied even when elevated); deliberately left unchanged.'
    }
)

$ServiceTargets = @()

if (-not $KeepNvidiaApp) {
    $ServiceTargets += [pscustomobject]@{
        Name        = 'NvContainerLocalSystem'
        StartupType = 'Manual'
        Stop        = $true
        Reason      = 'NVIDIA App backend/overlay. The display driver and NVDisplay.ContainerLocalSystem are preserved.'
    }
}

$TaskTargets = @(
    [pscustomobject]@{
        Path   = '\Microsoft\Office\'
        Name   = 'Office Actions Server'
        Reason = 'Optional Office actions/background integration; core Office and update tasks are preserved.'
    },
    [pscustomobject]@{
        Path   = '\Microsoft\Office\'
        Name   = 'Office Background Push Maintenance'
        Reason = 'Optional Office background push maintenance; Office automatic updates are preserved.'
    }
)

$ProtectedTaskNotes = @(
    [pscustomobject]@{
        Path   = '\Microsoft\Windows\UsageAndQualityInsights\'
        Name   = 'UsageAndQualityInsights-MaintenanceTask'
        Reason = 'Windows-protected on this machine; left unchanged. Its associated service is already disabled.'
    },
    [pscustomobject]@{
        Path   = '\Microsoft\Windows\WindowsAI\ClickToDo\'
        Name   = 'ModelCachingLimit'
        Reason = 'Windows-protected on this machine; left unchanged. Click to Do is already disabled by policy.'
    },
    [pscustomobject]@{
        Path   = '\Microsoft\Windows\WindowsAI\ClickToDo\'
        Name   = 'ModelCachingUpdate'
        Reason = 'Windows-protected on this machine; left unchanged. Click to Do is already disabled by policy.'
    }
)

# These are documented Windows policy values, not undocumented tuning knobs.
$RegistryTargets = @(
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        Name   = 'EnableCdp'
        Type   = 'DWord'
        Value  = 0
        Reason = 'Disable cross-device/Continue experiences; prevents the observed CrossDeviceResume workload after reboot.'
    },
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        Name   = 'DisableWindowsConsumerFeatures'
        Type   = 'DWord'
        Value  = 1
        Reason = 'Disable Microsoft consumer-feature promotion and suggested app provisioning.'
    },
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        Name   = 'DisableConsumerAccountStateContent'
        Type   = 'DWord'
        Value  = 1
        Reason = 'Disable cloud consumer-account promotional content in Windows experiences.'
    },
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'
        Name   = 'DisabledByGroupPolicy'
        Type   = 'DWord'
        Value  = 1
        Reason = 'Disable the Windows advertising identifier.'
    },
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
        Name   = 'DisableClickToDo'
        Type   = 'DWord'
        Value  = 1
        Reason = 'Disable Click to Do and its entry points.'
    },
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
        Name   = 'AllowRecallEnablement'
        Type   = 'DWord'
        Value  = 0
        Reason = 'Keep Windows Recall unavailable.'
    },
    [pscustomobject]@{
        Path   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
        Name   = 'DisableAIDataAnalysis'
        Type   = 'DWord'
        Value  = 1
        Reason = 'Turn off saving snapshots for Recall.'
    }
)

function Write-Section {
    param([Parameter(Mandatory)][string]$Title)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host (' {0}' -f $Title) -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        throw 'This action requires an elevated PowerShell window (Run as administrator).'
    }
}

function Get-ServiceStartupType {
    param([Parameter(Mandatory)][string]$Name)

    $escaped = $Name.Replace("'", "''")
    $item = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escaped'" -ErrorAction Stop
    switch ($item.StartMode) {
        'Auto'     { return 'Automatic' }
        'Manual'   { return 'Manual' }
        'Disabled' { return 'Disabled' }
        default    { return [string]$item.StartMode }
    }
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $state = [ordered]@{
        Path        = $Path
        Name        = $Name
        ValueExists = $false
        Value       = $null
        Kind        = $null
    }

    if (Test-Path -LiteralPath $Path) {
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $state.ValueExists = $true
            $state.Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $state.Kind = $key.GetValueKind($Name).ToString()
        }
    }

    return [pscustomobject]$state
}

function Get-TaskOrNull {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    # Loading Task Scheduler through CIM can pause for several seconds on the
    # first call. Cache one complete snapshot instead of issuing many separate
    # provider calls during Preview, backup, and Apply.
    if (-not $script:TaskCacheLoaded) {
        $script:TaskCache = @(Get-ScheduledTask -ErrorAction Stop)
        $script:TaskCacheLoaded = $true
    }

    return $script:TaskCache |
        Where-Object { ($_.TaskPath -eq $Path) -and ($_.TaskName -eq $Name) } |
        Select-Object -First 1
}

function Clear-TaskCache {
    $script:TaskCache = @()
    $script:TaskCacheLoaded = $false
}

$script:TaskCache = @()
$script:TaskCacheLoaded = $false

function New-StateBackup {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $directory = Join-Path $StateRoot $stamp
    New-Item -Path $directory -ItemType Directory -Force | Out-Null

    $services = foreach ($target in $ServiceTargets) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            [pscustomobject]@{ Name = $target.Name; Exists = $false }
            continue
        }

        $serviceKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $target.Name
        $delayedState = Get-RegistryValueState -Path $serviceKey -Name 'DelayedAutoStart'
        [pscustomobject]@{
            Name             = $target.Name
            Exists           = $true
            StartupType      = Get-ServiceStartupType -Name $target.Name
            Status           = $service.Status.ToString()
            DelayedAutoState = $delayedState
        }
    }

    $tasks = foreach ($target in $TaskTargets) {
        $task = Get-TaskOrNull -Path $target.Path -Name $target.Name
        [pscustomobject]@{
            Path    = $target.Path
            Name    = $target.Name
            Exists  = ($null -ne $task)
            Enabled = if ($null -ne $task) { [bool]$task.Settings.Enabled } else { $null }
        }
    }

    $registry = foreach ($target in $RegistryTargets) {
        Get-RegistryValueState -Path $target.Path -Name $target.Name
    }

    $state = [pscustomobject]@{
        SchemaVersion = 1
        ScriptVersion = $ScriptVersion
        CreatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        ComputerName  = $env:COMPUTERNAME
        UserName      = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Services      = @($services)
        Tasks         = @($tasks)
        Registry      = @($registry)
    }

    $stateFile = Join-Path $directory 'state.xml'
    $state | Export-Clixml -LiteralPath $stateFile -Depth 8

    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        throw 'State backup verification failed; no changes were made.'
    }

    return $stateFile
}

function Set-RegistryTarget {
    param([Parameter(Mandatory)]$Target)

    if (-not (Test-Path -LiteralPath $Target.Path)) {
        New-Item -Path $Target.Path -Force | Out-Null
    }

    New-ItemProperty -LiteralPath $Target.Path -Name $Target.Name -PropertyType $Target.Type `
        -Value $Target.Value -Force | Out-Null
}

function Restore-RegistryState {
    param([Parameter(Mandatory)]$Item)

    if ($Item.ValueExists) {
        if (-not (Test-Path -LiteralPath $Item.Path)) {
            New-Item -Path $Item.Path -Force | Out-Null
        }
        New-ItemProperty -LiteralPath $Item.Path -Name $Item.Name -PropertyType $Item.Kind `
            -Value $Item.Value -Force | Out-Null
    }
    elseif (Test-Path -LiteralPath $Item.Path) {
        Remove-ItemProperty -LiteralPath $Item.Path -Name $Item.Name -ErrorAction SilentlyContinue
    }
}

function Restore-State {
    param(
        [Parameter(Mandatory)][string]$StateFile,
        [switch]$Quiet
    )

    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) {
        throw "Restore state not found: $StateFile"
    }

    $state = Import-Clixml -LiteralPath $StateFile
    if ($state.SchemaVersion -ne 1) {
        throw "Unsupported restore-state schema: $($state.SchemaVersion)"
    }
    if ($state.ComputerName -ne $env:COMPUTERNAME) {
        throw "This state belongs to computer '$($state.ComputerName)', not '$env:COMPUTERNAME'."
    }

    foreach ($item in $state.Registry) {
        Restore-RegistryState -Item $item
    }

    foreach ($item in $state.Tasks) {
        if (-not $item.Exists) { continue }
        $task = Get-TaskOrNull -Path $item.Path -Name $item.Name
        if ($null -eq $task) {
            Write-Warning "Cannot restore missing task: $($item.Path)$($item.Name)"
            continue
        }
        if ($item.Enabled) {
            Enable-ScheduledTask -InputObject $task | Out-Null
        }
        else {
            Disable-ScheduledTask -InputObject $task | Out-Null
        }
    }

    foreach ($item in $state.Services) {
        if (-not $item.Exists) { continue }
        $service = Get-Service -Name $item.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Warning "Cannot restore missing service: $($item.Name)"
            continue
        }

        Set-Service -Name $item.Name -StartupType $item.StartupType
        Restore-RegistryState -Item $item.DelayedAutoState

        if ($item.Status -eq 'Running') {
            Start-Service -Name $item.Name -ErrorAction Continue
        }
        else {
            Stop-Service -Name $item.Name -ErrorAction Continue
        }
    }

    if (-not $Quiet) {
        Write-Host "Restored state from: $StateFile" -ForegroundColor Green
        Write-Host 'Reboot Windows to complete restoration.' -ForegroundColor Yellow
    }
}

function Show-Plan {
    Write-Section 'Dell G15 5530 - precision aggressive debloat (preview)'

    $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    Write-Host "Script version : $ScriptVersion"
    Write-Host "Windows edition: $edition"
    Write-Host "NVIDIA App     : $(if ($KeepNvidiaApp) { 'preserved by request' } else { 'background container set to Manual and stopped' })"

    Write-Host ''
    Write-Host 'Services:' -ForegroundColor Cyan
    foreach ($target in $ProtectedServiceNotes) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Host "  [not installed] $($target.Name)"
            continue
        }
        $startup = Get-ServiceStartupType -Name $target.Name
        Write-Host ('  {0}: {1}/{2} -> UNCHANGED (protected)' -f $target.Name, $startup, $service.Status)
        Write-Host ('    {0}' -f $target.Reason) -ForegroundColor Yellow
    }
    foreach ($target in $ServiceTargets) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Host "  [not installed] $($target.Name)"
            continue
        }
        $startup = Get-ServiceStartupType -Name $target.Name
        Write-Host ('  {0}: {1}/{2} -> Manual/Stopped' -f $target.Name, $startup, $service.Status)
        Write-Host ('    {0}' -f $target.Reason) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Scheduled tasks:' -ForegroundColor Cyan
    foreach ($target in $TaskTargets) {
        $task = Get-TaskOrNull -Path $target.Path -Name $target.Name
        if ($null -eq $task) {
            Write-Host "  [not installed] $($target.Path)$($target.Name)"
            continue
        }
        Write-Host ('  {0}{1}: Enabled={2} -> False' -f $target.Path, $target.Name, $task.Settings.Enabled)
        Write-Host ('    {0}' -f $target.Reason) -ForegroundColor DarkGray
    }
    foreach ($target in $ProtectedTaskNotes) {
        $task = Get-TaskOrNull -Path $target.Path -Name $target.Name
        if ($null -eq $task) {
            Write-Host "  [not installed] $($target.Path)$($target.Name)"
            continue
        }
        Write-Host ('  {0}{1}: Enabled={2} -> UNCHANGED (protected)' -f $target.Path, $target.Name, $task.Settings.Enabled)
        Write-Host ('    {0}' -f $target.Reason) -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Documented policies:' -ForegroundColor Cyan
    foreach ($target in $RegistryTargets) {
        $old = Get-RegistryValueState -Path $target.Path -Name $target.Name
        $oldText = if ($old.ValueExists) { [string]$old.Value } else { '<not configured>' }
        Write-Host ('  {0}\{1}: {2} -> {3}' -f $target.Path, $target.Name, $oldText, $target.Value)
        Write-Host ('    {0}' -f $target.Reason) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Deliberately preserved:' -ForegroundColor Cyan
    Write-Host '  Defender, Firewall, Windows Update, Edge/Office update tasks'
    Write-Host '  Intel Innovation Platform Framework, Intel audio/HDCP, Wi-Fi services'
    Write-Host '  NVIDIA display driver and NVDisplay.ContainerLocalSystem (Control Panel)'
    Write-Host '  Dell thermal/power components, Realtek/Dolby audio, Bluetooth and USB'
    Write-Host '  Hyper-V, WSL, Host Network Service and virtualization networking'
    Write-Host '  Sleep, hibernation, Task Scheduler, indexing state, drivers and Appx packages'
}

function Invoke-Apply {
    Assert-Administrator
    Show-Plan

    Write-Section 'Applying'
    $stateFile = New-StateBackup
    Write-Host "Backup: $stateFile"

    $changedServices = @()
    $changedTaskKeys = @()

    try {
        foreach ($target in $ServiceTargets) {
            $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
            if ($null -eq $service) { continue }

            try {
                Set-Service -Name $target.Name -StartupType $target.StartupType -ErrorAction Stop
                $changedServices += $target.Name
            }
            catch {
                Write-Warning "Optional service $($target.Name) was skipped: $($_.Exception.Message)"
                continue
            }
            if ($target.Stop -and $service.Status -ne 'Stopped') {
                try {
                    Stop-Service -Name $target.Name -ErrorAction Stop
                }
                catch {
                    Write-Warning "$($target.Name) could not stop immediately; Manual startup will take effect after reboot. $($_.Exception.Message)"
                }
            }
        }

        foreach ($target in $TaskTargets) {
            $task = Get-TaskOrNull -Path $target.Path -Name $target.Name
            if ($null -ne $task) {
                try {
                    Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
                    $changedTaskKeys += ('{0}|{1}' -f $target.Path, $target.Name)
                }
                catch {
                    Write-Warning "Optional task $($target.Path)$($target.Name) was skipped: $($_.Exception.Message)"
                }
            }
        }

        # Discard the pre-change snapshot before read-back verification.
        Clear-TaskCache

        foreach ($target in $RegistryTargets) {
            Set-RegistryTarget -Target $target
        }

        # End only exact optional UI/telemetry processes. Do not kill generic
        # nvcontainer or msedgewebview2 processes because those may host drivers
        # or applications that are deliberately preserved.
        $processNames = @('CrossDeviceResume')
        if (-not $KeepNvidiaApp) { $processNames += 'PresentMonService' }
        foreach ($name in $processNames) {
            Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }

        $verificationErrors = New-Object System.Collections.Generic.List[string]

        foreach ($target in $ServiceTargets) {
            if ($changedServices -notcontains $target.Name) { continue }
            if ($null -eq (Get-Service -Name $target.Name -ErrorAction SilentlyContinue)) { continue }
            $actual = Get-ServiceStartupType -Name $target.Name
            if ($actual -ne $target.StartupType) {
                $verificationErrors.Add("Service $($target.Name): expected startup $($target.StartupType), read back $actual")
            }
        }

        foreach ($target in $TaskTargets) {
            $taskKey = '{0}|{1}' -f $target.Path, $target.Name
            if ($changedTaskKeys -notcontains $taskKey) { continue }
            $task = Get-TaskOrNull -Path $target.Path -Name $target.Name
            if (($null -ne $task) -and $task.Settings.Enabled) {
                $verificationErrors.Add("Task $($target.Path)$($target.Name) remained enabled")
            }
        }

        foreach ($target in $RegistryTargets) {
            $actual = Get-RegistryValueState -Path $target.Path -Name $target.Name
            if ((-not $actual.ValueExists) -or ([int64]$actual.Value -ne [int64]$target.Value)) {
                $verificationErrors.Add("Policy $($target.Path)\$($target.Name) did not read back as $($target.Value)")
            }
        }

        if ($verificationErrors.Count -gt 0) {
            throw ($verificationErrors -join [Environment]::NewLine)
        }
    }
    catch {
        $failure = $_
        Write-Warning 'A critical apply/verification step failed. Restoring the pre-change state.'
        try {
            Restore-State -StateFile $stateFile -Quiet
        }
        catch {
            Write-Warning "Automatic rollback also reported an error: $($_.Exception.Message)"
        }
        throw "Apply failed and rollback was attempted: $($failure.Exception.Message)"
    }

    Write-Host ''
    Write-Host 'Applied and verified successfully.' -ForegroundColor Green
    Write-Host "Restore state: $stateFile"
    Write-Host 'Reboot once before measuring idle power or process count.' -ForegroundColor Yellow
    if ($KeepNvidiaApp) {
        Write-Host 'NVIDIA note: the NVIDIA App and its background service were preserved by request.'
    }
    else {
        Write-Host 'NVIDIA note: the driver and Control Panel service were preserved; the NVIDIA App overlay/recording/auto-update backend was not.'
    }
}

function Invoke-Diagnose {
    Assert-Administrator
    Write-Section 'G15 debloat diagnosis (one-shot; no resident polling)'

    Write-Host 'Target services:' -ForegroundColor Cyan
    foreach ($target in $ServiceTargets) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            Write-Host "  $($target.Name): not installed"
        }
        else {
            Write-Host ('  {0}: Startup={1}; Status={2}' -f $target.Name, (Get-ServiceStartupType $target.Name), $service.Status)
        }
    }

    # Always report both NVIDIA containers so it is obvious that the display
    # container was intentionally retained.
    foreach ($name in @('NVDisplay.ContainerLocalSystem', 'NvContainerLocalSystem')) {
        if ($ServiceTargets.Name -contains $name) { continue }
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            Write-Host ('  {0}: Startup={1}; Status={2}' -f $name, (Get-ServiceStartupType $name), $service.Status)
        }
    }

    Write-Host ''
    Write-Host 'Relevant running processes:' -ForegroundColor Cyan
    $names = @('IntelGraphicsSoftware', 'IntelGraphicsSoftware.Service', 'PresentMonService', 'CrossDeviceResume', 'msedgewebview2')
    $processes = Get-Process -Name $names -ErrorAction SilentlyContinue |
        Sort-Object ProcessName, Id |
        Select-Object ProcessName, Id,
            @{Name = 'CPUSeconds'; Expression = { if ($null -eq $_.CPU) { $null } else { [math]::Round($_.CPU, 2) } } },
            @{Name = 'MemoryMB'; Expression = { [math]::Round($_.WorkingSet64 / 1MB, 1) } }
    if ($null -eq $processes) {
        Write-Host '  None of the tracked optional processes are running.'
    }
    else {
        $processes | Format-Table -AutoSize
    }

    Write-Host 'Power requests:' -ForegroundColor Cyan
    & powercfg.exe /requests

    Write-Host ''
    Write-Host 'Wake timers:' -ForegroundColor Cyan
    & powercfg.exe /waketimers

    Write-Host ''
    Write-Host 'This diagnosis does not call nvidia-smi and does not poll the GPU.' -ForegroundColor DarkGray
}

try {
    switch ($PSCmdlet.ParameterSetName) {
        'Apply' {
            Invoke-Apply
        }
        'Diagnose' {
            Invoke-Diagnose
        }
        'RestoreLatest' {
            Assert-Administrator
            if (-not (Test-Path -LiteralPath $StateRoot)) {
                throw "No backups exist under $StateRoot"
            }
            $latest = Get-ChildItem -LiteralPath $StateRoot -Filter 'state.xml' -File -Recurse |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
            if ($null -eq $latest) {
                throw "No restore state was found under $StateRoot"
            }
            Restore-State -StateFile $latest.FullName
        }
        'RestoreFrom' {
            Assert-Administrator
            Restore-State -StateFile $RestoreFrom
        }
        default {
            Show-Plan
            Write-Host ''
            Write-Host 'PREVIEW ONLY. Nothing was changed.' -ForegroundColor Yellow
            Write-Host ('Apply with: & "{0}" -Apply' -f $PSCommandPath)
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
