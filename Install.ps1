<#
.SYNOPSIS
    Installs the "Open in Google Sheets / Docs / Slides" right-click menu.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install.ps1 -ClientJson "C:\Users\You\Downloads\client_secret_12345.apps.googleusercontent.com.json"

    No admin rights needed: everything is registered per-user (HKCU).
#>
param(
    [string]$ClientJson  # path to the OAuth client JSON downloaded from Google Cloud
)

$ErrorActionPreference = 'Stop'

$AppDir = Join-Path $env:LOCALAPPDATA 'OpenInGoogle'
New-Item -ItemType Directory -Force -Path $AppDir | Out-Null

$workerSrc = Join-Path $PSScriptRoot 'Open-InGoogle.ps1'
if (-not (Test-Path $workerSrc)) { throw "Open-InGoogle.ps1 not found next to Install.ps1." }
Copy-Item $workerSrc (Join-Path $AppDir 'Open-InGoogle.ps1') -Force

if ($ClientJson) {
    if (-not (Test-Path $ClientJson)) { throw "Client JSON not found: $ClientJson" }
    $j = Get-Content $ClientJson -Raw | ConvertFrom-Json
    $cred = $j.installed
    if (-not $cred) { $cred = $j.web }
    if (-not $cred -or -not $cred.client_id) { throw 'Could not find client_id in that JSON file.' }
    @{ client_id = $cred.client_id; client_secret = $cred.client_secret } |
        ConvertTo-Json | Set-Content (Join-Path $AppDir 'config.json')
    Write-Host 'Google credentials saved.'
} elseif (-not (Test-Path (Join-Path $AppDir 'config.json'))) {
    Write-Host 'NOTE: no -ClientJson given and no existing config found.'
    Write-Host 'Run again with -ClientJson "<path to downloaded JSON>" (see SETUP.md step 5).'
}

$worker = Join-Path $AppDir 'Open-InGoogle.ps1'

$entries = @(
    @{ Ext = '.xlsx'; Label = 'Open in Google Sheets' }
    @{ Ext = '.xls';  Label = 'Open in Google Sheets' }
    @{ Ext = '.csv';  Label = 'Open in Google Sheets' }
    @{ Ext = '.docx'; Label = 'Open in Google Docs'   }
    @{ Ext = '.doc';  Label = 'Open in Google Docs'   }
    @{ Ext = '.pptx'; Label = 'Open in Google Slides' }
    @{ Ext = '.ppt';  Label = 'Open in Google Slides' }
)

foreach ($e in $entries) {
    $shellKey = "HKCU:\Software\Classes\SystemFileAssociations\$($e.Ext)\shell\OpenInGoogle"
    New-Item -Path $shellKey -Force | Out-Null
    Set-Item -Path $shellKey -Value $e.Label
    $cmdKey = "$shellKey\command"
    New-Item -Path $cmdKey -Force | Out-Null
    Set-Item -Path $cmdKey -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$worker`" -FilePath `"%1`""
}

Write-Host ''
Write-Host 'Done! Right-click any Excel, Word, PowerPoint or CSV file anywhere on your PC'
Write-Host 'and choose "Open in Google Sheets / Docs / Slides".'
Write-Host 'The first run will open your browser once to sign in with Google.'
