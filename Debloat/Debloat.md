# G15 Debloat

Two independent tools for auditing and trimming optional Windows/Dell
components on the G15 5530. Run the audit first; it's what the debloat
script's target list was built from.

This debloat has been specifically tailored to my laptop's current state.

To get the most optimal results, please run the audit and look through the
output folder. I'd suggest first running both [CTT's WinUtil](https://github.com/ChrisTitusTech/winutil) and then
[Raphire's debloat script](https://github.com/Raphire/Win11Debloat), in that order, and then doing the remaining
cleanup with the help of this script.

Maybe use an LLM, or remove/disable
services. If you're good at it and know what you're doing, you can do it
manually aswell but still, better to use a good llm to make sure you don't
mess up real big. (Friendly reminder, don't mess with edge or microsoft
store. )

**However**, be cautious about what you tweak. You might end up
blowing up your system.

## 1. Audit (read-only)

```powershell
Set-Location "C:\code\dell-g15-power-optimizer\Debloat"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\Debloat-audit.ps1
```

Exports `Services.csv`, `Scheduled-Tasks.csv`, `Startup-Programs.csv`, and
`Running-Processes.csv` to `%USERPROFILE%\Desktop\Windows-Debloat-Audit`,
then opens that folder alongside Services, Task Manager, and Task
Scheduler so you can cross-check the CSVs against what Windows shows live.
This script makes no changes to the system.

## 2. Debloat (reversible)

`G15-Precision-Debloat.ps1` targets a small, specific set of optional
components: the NVIDIA App background container/PresentMon, Windows
cross-device resume, consumer-content promotion, Recall, Click to Do, and
two nonessential Office background tasks. It does not touch Appx packages,
drivers, services, scheduled tasks, or user data, and it reports (without
changing) OEM-protected and Windows-protected items it finds.

```powershell
Set-Location "C:\code\dell-g15-power-optimizer\Debloat"
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

.\G15-Precision-Debloat.ps1 -Preview        # see what would change
.\G15-Precision-Debloat.ps1 -Apply          # apply it (backs up state first)
.\G15-Precision-Debloat.ps1 -Diagnose       # check current state
.\G15-Precision-Debloat.ps1 -RestoreLatest  # undo the most recent Apply
```

`Run-Debloat.ps1` runs `-Preview` then `-Apply` back to back for a quick
one-shot run.

State backups are written under `%ProgramData%\G15-Precision-Debloat`, mirroring
how the Power scripts back up under `%ProgramData%\G15-Low-Power-Master`.