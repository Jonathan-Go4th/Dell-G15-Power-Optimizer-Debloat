#requires -Version 5.1

<#
.SYNOPSIS
    Aggressive, reversible telemetry and background-service debloat for a Dell G15 5530 running Windows 11.

.DESCRIPTION
    This script targets active optional components found in the audit:
      * Reports the OEM-protected Intel Graphics Software service but leaves it unchanged
      * Windows/OEM telemetry, diagnostic uploads, and optional background services
      * Supported diagnostic-data, cross-device, activity-history and consumer-content settings
      * Exact telemetry/feedback task targets and three optional Office tasks; protected tasks are reported

    It does not uninstall Appx packages, drivers, services, or scheduled tasks.
    It does not delete files or development tools.
    Apply journals only attempted changes and backs up their prior state.
    Each failed target is restored independently; successful debloating is retained.
    Failures are reported with a nonzero exit status. RestoreLatest explicitly undoes
    the latest run. Existing AllowTelemetry=0 is never raised during Apply.
    Recall policies remain read-only because changing them can delete snapshots.

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
    [string]$RestoreFrom
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.3.1'
$StateRoot = Join-Path $env:ProgramData 'G15-Precision-Debloat'

$ProtectedServiceNotes = @(
    [pscustomobject]@{
        Name        = 'IntelGraphicsSoftwareService'
        Reason      = 'OEM-protected on this machine (Access denied even when elevated); deliberately left unchanged.'
    }
)

# Explicit targets only. Missing services are skipped; no wildcard service disabling.
$AllServiceTargets = @(
    [pscustomobject]@{ Name='DiagTrack'; StartupType='Disabled'; Reason='Connected User Experiences and Telemetry collection/upload.' },
    [pscustomobject]@{ Name='diagnosticshub.standardcollector.service'; StartupType='Disabled'; Reason='Optional diagnostics hub collector; profiling sessions may need it.' },
    [pscustomobject]@{ Name='dptftcs'; StartupType='Disabled'; Reason='Intel Dynamic Tuning telemetry only; ipfsvc and thermal control preserved.' },
    [pscustomobject]@{ Name='InventorySvc'; StartupType='Disabled'; Reason='Inventory and compatibility appraisal collection; compatibility assessment reduced.' },
    [pscustomobject]@{ Name='wuqisvc'; StartupType='Disabled'; Reason='Microsoft Usage and Quality Insights collection.' },
    [pscustomobject]@{ Name='WerSvc'; StartupType='Disabled'; Reason='Windows crash/problem report collection and upload; automated error solutions unavailable.' },
    [pscustomobject]@{ Name='wercplsupport'; StartupType='Disabled'; Reason='Problem Reports Control Panel support.' },
    [pscustomobject]@{ Name='CDPSvc'; StartupType='Disabled'; Reason='Cross-device/nearby shared experiences; standalone Bluetooth and USB retained.' },
    [pscustomobject]@{ Name='MapsBroker'; StartupType='Disabled'; Reason='Downloaded offline maps management; automatic offline map updates disabled.' },
    [pscustomobject]@{ Name='RetailDemo'; StartupType='Disabled'; Reason='Retail demonstration mode.' },
    [pscustomobject]@{ Name='WMPNetworkSvc'; StartupType='Disabled'; Reason='Windows Media Player network media sharing.' },
    [pscustomobject]@{ Name='PushToInstall'; StartupType='Disabled'; Reason='Remote app push installation from other devices.' },
    [pscustomobject]@{ Name='PhoneSvc'; StartupType='Disabled'; Reason='Phone integration; Phone Link features may be unavailable.' },
    [pscustomobject]@{ Name='TrkWks'; StartupType='Disabled'; Reason='Tracking links to files across computers on a network.' },
    [pscustomobject]@{ Name='wisvc'; StartupType='Disabled'; Reason='Windows Insider management; stable Windows Update retained.' },
    [pscustomobject]@{ Name='DellConnectedServiceDelivery'; StartupType='Disabled'; Reason='Optional Dell connected-service delivery; support integrations unavailable.' },
    [pscustomobject]@{ Name='DellTechHub'; StartupType='Disabled'; Reason='Optional Dell support/diagnostic backend; Dell support integrations unavailable.' },
    [pscustomobject]@{ Name='SupportAssistAgent'; StartupType='Disabled'; Reason='Optional Dell SupportAssist monitoring and remote support backend.' },
    [pscustomobject]@{ Name='DDVDataCollector'; StartupType='Disabled'; Reason='Dell Data Vault collection.' },
    [pscustomobject]@{ Name='DDVRulesProcessor'; StartupType='Disabled'; Reason='Dell Data Vault processing.' },
    [pscustomobject]@{ Name='DDVCollectorSvcApi'; StartupType='Disabled'; Reason='Dell Data Vault collector API.' }
)
$ServiceTargets = @($AllServiceTargets)

