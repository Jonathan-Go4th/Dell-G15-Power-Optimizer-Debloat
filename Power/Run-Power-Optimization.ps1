# Run from an Administrator PowerShell window.
# Applies the daily low-power plan, then layers the Windows "Best power
# efficiency" mode on top so both optimizations end up active together.

Set-Location $PSScriptRoot
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

Unblock-File ".\G15-Power-Optimization.ps1"
Unblock-File ".\Battery-Mode-Optimization.ps1"

# Check the current configuration first.
.\G15-Power-Optimization.ps1 -Preview

# Apply the power plan. This resets Windows' power mode to neutral/Balanced
# as part of applying, so Battery-Mode-Optimization.ps1 must run AFTER it.
.\G15-Power-Optimization.ps1 -Apply

# Layer the battery-optimizing mode on top (sets Windows power mode to
# "Best power efficiency" for AC and DC).
.\Battery-Mode-Optimization.ps1
