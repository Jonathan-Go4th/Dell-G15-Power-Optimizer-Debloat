#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    One-shot, read-only Dell G15 debloat audit. Writes reports and a ZIP only.
.DESCRIPTION
    Run before and after debloating to compare services, tasks, policies and power
    settings. Does not apply tweaks, launch monitoring tools, or poll the GPU.
    CPU samples are approximate activity measurements, not watts or C-state residency.
    Some protected/exiting processes may be unavailable; sample coverage is recorded.
.EXAMPLE
    .\Debloat-audit.ps1
.EXAMPLE
    .\Debloat-audit.ps1 -SampleSeconds 30 -OpenFolder
#>
[CmdletBinding()]
param(
    [string]$OutputRoot,
    [ValidateRange(1,60)][int]$SampleSeconds = 15,
    [switch]$OpenFolder
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not [Environment]::Is64BitProcess) { throw 'Run this audit in 64-bit Windows PowerShell as Administrator.' }
$AuditVersion = '1.3.0'
$capturedUtc = [DateTime]::UtcNow.ToString('o')
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'Desktop folder not found. Specify -OutputRoot with an existing parent location.' }
    $OutputRoot = Join-Path $desktop 'Windows-Debloat-Audit'
}
$folder = Join-Path $OutputRoot ((Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$auditErrors = New-Object System.Collections.Generic.List[string]
$auditSections = New-Object System.Collections.Generic.List[object]
function Invoke-AuditSection {
    param([string]$Name, [scriptblock]$Action)
    $errorsBefore = $auditErrors.Count
    $failure = $null
    try { & $Action }
    catch {
        $failure = $_.Exception.Message
        $auditErrors.Add("${Name}: $failure")
        Write-Warning "Could not fully collect $Name; other reports continue."
    }
    $auditSections.Add([pscustomobject]@{
        Section=$Name
        Status=$(if ($null -ne $failure) { 'Failed' } elseif ($auditErrors.Count -gt $errorsBefore) { 'Partial' } else { 'Collected' })
        ErrorCount=($auditErrors.Count-$errorsBefore)
    })
}

# Read each inventory once; keep the existing filenames for before/after comparisons.
Invoke-AuditSection 'services' {
    $services = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    $services | Select-Object Name,DisplayName,State,StartMode |
        Sort-Object StartMode,DisplayName |
        Export-Csv "$folder\Services.csv" -NoTypeInformation -Encoding UTF8
    $services | Select-Object Name,State,StartMode,ProcessId,PathName,StartName |
        Export-Csv "$folder\Services-Details.csv" -NoTypeInformation -Encoding UTF8
}
$taskInventory = @{ Tasks=@(); Collected=$false }
Invoke-AuditSection 'scheduled tasks' {
    $taskInventory.Tasks = @(Get-ScheduledTask -ErrorAction Stop)
    $taskInventory.Collected = $true
    $taskInventory.Tasks | Select-Object TaskPath,TaskName,State,
        @{Name='Enabled';Expression={$_.Settings.Enabled}},Author |
        Sort-Object TaskPath,TaskName |
        Export-Csv "$folder\Scheduled-Tasks.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'startup programs' {
    Get-CimInstance Win32_StartupCommand -ErrorAction Stop |
        Select-Object Name,Location,User,Command | Sort-Object Name |
        Export-Csv "$folder\Startup-Programs.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'running processes' {
    Get-Process -ErrorAction Stop | Select-Object ProcessName,Id,
        @{Name='CPUSeconds';Expression={if($null -ne $_.CPU){[math]::Round($_.CPU,2)}else{$null}}},
        @{Name='MemoryMB';Expression={[math]::Round($_.WorkingSet64 / 1MB,1)}} |
        Sort-Object CPUSeconds -Descending |
        Export-Csv "$folder\Running-Processes.csv" -NoTypeInformation -Encoding UTF8
}

# Extended read-only evidence. CPUSeconds above is cumulative since process start;
# the interval sample below better identifies activity at the time of this audit.
Invoke-AuditSection 'Windows version' {
    $build = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        CapturedUtc=$capturedUtc; AuditVersion=$AuditVersion
        PowerShellVersion=$PSVersionTable.PSVersion.ToString()
        Model=(Get-CimInstance Win32_ComputerSystem).Model
        CPU=((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)
        Edition=$build.EditionID; DisplayVersion=$build.DisplayVersion
        Build="$($build.CurrentBuildNumber).$($build.UBR)"
        LogicalProcessors=[Environment]::ProcessorCount
    } | Export-Csv "$folder\System.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'task activity' {
    if (-not $taskInventory.Collected) { throw 'Task inventory unavailable; task details were not collected.' }
    $rows = foreach ($task in $taskInventory.Tasks) {
        $info = $null
        try { $info = Get-ScheduledTaskInfo -InputObject $task -ErrorAction Stop }
        catch { $auditErrors.Add("Task info $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)") }
        [pscustomobject]@{
            TaskPath=$task.TaskPath; TaskName=$task.TaskName; State=$task.State
            Enabled=$task.Settings.Enabled; Author=$task.Author
            LastRunTime=if($info){$info.LastRunTime}else{$null}
            NextRunTime=if($info){$info.NextRunTime}else{$null}
            LastTaskResult=if($info){$info.LastTaskResult}else{$null}
            Actions=($task.Actions | ConvertTo-Json -Depth 5 -Compress)
            Triggers=($task.Triggers | ConvertTo-Json -Depth 5 -Compress)
        }
    }
    $rows | Export-Csv "$folder\Scheduled-Tasks-Details.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'process paths' {
    Get-CimInstance Win32_Process |
        Select-Object Name,ProcessId,ParentProcessId,ExecutablePath,CreationDate |
        Export-Csv "$folder\Process-Paths.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'recent updates' {
    Get-HotFix | Select-Object HotFixID,Description,InstalledOn |
        Export-Csv "$folder\Hotfixes.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'update events' {
    Get-WinEvent -FilterHashtable @{
        LogName='Microsoft-Windows-WindowsUpdateClient/Operational'
        StartTime=(Get-Date).AddDays(-30)
    } -MaxEvents 150 -ErrorAction Stop |
        Select-Object TimeCreated,Id,LevelDisplayName,Message |
        Export-Csv "$folder\Update-Events.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'policy values' {
    $keys = @(
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI',
        'HKCU:\Software\Microsoft\InputPersonalization',
        'HKCU:\Software\Microsoft\Siuf\Rules',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy',
        'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
    )
    $rows = foreach($path in $keys) {
        if(-not (Test-Path -LiteralPath $path)) { continue }
        $key = Get-Item -LiteralPath $path
        foreach($name in $key.GetValueNames()) {
            [pscustomobject]@{
                Path=$path; Name=$name; Kind=$key.GetValueKind($name)
                Value=$key.GetValue($name)
            }
        }
    }
    @($rows) | Export-Csv "$folder\Policies.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'pending restart' {
    [pscustomobject]@{
        ComponentServicing=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        WindowsUpdate=(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
    } | Export-Csv "$folder\Reboot-Indicators.csv" -NoTypeInformation -Encoding UTF8
}
Invoke-AuditSection 'power mode preferences' {
    Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' |
        Select-Object ActivePowerScheme,ActiveOverlayAcPowerScheme,ActiveOverlayDcPowerScheme |
        Export-Csv "$folder\Power-Mode-Registry.csv" -NoTypeInformation -Encoding UTF8
}
foreach($report in @(
    @{File='Power-Settings.txt'; Args=@('/qh','SCHEME_CURRENT')},
    @{File='Power-Active.txt'; Args=@('/getactivescheme')},
    @{File='Power-Requests.txt'; Args=@('/requests')},
    @{File='Power-WakeTimers.txt'; Args=@('/waketimers')},
    @{File='Power-SleepStates.txt'; Args=@('/a')}
)) {
    Invoke-AuditSection $report.File {
        & powercfg.exe @($report.Args) 2>&1 |
            Out-File -LiteralPath (Join-Path $folder $report.File) -Encoding utf8 -Width 4096
        if ($LASTEXITCODE -ne 0) { throw "powercfg returned $LASTEXITCODE" }
    }
}
Invoke-AuditSection 'process CPU interval sample' {
    Write-Host "Sampling CPU activity for $SampleSeconds seconds; leave the laptop untouched."
    $before = @{}
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $beforeSeen = 0; $beforeUnavailable = 0
    foreach($p in Get-Process -ErrorAction Stop) {
        $beforeSeen++
        try {
            $cpu = $p.CPU
            if ($null -eq $cpu) { $beforeUnavailable++; continue }
            $key = "$($p.Id)|$($p.StartTime.ToUniversalTime().Ticks)"
            $before[$key] = @{ CPU=[double]$cpu; Time=$timer.Elapsed.TotalSeconds }
        } catch { $beforeUnavailable++ }
    }
    Start-Sleep -Seconds $SampleSeconds
    $afterSeen = 0; $afterUnavailable = 0; $unmatched = 0
    $rows = @(foreach($p in Get-Process -ErrorAction Stop) {
        $afterSeen++
        try {
            $cpu = $p.CPU
            $sampleTime = $timer.Elapsed.TotalSeconds
            if ($null -eq $cpu) { $afterUnavailable++; continue }
            $key = "$($p.Id)|$($p.StartTime.ToUniversalTime().Ticks)"
            if (-not $before.ContainsKey($key)) { $unmatched++; continue }
            $elapsed = $sampleTime - $before[$key].Time
            if ($elapsed -le 0) { $afterUnavailable++; continue }
            $delta = [double]$cpu - $before[$key].CPU
            if ($delta -lt 0) { $afterUnavailable++; continue }
            [pscustomobject]@{
                ProcessName=$p.ProcessName; Id=$p.Id
                CPUSecondsDelta=[math]::Round($delta,4)
                CPUPercentOfMachine=[math]::Round(100*$delta/($elapsed*[Environment]::ProcessorCount),3)
                IntervalSeconds=[math]::Round($elapsed,3)
            }
        } catch { $afterUnavailable++ }
    })
    $timer.Stop()
    $rows | Sort-Object CPUSecondsDelta -Descending |
        Export-Csv "$folder\Process-CPU-Interval.csv" -NoTypeInformation -Encoding UTF8
    [pscustomobject]@{
        RequestedSeconds=$SampleSeconds; BeforeSeen=$beforeSeen; AfterSeen=$afterSeen
        MatchedProcesses=$rows.Count; BeforeUnavailable=$beforeUnavailable
        AfterUnavailable=$afterUnavailable; AfterWithoutBaseline=$unmatched
        LogicalProcessorsUsed=[Environment]::ProcessorCount
    } | Export-Csv "$folder\CPU-Sample-Coverage.csv" -NoTypeInformation -Encoding UTF8
}
$auditSections | Export-Csv "$folder\Audit-Sections.csv" -NoTypeInformation -Encoding UTF8
@('Read-only audit. Reports include local paths and account information; share privately.',
  'A Ready task is enabled, not continuously running. CPUSeconds is cumulative, not current load.',
  'This audit itself wakes the CPU; let the machine settle before measuring HWiNFO power.',
  'CPU sampling excludes exited processes and records unavailable/unmatched processes in CPU-Sample-Coverage.csv.',
  'Audit-Sections.csv distinguishes collected, partial and failed sections. Missing evidence is not a clean bill of health.',
  'Hotfixes and update events may not include every driver or feature update.',
  'Collection errors:') + @($auditErrors) |
    Out-File "$folder\READ-ME.txt" -Encoding utf8
$zip = "$folder.zip"
Compress-Archive -LiteralPath $folder -DestinationPath $zip

Write-Host "Audit saved to: $folder" -ForegroundColor Green
Write-Host "Audit archive: $zip" -ForegroundColor Green
if ($auditErrors.Count) {
    Write-Warning "$($auditErrors.Count) collection error(s). Review Audit-Sections.csv and READ-ME.txt in the ZIP."
}
Write-Host 'Allow the laptop to settle before taking your separate HWiNFO idle-power measurement.' 

# Opt-in only: no Task Manager, Services or Task Scheduler windows are launched.
if ($OpenFolder) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $folder) }