# These names are accepted only when restoring backups made by older versions.
# They are never included in a new Preview or Apply plan.
$LegacyRestoreServiceNames = @('NvContainerLocalSystem', 'NvTelemetryContainer')

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
    },
    [pscustomobject]@{
        Path   = '\Microsoft\Office\'
        Name   = 'Office Performance Monitor'
        Reason = 'Optional Office performance-monitoring task; updates and Click-to-Run are preserved.'
    }
)

# Exact path/name pairs. Update, security, certificate, driver and MDM tasks are excluded.
$TaskTargets += @(
    [pscustomobject]@{ Path='\Microsoft\Windows\Application Experience\'; Name='Microsoft Compatibility Appraiser'; Reason='Compatibility inventory/appraisal collection.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Application Experience\'; Name='Microsoft Compatibility Appraiser Exp'; Reason='Compatibility inventory/appraisal collection.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Application Experience\'; Name='ProgramDataUpdater'; Reason='Application inventory collection.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Application Experience\'; Name='MareBackup'; Reason='Application experience inventory task; compatibility assessment reduced.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Application Experience\'; Name='StartupAppTask'; Reason='Startup application inventory.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='Consolidator'; Reason='Customer Experience Improvement Program reporting.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='UsbCeip'; Reason='USB Customer Experience Improvement Program reporting.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='KernelCeipTask'; Reason='Legacy kernel Customer Experience Improvement Program reporting.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Feedback\Siuf\'; Name='DmClient'; Reason='Feedback solicitation.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Feedback\Siuf\'; Name='DmClientOnScenarioDownload'; Reason='Feedback scenario downloads.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Windows Error Reporting\'; Name='QueueReporting'; Reason='Queued crash and error report uploads.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\DiskDiagnostic\'; Name='Microsoft-Windows-DiskDiagnosticDataCollector'; Reason='Disk diagnostic data collection; disk repair tasks retained.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\DiskFootprint\'; Name='Diagnostics'; Reason='Storage diagnostic collection; Storage Sense retained.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Diagnosis\'; Name='Scheduled'; Reason='Scheduled diagnostic analysis; automatic troubleshooting reduced.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Diagnosis\'; Name='UnexpectedCodepath'; Reason='Unexpected-code-path diagnostics; automatic troubleshooting reduced.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Diagnosis\'; Name='RecommendedTroubleshootingScanner'; Reason='Recommended troubleshooting scanner.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\DUSM\'; Name='dusmtask'; Reason='Data usage statistics maintenance.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\PI\'; Name='Sqm-Tasks'; Reason='Software quality metrics.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Sustainability\'; Name='SustainabilityTelemetry'; Reason='Sustainability telemetry; power-plan settings retained.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Flighting\FeatureConfig\'; Name='UsageDataFlushing'; Reason='Feature usage data flushing.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Flighting\FeatureConfig\'; Name='UsageDataReceiver'; Reason='Feature usage data reception.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Flighting\FeatureConfig\'; Name='UsageDataReporting'; Reason='Feature usage reporting.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Flighting\FeatureConfig\'; Name='BootstrapUsageDataReporting'; Reason='Feature bootstrap usage reporting.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\PerformanceTrace\'; Name='ShowFeedbackToast'; Reason='Performance feedback prompts.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Maps\'; Name='MapsToastTask'; Reason='Offline maps notifications.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Maps\'; Name='MapsUpdateTask'; Reason='Offline maps updates.' },
    [pscustomobject]@{ Path='\Microsoft\Windows\Windows Media Sharing\'; Name='UpdateLibrary'; Reason='Media sharing library updates.' }
)

$ProtectedTaskNotes = @(
    [pscustomobject]@{
        Path   = '\Microsoft\Windows\UsageAndQualityInsights\'
        Name   = 'UsageAndQualityInsights-MaintenanceTask'
        Reason = 'Windows-protected on this machine; left unchanged. The associated wuqisvc service is targeted separately.'
    },
    [pscustomobject]@{
        Path   = '\Microsoft\Windows\WindowsAI\ClickToDo\'
        Name   = 'ModelCachingLimit'
        Reason = 'Windows-protected on this machine; left unchanged. Current Click to Do policy is reported below.'
    },
    [pscustomobject]@{
        Path   = '\Microsoft\Windows\WindowsAI\ClickToDo\'
        Name   = 'ModelCachingUpdate'
        Reason = 'Windows-protected on this machine; left unchanged. Current Click to Do policy is reported below.'
    }
)

# Diagnostic data: https://learn.microsoft.com/windows/privacy/configure-windows-diagnostic-data-in-your-organization
# Recall effects: https://learn.microsoft.com/windows/client-management/mdm/policy-csp-windowsai
# All = local setting supported on Home too; policy targets retain edition filtering.
$RegistryTargets = @(
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='EnableCdp'; Type='DWord'; Value=0; Editions='Business'; MinBuild=0; Reason='Disable cross-device shared experiences.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='EnableActivityFeed'; Type='DWord'; Value=0; Editions='Business'; MinBuild=0; Reason='Disable activity feed.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='PublishUserActivities'; Type='DWord'; Value=0; Editions='Business'; MinBuild=0; Reason='Disable publishing user activities.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name='UploadUserActivities'; Type='DWord'; Value=0; Editions='Business'; MinBuild=0; Reason='Disable uploading user activities.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableWindowsConsumerFeatures'; Type='DWord'; Value=1; Editions='Enterprise'; MinBuild=0; Reason='Disable consumer promotions and suggested app provisioning.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'; Name='DisableConsumerAccountStateContent'; Type='DWord'; Value=1; Editions='Enterprise'; MinBuild=0; Reason='Disable consumer account promotional content.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo'; Name='DisabledByGroupPolicy'; Type='DWord'; Value=1; Editions='Business'; MinBuild=0; Reason='Disable Windows advertising identifier.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='AllowTelemetry'; Type='DWord'; Value=1; Editions='Business'; MinBuild=0; Reason='Lowest supported diagnostic-data policy: 0 on Enterprise/Education, 1 on Pro.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='DoNotShowFeedbackNotifications'; Type='DWord'; Value=1; Editions='Business'; MinBuild=0; Reason='Suppress feedback requests.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='LimitDiagnosticLogCollection'; Type='DWord'; Value=1; Editions='Business'; MinBuild=22000; Reason='Block additional optional diagnostic log collection.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name='LimitDumpCollection'; Type='DWord'; Value=1; Editions='Business'; MinBuild=22000; Reason='Limit optional diagnostic dump collection.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppCompat'; Name='AITEnable'; Type='DWord'; Value=0; Editions='Business'; MinBuild=0; Reason='Turn off application impact telemetry.' },
    [pscustomobject]@{ Path='HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'; Name='Disabled'; Type='DWord'; Value=1; Editions='All'; MinBuild=0; Reason='Disable Windows Error Reporting.' },
    [pscustomobject]@{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'; Name='TailoredExperiencesWithDiagnosticDataEnabled'; Type='DWord'; Value=0; Editions='All'; MinBuild=0; Reason='Turn off diagnostic-data-based tailored experiences for this user.' },
    [pscustomobject]@{ Path='HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'; Name='Enabled'; Type='DWord'; Value=0; Editions='All'; MinBuild=0; Reason='Turn off advertising identifier for this user.' },
    [pscustomobject]@{ Path='HKCU:\Software\Microsoft\InputPersonalization'; Name='RestrictImplicitTextCollection'; Type='DWord'; Value=1; Editions='All'; MinBuild=0; Reason='Restrict implicit typing data collection for this user.' },
    [pscustomobject]@{ Path='HKCU:\Software\Microsoft\InputPersonalization'; Name='RestrictImplicitInkCollection'; Type='DWord'; Value=1; Editions='All'; MinBuild=0; Reason='Restrict implicit ink collection for this user.' },
    [pscustomobject]@{ Path='HKCU:\Software\Microsoft\Siuf\Rules'; Name='NumberOfSIUFInPeriod'; Type='DWord'; Value=0; Editions='All'; MinBuild=0; Reason='Disable feedback solicitation for this user.' },
    [pscustomobject]@{ Path='HKCU:\Software\Microsoft\Siuf\Rules'; Name='PeriodInNanoSeconds'; Type='DWord'; Value=0; Editions='All'; MinBuild=0; Reason='Set feedback solicitation frequency to never.' }
)

# Read-only: a reversible registry backup cannot recover deleted Recall snapshots.
$ReportedAIValues = @('DisableClickToDo', 'AllowRecallEnablement', 'DisableAIDataAnalysis')

function Get-CurrentUserSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-ApplicableRegistryTargets {
    $windows = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $business = $windows.EditionID -match '^(Professional|Enterprise|Education|IoTEnterprise)'
    $enterprise = $windows.EditionID -match '^(Enterprise|Education|IoTEnterprise)'
    foreach ($target in $RegistryTargets) {
        if ($target.MinBuild -gt [int]$windows.CurrentBuildNumber) { continue }
        if ($target.Editions -eq 'Business' -and -not $business) { continue }
        if ($target.Editions -eq 'Enterprise' -and -not $enterprise) { continue }
        $copy = $target.PSObject.Copy()
        if ($copy.Name -eq 'AllowTelemetry') {
            $copy.Value = if ($enterprise) { 0 } else { 1 }
            $existing = Get-RegistryValueState -Path $copy.Path -Name $copy.Name
            # Pro does not support diagnostic-data-off, but must not overwrite a
            # pre-existing stricter preference. This is not a zero-telemetry claim.
            if ($existing.ValueExists -and $existing.Kind -eq 'DWord' -and $existing.Value -eq 0) {
                $copy.Value = 0
            }
        }
        $copy
    }
}

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

function Get-PostUpdatePlan {
    Clear-TaskCache
    $script:PlanIssues = @()
    $computer = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    if ($computer.Model -notmatch 'G15\s+5530' -or $cpu.Name -notmatch 'i5-13450HX') {
        throw "This policy targets G15 5530 / i5-13450HX, detected $($computer.Model), $($cpu.Name)."
    }
    $plan = New-Object System.Collections.Generic.List[object]
    foreach ($target in $ServiceTargets) {
        $service = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) { continue }
        $mode = Get-ServiceStartupType -Name $target.Name
        if ($mode -eq $target.StartupType -and $service.Status -eq 'Stopped') { continue }
        $dependents = @($service.DependentServices | Where-Object { $_.Status -ne 'Stopped' })
        if ($dependents.Count -gt 0) {
            $message = "Skipped $($target.Name): running dependents: $($dependents.Name -join ', ')."
            $script:PlanIssues += $message
            Write-Warning $message
            continue
        }
        if ($service.Status -notin @('Running', 'Stopped')) {
            $message = "Skipped $($target.Name): wait for the service to settle, then retry."
            $script:PlanIssues += $message
            Write-Warning $message
            continue
        }
        $key = 'HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $target.Name
        $before = [pscustomobject]@{
            Name=$target.Name; StartupType=$mode; Status=$service.Status.ToString()
            DelayedAutoState=(Get-RegistryValueState -Path $key -Name 'DelayedAutoStart')
        }
        $plan.Add([pscustomobject]@{Kind='Service'; Name=$target.Name; Before=$before; Desired=$target.StartupType})
    }
    foreach ($target in $TaskTargets) {
        $task = Get-TaskOrNull -Path $target.Path -Name $target.Name
        if ($null -eq $task -or -not $task.Settings.Enabled) { continue }
        $before = [pscustomobject]@{Path=$target.Path; Name=$target.Name; Enabled=$true}
        $plan.Add([pscustomobject]@{Kind='Task'; Name=$target.Name; Before=$before; Desired='Disabled'})
    }
    foreach ($target in @(Get-ApplicableRegistryTargets)) {
        $before = Get-RegistryValueState -Path $target.Path -Name $target.Name
        if ($before.ValueExists -and $before.Kind -eq 'DWord' -and $before.Value -eq $target.Value) { continue }
        $plan.Add([pscustomobject]@{Kind='Registry'; Name=$target.Name; Before=$before; Desired=$target.Value})
    }
    return $plan.ToArray()
}

function Save-PostUpdateState {
    param([Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$File)
    $temp = "$File.tmp"
    $State | Export-Clixml -LiteralPath $temp -Depth 12
    $check = Import-Clixml -LiteralPath $temp
    if ($check.SchemaVersion -ne 2 -or $check.Id -ne $State.Id) { throw 'State backup verification failed.' }
    Move-Item -LiteralPath $temp -Destination $File -Force
}

function Assert-PostUpdateEntry {
    param([Parameter(Mandatory)]$Entry)
    switch ($Entry.Kind) {
        'Service' {
            if ($Entry.Name -notin @($AllServiceTargets.Name + $LegacyRestoreServiceNames) -or $Entry.Before.Name -ne $Entry.Name -or
                $Entry.Before.StartupType -notin @('Automatic','Manual','Disabled') -or
                $Entry.Before.Status -notin @('Running','Stopped') -or
                $Entry.Before.DelayedAutoState.Path -ne ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$Entry.Name) -or
                $Entry.Before.DelayedAutoState.Name -ne 'DelayedAutoStart') { throw 'Invalid service restore entry.' }
        }
        'Task' {
            if ($Entry.Name -notin @($TaskTargets | ForEach-Object Name) -or
                $Entry.Before.Name -ne $Entry.Name -or
                @($TaskTargets | Where-Object { $_.Path -eq $Entry.Before.Path -and $_.Name -eq $Entry.Name }).Count -ne 1) { throw 'Invalid task restore entry.' }
        }
        'Registry' {
            if ($Entry.Name -ne $Entry.Before.Name -or @($RegistryTargets | Where-Object { $_.Path -eq $Entry.Before.Path -and $_.Name -eq $Entry.Before.Name }).Count -ne 1) {
                throw 'Invalid registry restore entry.'
            }
        }
        default { throw 'Unknown restore entry.' }
    }
}

function Assert-EntryUnchanged {
    param([Parameter(Mandatory)]$Entry)
    Assert-PostUpdateEntry -Entry $Entry
    switch ($Entry.Kind) {
        'Service' {
            $service = Get-Service -Name $Entry.Name -ErrorAction Stop
            if ((Get-ServiceStartupType $Entry.Name) -ne $Entry.Before.StartupType -or
                $service.Status.ToString() -ne $Entry.Before.Status) {
                throw "Service $($Entry.Name) changed since planning; retry."
            }
            if (@($service.DependentServices | Where-Object { $_.Status -ne 'Stopped' }).Count) {
                throw "Service $($Entry.Name) now has running dependents; retry after closing them."
            }
            $actual = Get-RegistryValueState -Path $Entry.Before.DelayedAutoState.Path -Name 'DelayedAutoStart'
            $before = $Entry.Before.DelayedAutoState
        }
        'Task' {
            $task = Get-ScheduledTask -TaskPath $Entry.Before.Path -TaskName $Entry.Name -ErrorAction Stop
            if ([bool]$task.Settings.Enabled -ne [bool]$Entry.Before.Enabled) {
                throw "Task $($Entry.Name) changed since planning; retry."
            }
            return
        }
        'Registry' {
            $actual = Get-RegistryValueState -Path $Entry.Before.Path -Name $Entry.Name
            $before = $Entry.Before
        }
    }
    if ($actual.ValueExists -ne $before.ValueExists -or
        ($actual.ValueExists -and ($actual.Kind -ne $before.Kind -or
        (ConvertTo-Json -InputObject $actual.Value -Compress) -ne (ConvertTo-Json -InputObject $before.Value -Compress)))) {
        throw "Registry state for $($Entry.Name) changed since planning; retry."
    }
}

function Invoke-PostUpdateEntry {
    param([Parameter(Mandatory)]$Entry)
    switch ($Entry.Kind) {
        'Service' {
            Assert-PostUpdateEntry -Entry $Entry
            $target = $AllServiceTargets | Where-Object Name -eq $Entry.Name | Select-Object -First 1
            if ($Entry.Desired -ne $target.StartupType) { throw 'Unexpected desired service startup.' }
            if ((Get-ServiceStartupType $Entry.Name) -ne $Entry.Desired) {
                Set-Service -Name $Entry.Name -StartupType $Entry.Desired -ErrorAction Stop
            }
            if ((Get-Service -Name $Entry.Name).Status -ne 'Stopped') { Stop-Service -Name $Entry.Name -ErrorAction Stop }
            (Get-Service -Name $Entry.Name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
            if ((Get-ServiceStartupType $Entry.Name) -ne $Entry.Desired) { throw "Service $($Entry.Name) startup did not verify." }
        }
        'Task' {
            $task = Get-ScheduledTask -TaskPath $Entry.Before.Path -TaskName $Entry.Name -ErrorAction Stop
            Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
            if ((Get-ScheduledTask -TaskPath $Entry.Before.Path -TaskName $Entry.Name).Settings.Enabled) { throw "Task $($Entry.Name) remained enabled." }
        }
        'Registry' {
            $target = $RegistryTargets | Where-Object { $_.Path -eq $Entry.Before.Path -and $_.Name -eq $Entry.Name } | Select-Object -First 1
            $target = $target.PSObject.Copy()
            $target.Value = $Entry.Desired
            Set-RegistryTarget -Target $target
            $actual = Get-RegistryValueState -Path $Entry.Before.Path -Name $Entry.Name
            if (-not $actual.ValueExists -or $actual.Kind -ne 'DWord' -or $actual.Value -ne $Entry.Desired) { throw 'Policy write did not verify.' }
        }
    }
}

function Restore-PostUpdateEntry {
    param([Parameter(Mandatory)]$Entry)
    switch ($Entry.Kind) {
        'Registry' {
            Restore-RegistryState -Item $Entry.Before
            $actual = Get-RegistryValueState -Path $Entry.Before.Path -Name $Entry.Name
            if ($actual.ValueExists -ne $Entry.Before.ValueExists -or
                ($actual.ValueExists -and ($actual.Kind -ne $Entry.Before.Kind -or
                (ConvertTo-Json -InputObject $actual.Value -Compress) -ne (ConvertTo-Json -InputObject $Entry.Before.Value -Compress)))) {
                throw 'Registry restoration did not verify.'
            }
        }
        'Task' {
            $task = Get-ScheduledTask -TaskPath $Entry.Before.Path -TaskName $Entry.Name -ErrorAction Stop
            if ($Entry.Before.Enabled) { Enable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null }
            else { Disable-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null }
            $actual = Get-ScheduledTask -TaskPath $Entry.Before.Path -TaskName $Entry.Name
            if ([bool]$actual.Settings.Enabled -ne [bool]$Entry.Before.Enabled) { throw 'Task restoration did not verify.' }
        }
        'Service' {
            $startupForRestore = if ($Entry.Before.StartupType -eq 'Disabled' -and $Entry.Before.Status -eq 'Running') { 'Manual' } else { $Entry.Before.StartupType }
            Set-Service -Name $Entry.Name -StartupType $startupForRestore -ErrorAction Stop
            Restore-RegistryState -Item $Entry.Before.DelayedAutoState
            if ($Entry.Before.Status -eq 'Running' -and (Get-Service $Entry.Name).Status -ne 'Running') {
                Start-Service $Entry.Name -ErrorAction Stop
            }
            if ($Entry.Before.Status -eq 'Stopped' -and (Get-Service $Entry.Name).Status -ne 'Stopped') {
                Stop-Service $Entry.Name -ErrorAction Stop
            }
            (Get-Service $Entry.Name).WaitForStatus($Entry.Before.Status,[TimeSpan]::FromSeconds(15))
            if ($startupForRestore -ne $Entry.Before.StartupType) {
                Set-Service -Name $Entry.Name -StartupType $Entry.Before.StartupType -ErrorAction Stop
            }
            if ((Get-ServiceStartupType $Entry.Name) -ne $Entry.Before.StartupType) { throw 'Service restoration did not verify.' }
        }
    }
}

function Restore-PostUpdateState {
    param([Parameter(Mandatory)][string]$StateFile)
    $state = Import-Clixml -LiteralPath $StateFile
    if ($state.SchemaVersion -ne 2 -or $state.ComputerName -ne $env:COMPUTERNAME) { throw 'Backup schema or computer mismatch.' }
    if ($state.Restored) { Write-Host 'This backup was already restored.'; return }
    foreach ($entry in $state.Entries) { Assert-PostUpdateEntry -Entry $entry }
    if (@($state.Entries | Where-Object { $_.Kind -eq 'Registry' -and $_.Before.Path -like 'HKCU:*' }).Count -gt 0) {
        if (-not $state.PSObject.Properties['UserSid'] -or $state.UserSid -ne (Get-CurrentUserSid)) {
            throw 'This backup contains user settings; restore it using the same Windows account that applied it.'
        }
    }
    $indices = @($state.Attempted)
    [array]::Reverse($indices)
    foreach ($i in $indices) {
        if ([int]$i -lt 0 -or [int]$i -ge @($state.Entries).Count) { throw 'Invalid journal index.' }
    }
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($i in $indices) {
        try { Restore-PostUpdateEntry -Entry $state.Entries[[int]$i] }
        catch { $errors.Add("$($state.Entries[[int]$i].Name): $($_.Exception.Message)") }
    }
    if ($errors.Count) { throw ("Restore incomplete; keep backup and retry:`n" + ($errors -join "`n")) }
    $state.Restored = $true
    $state.Result = 'Restored'
    Save-PostUpdateState -State $state -File $StateFile
    Write-Host "Restored and verified: $StateFile" -ForegroundColor Green
    Write-Host 'Restart Windows before measuring again.'
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

function Restore-LegacyState {
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

function Restore-State {
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { throw "Backup not found: $StateFile" }
    $state = Import-Clixml -LiteralPath $StateFile
    if ($state.SchemaVersion -eq 2) { Restore-PostUpdateState -StateFile $StateFile; return }
    if ($state.SchemaVersion -eq 1) {
        Write-Warning 'Restoring a legacy v1 backup will replay all targets captured by that older script.'
        Restore-LegacyState -StateFile $StateFile
        return
    }
    throw "Unsupported backup schema $($state.SchemaVersion)."
}

function Show-Plan {
    Write-Section 'Dell G15 5530 - aggressive telemetry debloat (preview)'

    $edition = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    Write-Host "Script version : $ScriptVersion"
    Write-Host "Windows edition: $edition"
    Write-Host 'NVIDIA App     : all NVIDIA services left unchanged'

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
        if ($startup -eq $target.StartupType -and $service.Status -eq 'Stopped') {
            Write-Host ('  {0}: {1}/{2} -> ALREADY CONFIGURED' -f $target.Name, $startup, $service.Status)
        }
        else {
            Write-Host ('  {0}: {1}/{2} -> {3}/Stopped' -f $target.Name, $startup, $service.Status, $target.StartupType)
        }
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
    $applicable = @(Get-ApplicableRegistryTargets)
    foreach ($target in $applicable) {
        $old = Get-RegistryValueState -Path $target.Path -Name $target.Name
        $oldText = if ($old.ValueExists) { [string]$old.Value } else { '<not configured>' }
        Write-Host ('  {0}\{1}: {2} -> {3}' -f $target.Path, $target.Name, $oldText, $target.Value)
        Write-Host ('    {0}' -f $target.Reason) -ForegroundColor DarkGray
    }

    foreach ($target in $RegistryTargets) {
        if ($applicable.Name -notcontains $target.Name) {
            Write-Host "  [edition not supported; unchanged] $($target.Name)"
        }
    }
    $aiPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'
    foreach ($name in $ReportedAIValues) {
        $old = Get-RegistryValueState -Path $aiPath -Name $name
        $oldText = if ($old.ValueExists) { [string]$old.Value } else { '<not configured>' }
        Write-Host "  [report only] $name = $oldText"
    }

    Write-Host ''
    Write-Host 'Changes needed now (exact apply plan):' -ForegroundColor Cyan
    $planned = @(Get-PostUpdatePlan)
    Write-Host ("  {0} change(s); {1} services, {2} tasks, {3} registry values." -f $planned.Count,
        @($planned | Where-Object Kind -eq 'Service').Count,
        @($planned | Where-Object Kind -eq 'Task').Count,
        @($planned | Where-Object Kind -eq 'Registry').Count)
    foreach ($entry in $planned) { Write-Host ("  {0}: {1} -> {2}" -f $entry.Kind,$entry.Name,$entry.Desired) }
    Write-Host '  Missing targets are skipped; protected targets are reported without bypassing permissions.'
    Write-Host '  Successful changes are retained if another target fails. Only that failed target is rolled back.'
    Write-Host '  RestoreLatest/RestoreFrom intentionally undo debloating; use only when you want to revert.'
    Write-Host '  Disabling services removes their background activity; installed components remain available for rollback.'
    Write-Host '  This is a configured-target check, not a network-level proof of zero telemetry.'
    Write-Host ''
    Write-Host 'Deliberately preserved:' -ForegroundColor Cyan
    Write-Host '  Defender, Firewall, Windows Update, Edge/Office update tasks'
    Write-Host '  Intel Innovation Platform Framework, Intel audio/HDCP, Wi-Fi services'
    Write-Host '  NVIDIA App services, display driver and Control Panel container'
    Write-Host '  Dell thermal/power components, Realtek/Dolby audio, Bluetooth and USB'
    Write-Host '  Hyper-V, WSL, Host Network Service and virtualization networking'
    Write-Host '  Sleep, hibernation, Task Scheduler, indexing state, drivers and Appx packages'

}

function Invoke-Apply {
    Assert-Administrator
    Show-Plan

    $plan = @(Get-PostUpdatePlan)
    Write-Section 'Applying'
    Write-Host "Planned changes: $($plan.Count)"
    foreach ($entry in $plan) { Write-Host ("  {0}: {1} -> {2}" -f $entry.Kind, $entry.Name, $entry.Desired) }
    if ($plan.Count -eq 0) {
        if ($script:PlanIssues.Count) { throw ($script:PlanIssues -join [Environment]::NewLine) }
        Write-Host 'Already configured; no backup needed.'
        return
    }
    $id = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8)
    $directory = Join-Path $StateRoot $id
    New-Item -Path $directory -ItemType Directory -Force | Out-Null
    $stateFile = Join-Path $directory 'state.xml'
    $state = [pscustomobject]@{
        SchemaVersion=2; ScriptVersion=$ScriptVersion; Id=$id
        CreatedUtc=[DateTime]::UtcNow.ToString('o')
        ComputerName=$env:COMPUTERNAME; UserSid=(Get-CurrentUserSid); Entries=$plan
        Attempted=@(); Restored=$false; Result='Prepared'; Failures=@($script:PlanIssues)
    }
    Save-PostUpdateState -State $state -File $stateFile
    Write-Host "Backup: $stateFile"
    for ($i=0; $i -lt $plan.Count; $i++) {
        # Validate BEFORE journaling: a stale plan must not restore over newer settings.
        try { Assert-EntryUnchanged -Entry $plan[$i] }
        catch {
            $message = "$($plan[$i].Name): $($_.Exception.Message)"
            $state.Failures += $message
            Write-Warning $message
            Save-PostUpdateState -State $state -File $stateFile
            continue
        }
        $state.Attempted = @($state.Attempted) + $i
        $state.Result = 'Applying'
        # If journal persistence fails, abort BEFORE touching the target.
        Save-PostUpdateState -State $state -File $stateFile
        try { Invoke-PostUpdateEntry -Entry $plan[$i] }
        catch {
            $message = "$($plan[$i].Name): $($_.Exception.Message)"
            try {
                # Never undo unrelated successful debloating because one target failed.
                Restore-PostUpdateEntry -Entry $plan[$i]
                $state.Attempted = @($state.Attempted | Where-Object { $_ -ne $i })
                $message += ' Only this target was restored.'
            }
            catch { $message += " Target rollback incomplete: $($_.Exception.Message)" }
            $state.Failures += $message
            Write-Warning $message
        }
        Save-PostUpdateState -State $state -File $stateFile
    }
    $state.Result = if ($state.Failures.Count) { 'AppliedWithFailures' } else { 'Applied' }
    Save-PostUpdateState -State $state -File $stateFile
    if ($state.Failures.Count) {
        throw ("Completed with failures; successful changes retained. Backup: $stateFile`n" + ($state.Failures -join "`n"))
    }
    Write-Host 'Applied and verified.' -ForegroundColor Green
    Write-Host "Restore state: $stateFile"
    Write-Host 'Restart once before measuring idle power.' -ForegroundColor Yellow
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
    Write-Host ''
    Write-Host 'This diagnosis does not call nvidia-smi and does not poll the GPU.' -ForegroundColor DarkGray
}

try {
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell for the native registry and services.' }
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
            $latest = $null
            foreach ($file in @(Get-ChildItem -LiteralPath $StateRoot -Filter 'state.xml' -File -Recurse |
                Sort-Object LastWriteTimeUtc -Descending)) {
                $saved = Import-Clixml -LiteralPath $file.FullName
                if ($saved.SchemaVersion -eq 2 -and -not $saved.Restored -and @($saved.Attempted).Count -gt 0) {
                    $latest = $file
                    break
                }
            }
            if ($null -eq $latest) {
                throw "No unrestored journaled changes were found under $StateRoot; use -RestoreFrom with an exact older state.xml path if needed."
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
