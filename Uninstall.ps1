<#
.SYNOPSIS
    Removes the "Open in Google Sheets / Docs / Slides" right-click menu.
    Your uploaded files stay in Google Drive; run this if you want a clean removal:
        powershell -ExecutionPolicy Bypass -File .\Uninstall.ps1 -RemoveAppData
#>
param([switch]$RemoveAppData)

$ErrorActionPreference = 'SilentlyContinue'

foreach ($ext in '.xlsx', '.xls', '.csv', '.docx', '.doc', '.pptx', '.ppt') {
    Remove-Item -Path "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\OpenInGoogle" -Recurse -Force
}

if ($RemoveAppData) {
    Remove-Item -Path (Join-Path $env:LOCALAPPDATA 'OpenInGoogle') -Recurse -Force
    Write-Host 'Removed context menu entries and local app data (sign-in tokens included).'
} else {
    Write-Host 'Removed context menu entries.'
    Write-Host 'Your uploaded files stay in Google Drive. Re-run with -RemoveAppData to also delete local sign-in tokens.'
}
