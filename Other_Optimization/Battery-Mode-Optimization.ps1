Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WindowsPowerMode {
    [DllImport("powrprof.dll")]
    public static extern uint PowerSetUserConfiguredACPowerMode(ref Guid mode);

    [DllImport("powrprof.dll")]
    public static extern uint PowerSetUserConfiguredDCPowerMode(ref Guid mode);

    [DllImport("powrprof.dll")]
    public static extern uint PowerGetUserConfiguredACPowerMode(out Guid mode);

    [DllImport("powrprof.dll")]
    public static extern uint PowerGetUserConfiguredDCPowerMode(out Guid mode);
}
'@

$bestEfficiency = [guid]'961cc777-2547-4f9d-8174-7d86181b8a7a'

$acResult = [WindowsPowerMode]::PowerSetUserConfiguredACPowerMode(
    [ref]$bestEfficiency
)

$dcResult = [WindowsPowerMode]::PowerSetUserConfiguredDCPowerMode(
    [ref]$bestEfficiency
)

if ($acResult -ne 0 -or $dcResult -ne 0) {
    throw "Failed to enable Best power efficiency. AC=$acResult DC=$dcResult"
}

$acMode = [guid]::Empty
$dcMode = [guid]::Empty

[void][WindowsPowerMode]::PowerGetUserConfiguredACPowerMode([ref]$acMode)
[void][WindowsPowerMode]::PowerGetUserConfiguredDCPowerMode([ref]$dcMode)

Write-Host "AC power mode: $acMode"
Write-Host "DC power mode: $dcMode"
Write-Host "Best power efficiency enabled successfully." -ForegroundColor Green