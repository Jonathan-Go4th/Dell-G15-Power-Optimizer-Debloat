#requires -Version 5.1
<#
Dell G15 5530 / Intel Core i5-13450HX
Daily low-power + race-to-idle policy, revision 2026-09-22-r14

Design goals
------------
* Low screen-on idle and light-load energy, without intentionally making the UI slow.
* Preserve the user's 99% maximum-processor-state requirement.
* Leave Intel HWP/Speed Shift autonomous control and processor idle states enabled.
* Let Windows 11 + Intel Thread Director choose P- versus E-cores automatically.
* Keep the NVIDIA dGPU available to Optimus, but do nothing that polls or pins it awake.
* Use only documented power settings (plus settings that powercfg itself exposes).
* Back up, verify, and roll back deterministically.

Important choices
-----------------
* EPP 60 AC / 72 DC is a measured, power-biased daily-use compromise for this machine,
  not a Microsoft or Intel universal recommendation. It preserves more burst response
  than EPP 100.
* Boost is disabled and maximum processor state is 99% because that is the explicit
  owner requirement. This is not the fastest theoretical race-to-idle configuration.
* SCHEDPOLICY and SHORTSCHEDPOLICY are 5 (Automatic). Windows can use Thread Director,
  QoS, workload type, and current conditions instead of a static E-core preference.
* PERFAUTONOMOUSWINDOW is deliberately not written. Zero is a real microsecond value,
  not a documented "hardware default"; a previous 10000-us experiment also caused a
  severe high-idle regression on this exact machine.
* Latency-hint floors/EPP, heterogeneous floor controls, increase/decrease policies,
  and frequency ceilings are inherited from Balanced. Overriding them did not have a
  sufficiently proven whole-system benefit and can undermine interactive bursts.
* NVMe idle settings use Microsoft's documented Power Saver S0 values. The active
  DISKMAXPOWER cap is not changed; Microsoft reports little benefit from lower active
  operational states, and such a cap can lengthen I/O bursts.
* PCIe ASPM is a policy request only. Firmware/device support decides whether L1 and
  deeper link states are actually reached.

This script does not change BIOS, registry security settings, services, scheduled
tasks, Windows Update, WSL, Hyper-V, Docker, hibernation, display brightness, refresh
rate, or NVIDIA application profiles. It installs no resident process or polling loop.

Primary documentation reviewed 2026-09-22
------------------------------------------
Microsoft processor settings:
https://learn.microsoft.com/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference
https://learn.microsoft.com/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfautonomousmode
https://learn.microsoft.com/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfautonomouswindow
https://learn.microsoft.com/windows-hardware/customize/power-settings/configuration-for-hetero-power-scheduling-schedulingpolicy
https://learn.microsoft.com/windows-hardware/customize/power-settings/configuration-for-hetero-power-scheduling-shortschedulingpolicy
https://learn.microsoft.com/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfboostmode
Microsoft storage, PCIe, USB, and power mode:
https://learn.microsoft.com/windows-hardware/design/component-guidelines/power-management-for-storage-hardware-devices-nvme
https://learn.microsoft.com/windows-hardware/drivers/usbcon/usb-selective-suspend
https://learn.microsoft.com/windows/win32/api/powrprof/nf-powrprof-powersetuserconfiguredacpowermode
Intel Thread Director:
https://www.intel.com/content/www/us/en/support/articles/000097053/processors/intel-core-processors.html
Dell G15 5530 firmware options:
https://www.dell.com/support/manuals/en-us/g-series-15-5530-laptop/dell-g15-5530-owners-manual/system-setup-options

Run from Administrator Windows PowerShell:
  .\G15-Power-Optimization.ps1 -Preview
  .\G15-Power-Optimization.ps1 -Apply
  .\G15-Power-Optimization.ps1 -Diagnose
  .\G15-Power-Optimization.ps1 -RestoreLatest
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Preview,
    [switch]$Diagnose,
    [switch]$RestoreLatest,
    [string]$RestoreFrom = '',
    [string]$BaseSchemeGuid = '',
    [switch]$KeepPowerMode,
    [ValidateRange(0,100)][int]$EppAC = 60,
    [ValidateRange(0,100)][int]$EppDC = 72
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run Windows PowerShell as Administrator.'
}

