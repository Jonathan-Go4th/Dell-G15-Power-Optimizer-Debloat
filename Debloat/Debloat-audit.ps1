$folder = "$env:USERPROFILE\Desktop\Windows-Debloat-Audit"
New-Item -ItemType Directory -Path $folder -Force | Out-Null

# Services shown in services.msc
Get-CimInstance Win32_Service |
    Select-Object Name, DisplayName, State, StartMode |
    Sort-Object StartMode, DisplayName |
    Export-Csv "$folder\Services.csv" -NoTypeInformation

# Scheduled tasks
Get-ScheduledTask |
    Select-Object TaskPath, TaskName, State,
        @{Name='Author'; Expression={$_.Author}} |
    Sort-Object TaskPath, TaskName |
    Export-Csv "$folder\Scheduled-Tasks.csv" -NoTypeInformation

# Programs configured to start with Windows
Get-CimInstance Win32_StartupCommand |
    Select-Object Name, Location, User, Command |
    Sort-Object Name |
    Export-Csv "$folder\Startup-Programs.csv" -NoTypeInformation

# Currently running processes
Get-Process |
    Select-Object ProcessName, Id,
        @{Name='CPUSeconds'; Expression={[math]::Round($_.CPU,2)}},
        @{Name='MemoryMB'; Expression={[math]::Round($_.WorkingSet64 / 1MB,1)}} |
    Sort-Object CPUSeconds -Descending |
    Export-Csv "$folder\Running-Processes.csv" -NoTypeInformation

Write-Host "Audit saved to: $folder" -ForegroundColor Green

# Open the audit folder and management interfaces
Start-Process explorer.exe $folder
Start-Process services.msc
Start-Process taskmgr.exe
Start-Process taskschd.msc