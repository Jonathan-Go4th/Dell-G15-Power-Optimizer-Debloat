# Run from an Administrator PowerShell window.

Set-Location $PSScriptRoot
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

.\G15-Precision-Debloat.ps1 -Preview
.\G15-Precision-Debloat.ps1 -Apply