function Invoke-PowerCfg {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & powercfg.exe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $priorPreference
    }

    $result = [pscustomobject]@{
        Code = $exitCode
        Text = ($output | Out-String)
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "powercfg $($Arguments -join ' ') failed:`n$($result.Text)"
    }
    return $result
}

function Get-GuidFromText {
    param([Parameter(Mandatory=$true)][string]$Text)
    $match = [regex]::Match($Text, '(?i)[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}')
    if (-not $match.Success) {
        throw 'Could not identify a power-plan GUID in powercfg output.'
    }
    return $match.Value.ToLowerInvariant()
}

function Test-PowerSchemeExists {
    param([Parameter(Mandatory=$true)][string]$Guid)
    return (Invoke-PowerCfg -Arguments @('/query', $Guid) -AllowFailure).Code -eq 0
}

function Read-PowerSettingPair {
    param(
        [Parameter(Mandatory=$true)][string]$Scheme,
        [Parameter(Mandatory=$true)][string]$Group,
        [Parameter(Mandatory=$true)][string]$Setting
    )

    $query = Invoke-PowerCfg -Arguments @('/qh', $Scheme, $Group, $Setting) -AllowFailure
    if ($query.Code -ne 0) {
        if ($query.Text -match '(?i)access.*denied|permission') {
            throw $query.Text
        }
        return $null
    }

    # The last two hexadecimal values in a single-setting /qh query are the
    # current AC and DC indices. This remains language-neutral.
    $hexValues = [regex]::Matches($query.Text, '(?i)0x([0-9a-f]+)')
    if ($hexValues.Count -lt 2) {
        return $null
    }
    return [pscustomobject]@{
        AC = [Convert]::ToUInt32($hexValues[$hexValues.Count - 2].Groups[1].Value, 16)
        DC = [Convert]::ToUInt32($hexValues[$hexValues.Count - 1].Groups[1].Value, 16)
    }
}

function Assert-TargetPlatform {
    $computer = Get-CimInstance Win32_ComputerSystem
    $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ([string]$computer.Model -notmatch 'G15\s+5530' -or
        [string]$processor.Name -notmatch 'i5-13450HX') {
        Write-Warning ("Detected model '{0}', CPU '{1}'. This policy was engineered for Dell G15 5530 / i5-13450HX." -f $computer.Model, $processor.Name)
    }
}

function Initialize-PowerModeApi {
    if (-not ([System.Management.Automation.PSTypeName]'G15PowerModeApi').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class G15PowerModeApi {
    [DllImport("powrprof.dll")] public static extern uint PowerGetUserConfiguredACPowerMode(out Guid mode);
    [DllImport("powrprof.dll")] public static extern uint PowerGetUserConfiguredDCPowerMode(out Guid mode);
    [DllImport("powrprof.dll")] public static extern uint PowerSetUserConfiguredACPowerMode(ref Guid mode);
    [DllImport("powrprof.dll")] public static extern uint PowerSetUserConfiguredDCPowerMode(ref Guid mode);
}
'@
    }
}

function Get-UserPowerModes {
    Initialize-PowerModeApi
    $acMode = [guid]::Empty
    $dcMode = [guid]::Empty
    $acResult = [G15PowerModeApi]::PowerGetUserConfiguredACPowerMode([ref]$acMode)
    $dcResult = [G15PowerModeApi]::PowerGetUserConfiguredDCPowerMode([ref]$dcMode)
    if ($acResult -ne 0 -or $dcResult -ne 0) {
        throw "Could not read Windows power modes (AC result=$acResult, DC result=$dcResult)."
    }
    return [pscustomobject]@{
        AC = $acMode.ToString().ToLowerInvariant()
        DC = $dcMode.ToString().ToLowerInvariant()
    }
}

function Set-UserPowerModes {
    param(
        [Parameter(Mandatory=$true)][guid]$AC,
        [Parameter(Mandatory=$true)][guid]$DC
    )
    Initialize-PowerModeApi
    $acResult = [G15PowerModeApi]::PowerSetUserConfiguredACPowerMode([ref]$AC)
    $dcResult = [G15PowerModeApi]::PowerSetUserConfiguredDCPowerMode([ref]$DC)
    if ($acResult -ne 0 -or $dcResult -ne 0) {
        throw "Could not set Windows power modes (AC result=$acResult, DC result=$dcResult)."
    }
}

function Resolve-BaseScheme {
    param([string]$RequestedGuid)
    if ($RequestedGuid) {
        $requested = ([guid]$RequestedGuid).ToString().ToLowerInvariant()
        if (-not (Test-PowerSchemeExists $requested)) {
            throw "Requested base power scheme does not exist: $requested"
        }
        return $requested
    }

    # Balanced is the supported parent for Modern Standby systems and avoids
    # inheriting unknown experimental values from the currently active plan.
    $balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    if (-not (Test-PowerSchemeExists $balanced)) {
        throw 'The Windows Balanced scheme is unavailable. Supply -BaseSchemeGuid with a known-good scheme GUID.'
    }
    return $balanced
}

function Get-ProcessCpuSnapshot {
    $snapshot = @{}
    foreach ($process in Get-Process) {
        if ($process.Id -eq 0) { continue }
        try {
            $key = '{0}:{1}' -f $process.Id, $process.StartTime.ToUniversalTime().Ticks
            $snapshot[$key] = [pscustomobject]@{
                Id = $process.Id
                Name = $process.ProcessName
                CPUSeconds = [double]$process.TotalProcessorTime.TotalSeconds
            }
        }
        catch {
            # Protected or exiting processes can disappear during enumeration.
        }
    }
    return $snapshot
}

# ---------------------------------------------------------------------------
# Mode validation
# ---------------------------------------------------------------------------
$modeCount = 0
if ($Apply) { $modeCount++ }
if ($Preview) { $modeCount++ }
if ($Diagnose) { $modeCount++ }
if ($RestoreLatest) { $modeCount++ }
if ($RestoreFrom) { $modeCount++ }

if ($modeCount -gt 1) {
    throw 'Use exactly one of -Preview, -Apply, -Diagnose, -RestoreLatest, or -RestoreFrom.'
}
if ($modeCount -eq 0) {
    Write-Host 'Specify -Preview, -Apply, -Diagnose, -RestoreLatest, or -RestoreFrom.' -ForegroundColor Yellow
    return
}

$stateRoot = Join-Path $env:ProgramData 'G15-Low-Power-Master'

# ---------------------------------------------------------------------------
# Diagnostics: deliberately non-resident and explicitly not an idle test
# ---------------------------------------------------------------------------
if ($Diagnose) {
    $diagnosticFolder = Join-Path $stateRoot ('diagnostics-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $null = New-Item -ItemType Directory -Path $diagnosticFolder -Force

    (Invoke-PowerCfg -Arguments @('/getactivescheme')).Text |
        Set-Content -LiteralPath (Join-Path $diagnosticFolder 'active-plan.txt')
    (Invoke-PowerCfg -Arguments @('/list')).Text |
        Set-Content -LiteralPath (Join-Path $diagnosticFolder 'plan-list.txt')
    (Invoke-PowerCfg -Arguments @('/qh', 'SCHEME_CURRENT')).Text |
        Set-Content -LiteralPath (Join-Path $diagnosticFolder 'active-settings.txt')
    (Invoke-PowerCfg -Arguments @('/a') -AllowFailure).Text |
        Set-Content -LiteralPath (Join-Path $diagnosticFolder 'sleep-capabilities.txt')

    foreach ($diagnostic in @(
        @{ Name='requests.txt'; Arguments=@('/requests') },
        @{ Name='waketimers.txt'; Arguments=@('/waketimers') },
        @{ Name='lastwake.txt'; Arguments=@('/lastwake') },
        @{ Name='wake-armed-devices.txt'; Arguments=@('/devicequery', 'wake_armed') }
    )) {
        (Invoke-PowerCfg -Arguments $diagnostic.Arguments -AllowFailure).Text |
            Set-Content -LiteralPath (Join-Path $diagnosticFolder $diagnostic.Name)
    }

    try {
        Get-UserPowerModes | Format-List | Out-String |
            Set-Content -LiteralPath (Join-Path $diagnosticFolder 'power-modes.txt')
    }
    catch {
        $_.Exception.Message | Set-Content -LiteralPath (Join-Path $diagnosticFolder 'power-modes.txt')
    }

    try {
        Get-CimInstance Win32_ComputerSystem |
            Select-Object Manufacturer, Model, TotalPhysicalMemory |
            Export-Csv -NoTypeInformation -LiteralPath (Join-Path $diagnosticFolder 'system.csv')
        Get-CimInstance Win32_Processor |
            Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed |
            Export-Csv -NoTypeInformation -LiteralPath (Join-Path $diagnosticFolder 'processor.csv')
        Get-CimInstance Win32_BIOS |
            Select-Object SMBIOSBIOSVersion, ReleaseDate |
            Export-Csv -NoTypeInformation -LiteralPath (Join-Path $diagnosticFolder 'bios.csv')
        Get-CimInstance Win32_OperatingSystem |
            Select-Object Caption, Version, BuildNumber |
            Export-Csv -NoTypeInformation -LiteralPath (Join-Path $diagnosticFolder 'windows.csv')
        Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus |
            Select-Object PowerOnline, Discharging, Charging, DischargeRate, RemainingCapacity, Voltage |
            Export-Csv -NoTypeInformation -LiteralPath (Join-Path $diagnosticFolder 'battery-snapshot.csv')
    }
    catch {
        Write-Warning ('Some platform telemetry was unavailable: ' + $_.Exception.Message)
    }

    Write-Host 'Running powercfg /energy for 60 seconds.' -ForegroundColor Cyan
    Write-Host 'This trace creates CPU and device activity; it is not an idle-wattage measurement.' -ForegroundColor Yellow
    $energyReport = Join-Path $diagnosticFolder 'energy-report.html'
    $before = Get-ProcessCpuSnapshot
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $energyResult = Invoke-PowerCfg -Arguments @('/energy', '/output', $energyReport, '/duration', '60') -AllowFailure
    $clock.Stop()
    $after = Get-ProcessCpuSnapshot

    $usage = @(foreach ($key in $after.Keys) {
        if ($before.ContainsKey($key)) {
            $delta = $after[$key].CPUSeconds - $before[$key].CPUSeconds
            if ($delta -gt 0) {
                [pscustomobject]@{
                    Process = $after[$key].Name
                    Id = $after[$key].Id
                    CPUSeconds = [math]::Round($delta, 3)
                    OneCorePercent = [math]::Round(100 * $delta / [math]::Max(1, $clock.Elapsed.TotalSeconds), 2)
                }
            }
        }
    })
    $usage | Sort-Object CPUSeconds -Descending |
        Export-Csv -NoTypeInformation -LiteralPath (Join-Path $diagnosticFolder 'process-cpu.csv')
    $energyResult.Text | Set-Content -LiteralPath (Join-Path $diagnosticFolder 'energy-command.txt')

    if (-not (Test-Path -LiteralPath $energyReport)) {
        Write-Warning 'The energy report was not created. See energy-command.txt.'
    }
    Write-Host "Diagnostics saved to: $diagnosticFolder" -ForegroundColor Green
    Write-Host 'The report is not opened automatically, avoiding another browser/GPU wake-up.'
    return
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
if ($RestoreLatest) {
    $activeGuid = Get-GuidFromText (Invoke-PowerCfg -Arguments @('/getactivescheme')).Text
    if (Test-Path -LiteralPath $stateRoot) {
        foreach ($file in (Get-ChildItem -LiteralPath $stateRoot -Filter state.xml -Recurse -File |
                Sort-Object LastWriteTime -Descending)) {
            try {
                $candidate = Import-Clixml -LiteralPath $file.FullName
                if ([string]$candidate.NewGuid -eq $activeGuid -and [string]$candidate.Status -eq 'Applied') {
                    $RestoreFrom = $file.FullName
                    break
                }
            }
            catch {
                Write-Warning ('Skipped unreadable restore state: ' + $file.FullName)
            }
        }
    }
    if (-not $RestoreFrom) {
        throw 'No applied restore state matches the active plan. Use -RestoreFrom with the exact state.xml path printed by -Apply.'
    }
}

if ($RestoreFrom) {
    $state = Import-Clixml -LiteralPath $RestoreFrom
    $previousGuid = ([guid]$state.PreviousGuid).ToString().ToLowerInvariant()
    $managedGuid = ([guid]$state.NewGuid).ToString().ToLowerInvariant()
    $backupPlan = Join-Path (Split-Path -Parent $RestoreFrom) 'previous.pow'

    if (-not (Test-PowerSchemeExists $previousGuid)) {
        if (-not (Test-Path -LiteralPath $backupPlan)) {
            throw "The previous scheme is absent and its backup is missing: $backupPlan"
        }
        Invoke-PowerCfg -Arguments @('/import', $backupPlan, $previousGuid) | Out-Null
    }

    Invoke-PowerCfg -Arguments @('/setactive', $previousGuid) | Out-Null
    if ((Get-GuidFromText (Invoke-PowerCfg -Arguments @('/getactivescheme')).Text) -ne $previousGuid) {
        throw 'Previous power-plan activation verification failed.'
    }

    if ($state.PSObject.Properties['PreviousModes'] -and $null -ne $state.PreviousModes) {
        Set-UserPowerModes -AC ([guid]$state.PreviousModes.AC) -DC ([guid]$state.PreviousModes.DC)
        $restoredModes = Get-UserPowerModes
        if ($restoredModes.AC -ne [string]$state.PreviousModes.AC -or
            $restoredModes.DC -ne [string]$state.PreviousModes.DC) {
            throw 'The prior power plan is active, but Windows power-mode restoration did not verify.'
        }
    }

    # Delete only the exact managed plan from this state file, and only after
    # another plan is active. This prevents duplicate managed plans accumulating.
    if ($managedGuid -ne $previousGuid -and (Test-PowerSchemeExists $managedGuid)) {
        $deleteResult = Invoke-PowerCfg -Arguments @('/delete', $managedGuid) -AllowFailure
        if ($deleteResult.Code -ne 0) {
            Write-Warning ("Restored successfully, but could not delete managed plan $managedGuid.`n$($deleteResult.Text)")
        }
    }

    if ($state.PSObject.Properties['Status']) { $state.Status = 'Restored' }
    if ($state.PSObject.Properties['RestoredUtc']) {
        $state.RestoredUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    else {
        $state | Add-Member -NotePropertyName RestoredUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o'))
    }
    $state | Export-Clixml -LiteralPath $RestoreFrom

    Write-Host "Restored previous power plan: $previousGuid" -ForegroundColor Green
    return
}

# ---------------------------------------------------------------------------
# Build and preview target policy
# ---------------------------------------------------------------------------
Assert-TargetPlatform
$previousGuid = Get-GuidFromText (Invoke-PowerCfg -Arguments @('/getactivescheme')).Text
$baseGuid = Resolve-BaseScheme $BaseSchemeGuid
$neutralPowerMode = [guid]'00000000-0000-0000-0000-000000000000'
$previousModes = $null

if (-not $KeepPowerMode) {
    try {
        $previousModes = Get-UserPowerModes
    }
    catch {
        throw ('Windows power mode could not be backed up; no changes were made. ' + $_.Exception.Message)
    }
}
else {
    try { $previousModes = Get-UserPowerModes }
    catch { Write-Warning 'Windows power mode could not be read, but -KeepPowerMode requested no change.' }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Dell G15 5530 / i5-13450HX - DAILY LOW POWER r14' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host "Current active plan : $previousGuid"
Write-Host "Source baseline     : $baseGuid"
Write-Host ''

$rows = New-Object 'System.Collections.Generic.List[object]'
function Add-Setting {
    param(
        [Parameter(Mandatory=$true)][string]$Group,
        [Parameter(Mandatory=$true)][string]$Setting,
        [Parameter(Mandatory=$true)][int]$AC,
        [Parameter(Mandatory=$true)][int]$DC,
        [Parameter(Mandatory=$true)][int]$Minimum,
        [Parameter(Mandatory=$true)][int]$Maximum,
        [Parameter(Mandatory=$true)][bool]$Critical,
        [Parameter(Mandatory=$true)][string]$Label
    )
    if ($AC -lt $Minimum -or $AC -gt $Maximum -or $DC -lt $Minimum -or $DC -gt $Maximum) {
        throw "Invalid value for $Label. Allowed range=$Minimum..$Maximum; AC=$AC; DC=$DC."
    }
    $rows.Add([pscustomobject]@{
        Group = $Group
        Setting = $Setting
        AC = $AC
        DC = $DC
        Critical = $Critical
        Label = $Label
    })
}

$processorGroup = 'SUB_PROCESSOR'

# CPU performance policy. Class-1 controls are optional because Windows images
# differ in what they expose; the base controls are critical.
Add-Setting $processorGroup 'PERFEPP' $EppAC $EppDC 0 100 $true 'Energy performance preference'
Add-Setting $processorGroup 'PERFEPP1' $EppAC $EppDC 0 100 $false 'Class-1 energy performance preference'
Add-Setting $processorGroup 'PROCTHROTTLEMIN' 0 0 0 100 $true 'Minimum processor state'
Add-Setting $processorGroup 'PROCTHROTTLEMIN1' 0 0 0 100 $false 'Class-1 minimum processor state'
Add-Setting $processorGroup 'PROCTHROTTLEMAX' 99 99 0 100 $true 'Maximum processor state (owner requirement)'
Add-Setting $processorGroup 'PROCTHROTTLEMAX1' 99 99 0 100 $false 'Class-1 maximum processor state'
Add-Setting $processorGroup 'PERFBOOSTMODE' 0 0 0 4 $true 'Processor boost mode (disabled)'
Add-Setting $processorGroup 'PERFAUTONOMOUS' 1 1 0 1 $false 'Autonomous hardware performance control'
Add-Setting $processorGroup 'IDLEDISABLE' 0 0 0 1 $true 'Processor idle states (enabled)'
Add-Setting $processorGroup 'SCHEDPOLICY' 5 5 0 5 $false 'Long-thread heterogeneous scheduling (Automatic)'
Add-Setting $processorGroup 'SHORTSCHEDPOLICY' 5 5 0 5 $false 'Short-thread heterogeneous scheduling (Automatic)'
Add-Setting $processorGroup 'CPMINCORES' 0 0 0 100 $false 'Core-parking minimum'
Add-Setting $processorGroup 'CPMAXCORES' 100 100 0 100 $false 'Core-parking maximum'
Add-Setting $processorGroup 'CPMINCORES1' 0 0 0 100 $false 'Class-1 core-parking minimum'
Add-Setting $processorGroup 'CPMAXCORES1' 100 100 0 100 $false 'Class-1 core-parking maximum'

# Device policies. These are requests; actual low-power states depend on the
# controller, driver, firmware, endpoint, and current workload.
Add-Setting 'SUB_PCIEXPRESS' 'ASPM' 2 2 0 2 $false 'PCIe link-state power management (Maximum savings)'
Add-Setting '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 1 1 0 1 $false 'USB selective suspend (enabled)'
Add-Setting '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1' '12bbebe6-58d6-4636-95bb-3217ef867c1a' 3 3 0 3 $false 'Wi-Fi power saving (AC/DC maximum)'

# Microsoft-documented S0 Power Saver values for StorNVMe.
Add-Setting 'SUB_DISK' 'd639518a-e56d-4345-8af2-b9f32fb26109' 100 100 0 60000 $false 'NVMe primary idle timeout (ms)'
Add-Setting 'SUB_DISK' 'fc95af4d-40e7-4b6d-835a-56d131dbc80e' 100 200 0 60000 $false 'NVMe primary transition latency tolerance (ms)'
Add-Setting 'SUB_DISK' 'd3d55efd-c1ff-424e-9dc3-441be7833010' 1000 1000 0 60000 $false 'NVMe secondary idle timeout (ms)'
Add-Setting 'SUB_DISK' 'dbc9e238-6de9-49e3-92cd-8c2b4946b472' 200 200 0 60000 $false 'NVMe secondary transition latency tolerance (ms)'

Write-Host 'Deliberately inherited (not overwritten):' -ForegroundColor Cyan
Write-Host '  PERFAUTONOMOUSWINDOW; latency-hint controls; HETEROCLASS0FLOORPERF;'
Write-Host '  performance increase/decrease policy; fixed frequency caps; cooling policy;'
Write-Host '  NVMe DISKMAXPOWER; display timeouts/brightness; video quality; sleep/hibernate.'
if ($KeepPowerMode) {
    Write-Warning 'Windows power mode will be preserved. A non-balanced mode can override effective PPM behavior.'
}
else {
    Write-Host 'Windows power mode will be set to Balanced/neutral before this plan is activated.'
}
Write-Host 'No NVIDIA query or polling command will run.'
Write-Host ''

$supportedRows = New-Object 'System.Collections.Generic.List[object]'
foreach ($row in $rows) {
    $old = Read-PowerSettingPair $baseGuid $row.Group $row.Setting
    if ($null -eq $old) {
        if ($row.Critical) {
            throw "Critical setting is unavailable in the source plan: $($row.Label)"
        }
        Write-Warning "SKIP unsupported setting: $($row.Label)"
        continue
    }
    $supportedRows.Add($row)
    Write-Host ("{0}: AC {1}->{2}; DC {3}->{4}" -f $row.Label, $old.AC, $row.AC, $old.DC, $row.DC)
}

if ($Preview) {
    Write-Host ''
    Write-Host 'PREVIEW ONLY. Nothing was changed.' -ForegroundColor Yellow
    Write-Host ("Apply with: & `"{0}`" -Apply" -f $PSCommandPath) -ForegroundColor Cyan
    return
}

# ---------------------------------------------------------------------------
# Backup and apply
# ---------------------------------------------------------------------------
$backupFolder = Join-Path $stateRoot (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$null = New-Item -ItemType Directory -Path $backupFolder -Force
$stateFile = Join-Path $backupFolder 'state.xml'
$previousExport = Join-Path $backupFolder 'previous.pow'
$sourceExport = Join-Path $backupFolder 'source-baseline.pow'
$newGuid = [guid]::NewGuid().ToString().ToLowerInvariant()
$newPlanCreated = $false

Invoke-PowerCfg -Arguments @('/export', $previousExport, $previousGuid) | Out-Null
Invoke-PowerCfg -Arguments @('/export', $sourceExport, $baseGuid) | Out-Null

$state = [pscustomobject]@{
    Revision = '2026-09-22-r14-daily-low-power'
    PreviousGuid = $previousGuid
    BaseGuid = $baseGuid
    NewGuid = $newGuid
    PreviousModes = $previousModes
    KeepPowerMode = [bool]$KeepPowerMode
    RequestedEppAC = $EppAC
    RequestedEppDC = $EppDC
    AppliedSettings = @($supportedRows.ToArray())
    Status = 'Preparing'
    CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
}
$state | Export-Clixml -LiteralPath $stateFile

try {
    # Select the documented balanced/neutral user vote first. Activating the
    # custom plan afterward makes its stored values the last applied plan policy.
    if (-not $KeepPowerMode) {
        Set-UserPowerModes -AC $neutralPowerMode -DC $neutralPowerMode
        $modeCheck = Get-UserPowerModes
        if ($modeCheck.AC -ne $neutralPowerMode.ToString() -or
            $modeCheck.DC -ne $neutralPowerMode.ToString()) {
            throw 'Windows power mode did not verify as Balanced/neutral.'
        }
    }

    Invoke-PowerCfg -Arguments @('/duplicatescheme', $baseGuid, $newGuid) | Out-Null
    $newPlanCreated = $true
    $shortGuid = $newGuid.Substring(0, 8)
    Invoke-PowerCfg -Arguments @('/changename', $newGuid, "Dell G15 - Daily Low Power r14 [$shortGuid]") | Out-Null

    foreach ($row in $supportedRows) {
        Invoke-PowerCfg -Arguments @('/setacvalueindex', $newGuid, $row.Group, $row.Setting, [string]$row.AC) | Out-Null
        Invoke-PowerCfg -Arguments @('/setdcvalueindex', $newGuid, $row.Group, $row.Setting, [string]$row.DC) | Out-Null

        $check = Read-PowerSettingPair $newGuid $row.Group $row.Setting
        if ($null -eq $check -or $check.AC -ne $row.AC -or $check.DC -ne $row.DC) {
            $actualAC = if ($null -eq $check) { 'unavailable' } else { [string]$check.AC }
            $actualDC = if ($null -eq $check) { 'unavailable' } else { [string]$check.DC }
            throw "Pre-activation read-back mismatch: $($row.Label). Expected AC=$($row.AC), DC=$($row.DC); actual AC=$actualAC, DC=$actualDC."
        }
    }

    Invoke-PowerCfg -Arguments @('/setactive', $newGuid) | Out-Null
    Start-Sleep -Milliseconds 1500

    $activeGuid = Get-GuidFromText (Invoke-PowerCfg -Arguments @('/getactivescheme')).Text
    if ($activeGuid -ne $newGuid) {
        throw "Activation verification failed. Expected $newGuid; active $activeGuid."
    }

    if (-not $KeepPowerMode) {
        $modeCheck = Get-UserPowerModes
        if ($modeCheck.AC -ne $neutralPowerMode.ToString() -or
            $modeCheck.DC -ne $neutralPowerMode.ToString()) {
            throw 'Windows or OEM software changed the user power mode after plan activation.'
        }
    }

    # A mismatch is reported once. Critical mismatches abort and roll back;
    # the script does not repeatedly force values against an OEM policy writer.
    $criticalMismatch = $false
    foreach ($row in $supportedRows) {
        $final = Read-PowerSettingPair $newGuid $row.Group $row.Setting
        if ($null -eq $final -or $final.AC -ne $row.AC -or $final.DC -ne $row.DC) {
            $actualAC = if ($null -eq $final) { 'unavailable' } else { [string]$final.AC }
            $actualDC = if ($null -eq $final) { 'unavailable' } else { [string]$final.DC }
            $message = "Post-activation normalization: $($row.Label). Expected AC=$($row.AC), DC=$($row.DC); actual AC=$actualAC, DC=$actualDC."
            if ($row.Critical) {
                Write-Warning $message
                $criticalMismatch = $true
            }
            else {
                Write-Warning ($message + ' Optional setting left as normalized by Windows/OEM.')
            }
        }
    }
    if ($criticalMismatch) {
        throw 'A critical value changed after activation. The plan is being rolled back instead of repeatedly forcing it.'
    }

    $state.Status = 'Applied'
    $state | Export-Clixml -LiteralPath $stateFile
    (Invoke-PowerCfg -Arguments @('/qh', $newGuid)).Text |
        Set-Content -LiteralPath (Join-Path $backupFolder 'applied-settings.txt')

    Write-Host ''
    Write-Host 'Applied and verified: Dell G15 - Daily Low Power r14' -ForegroundColor Green
    Write-Host "Plan GUID       : $newGuid"
    Write-Host "EPP AC / DC     : $EppAC / $EppDC"
    Write-Host 'Scheduler       : Automatic / Automatic (5 / 5)'
    Write-Host 'CPU maximum     : 99% AC / DC'
    Write-Host 'Boost           : Disabled'
    Write-Host "Restore state   : $stateFile"
    Write-Host 'No resident process was installed. Close this PowerShell window before measuring idle.'
    Write-Host ''
    Write-Host ("Restore: & `"{0}`" -RestoreFrom `"{1}`"" -f $PSCommandPath, $stateFile) -ForegroundColor Yellow
}
catch {
    $failure = $_
    try {
        Invoke-PowerCfg -Arguments @('/setactive', $previousGuid) | Out-Null
    }
    catch {
        Write-Warning ('Power-plan rollback failed: ' + $_.Exception.Message)
    }

    if (-not $KeepPowerMode -and $null -ne $previousModes) {
        try {
            Set-UserPowerModes -AC ([guid]$previousModes.AC) -DC ([guid]$previousModes.DC)
        }
        catch {
            Write-Warning ('Windows power-mode rollback failed: ' + $_.Exception.Message)
        }
    }

    if ($newPlanCreated -and (Test-PowerSchemeExists $newGuid)) {
        try {
            $activeNow = Get-GuidFromText (Invoke-PowerCfg -Arguments @('/getactivescheme')).Text
            if ($activeNow -ne $newGuid) {
                Invoke-PowerCfg -Arguments @('/delete', $newGuid) | Out-Null
            }
        }
        catch {
            Write-Warning ('Partial managed-plan cleanup failed: ' + $_.Exception.Message)
        }
    }

    try {
        $state.Status = 'Failed'
        $state | Export-Clixml -LiteralPath $stateFile
    }
    catch {
        Write-Warning ('Could not update failure state: ' + $_.Exception.Message)
    }
    Write-Warning ("Restore state: $stateFile")
    throw $failure
}
