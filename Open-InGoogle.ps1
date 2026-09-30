<#
.SYNOPSIS
    Right-click helper: uploads an Office/CSV file to Google Drive,
    converts it to the native Google format, and opens it in
    Google Sheets / Docs / Slides in the default browser.

    Called from the Windows Explorer context menu as:
        powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden \
            -File "Open-InGoogle.ps1" -FilePath "%1"

    Dedup strategy: the script remembers which Drive file belongs to which
    local file (filemap.json). A Drive search by filename is only a fallback,
    because Drive search has proven unreliable for finding existing files.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath
)

$ErrorActionPreference = 'Stop'

$AppDir     = Join-Path $env:LOCALAPPDATA 'OpenInGoogle'
$ConfigPath = Join-Path $AppDir 'config.json'
$TokenPath  = Join-Path $AppDir 'tokens.dat'
$LogPath    = Join-Path $AppDir 'open-in-google.log'
$MapPath    = Join-Path $AppDir 'filemap.json'

$DriveFolderName = 'OpenInGoogle'
$OAuthScope      = 'https://www.googleapis.com/auth/drive.file'

# Extension -> Google editor + MIME types (source -> converted)
$TypeMap = @{
    '.xlsx' = @{ Editor = 'spreadsheets';  SrcMime = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';       DstMime = 'application/vnd.google-apps.spreadsheet'  }
    '.xls'  = @{ Editor = 'spreadsheets';  SrcMime = 'application/vnd.ms-excel';                                                DstMime = 'application/vnd.google-apps.spreadsheet'  }
    '.csv'  = @{ Editor = 'spreadsheets';  SrcMime = 'text/csv';                                                                DstMime = 'application/vnd.google-apps.spreadsheet'  }
    '.docx' = @{ Editor = 'document';      SrcMime = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'; DstMime = 'application/vnd.google-apps.document'     }
    '.doc'  = @{ Editor = 'document';      SrcMime = 'application/msword';                                                      DstMime = 'application/vnd.google-apps.document'     }
    '.pptx' = @{ Editor = 'presentation';  SrcMime = 'application/vnd.openxmlformats-officedocument.presentationml.presentation'; DstMime = 'application/vnd.google-apps.presentation' }
    '.ppt'  = @{ Editor = 'presentation';  SrcMime = 'application/vnd.ms-powerpoint';                                           DstMime = 'application/vnd.google-apps.presentation' }
}

$script:Config = $null
$script:AccessToken = $null

function Write-Log([string]$Message) {
    try {
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -Path $LogPath -Value "$ts $Message" -ErrorAction SilentlyContinue
    } catch { }
}

function Show-Error([string]$Message) {
    Write-Log "ERROR: $Message"
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($Message, 'Open in Google', 'OK', 'Error') | Out-Null
    exit 1
}

function Protect-Bytes([byte[]]$Bytes) {
    Add-Type -AssemblyName System.Security
    return [System.Security.Cryptography.ProtectedData]::Protect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Unprotect-Bytes([byte[]]$Bytes) {
    Add-Type -AssemblyName System.Security
    return [System.Security.Cryptography.ProtectedData]::Unprotect(
        $Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function Save-Tokens($TokenResponse, $OldRefreshToken) {
    $refresh = $TokenResponse.refresh_token
    if (-not $refresh) { $refresh = $OldRefreshToken }
    if (-not $refresh) { throw 'Google did not return a refresh token.' }
    $obj = @{
        access_token  = $TokenResponse.access_token
        refresh_token = $refresh
        expires_at    = (Get-Date).AddSeconds([int]$TokenResponse.expires_in - 60).ToString('o')
    }
    $json = ($obj | ConvertTo-Json -Compress)
    [System.IO.File]::WriteAllBytes($TokenPath, (Protect-Bytes ([System.Text.Encoding]::UTF8.GetBytes($json))))
}

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    try { return $l.LocalEndpoint.Port } finally { $l.Stop() }
}

# Waits (on 127.0.0.1) for Google's OAuth redirect and returns the auth code.
# Uses raw TCP so no admin rights / URL ACL reservation is needed.
function Wait-ForOAuthCode([int]$Port) {
    $tcp = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $tcp.Start()
    try {
        for ($i = 0; $i -lt 10; $i++) {
            $iar = $tcp.BeginAcceptTcpClient($null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne(120000)) { throw 'Timed out waiting for Google sign-in.' }
            $client = $tcp.EndAcceptTcpClient($iar)
            try {
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $requestLine = $reader.ReadLine()
                $line = ''
                while ($line -ne $null -and $line -ne '') { $line = $reader.ReadLine() }

                $code = $null
                $err  = $null
                if ($requestLine -match 'GET\s+(\S+)') {
                    $target = $Matches[1]
                    if ($target -match '[?&]code=([^&\s]+)') { $code = [System.Uri]::UnescapeDataString($Matches[1]) }
                    if ($target -match '[?&]error=([^&\s]+)') { $err = $Matches[1] }
                }

                $html = '<html><body style="font-family:sans-serif;padding:40px"><h2>You are signed in.</h2><p>You can close this tab now.</p></body></html>'
                $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                $header = "HTTP/1.1 200 OK`r`nContent-Type: text/html; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nConnection: close`r`n`r`n"
                $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes, 0, $headerBytes.Length)
                $stream.Write($bodyBytes, 0, $bodyBytes.Length)
                $stream.Flush()

                if ($code -or $err) { return @{ Code = $code; Error = $err } }
            } finally { $client.Close() }
        }
        throw 'Google sign-in did not complete.'
    } finally { $tcp.Stop() }
}

function Start-OAuthFlow {
    $cfg  = $script:Config
    $port = Get-FreePort
    $redirectUri = "http://127.0.0.1:$port/"

    $authUrl = 'https://accounts.google.com/o/oauth2/v2/auth' +
        '?client_id='     + [System.Uri]::EscapeDataString($cfg.client_id) +
        '&redirect_uri='  + [System.Uri]::EscapeDataString($redirectUri) +
        '&response_type=code' +
        '&scope='         + [System.Uri]::EscapeDataString($OAuthScope) +
        '&access_type=offline&prompt=consent'

    Start-Process $authUrl
    $result = Wait-ForOAuthCode $port

    if ($result.Error) { throw "Google sign-in was not completed ($($result.Error))." }
    if (-not $result.Code) { throw 'Google did not return an authorization code.' }

    $body = @{
        code          = $result.Code
        client_id     = $cfg.client_id
        client_secret = $cfg.client_secret
        redirect_uri  = $redirectUri
        grant_type    = 'authorization_code'
    }
    $tok = Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -Body $body
    Save-Tokens $tok $null
    return $tok.access_token
}

function Refresh-AccessToken([string]$RefreshToken) {
    $cfg = $script:Config
    $body = @{
        client_id     = $cfg.client_id
        client_secret = $cfg.client_secret
        refresh_token = $RefreshToken
        grant_type    = 'refresh_token'
    }
    $tok = Invoke-RestMethod -Uri 'https://oauth2.googleapis.com/token' -Method Post -Body $body
    Save-Tokens $tok $RefreshToken
    return $tok.access_token
}

function Get-AccessToken {
    $tok = $null
    if (Test-Path $TokenPath) {
        try {
            $json = [System.Text.Encoding]::UTF8.GetString((Unprotect-Bytes ([System.IO.File]::ReadAllBytes($TokenPath))))
            $tok = $json | ConvertFrom-Json
        } catch { $tok = $null }
    }
    if (-not $tok -or -not $tok.refresh_token) { return (Start-OAuthFlow) }
    $exp = [datetime]$tok.expires_at
    if ($exp -le (Get-Date).AddMinutes(1)) { return (Refresh-AccessToken $tok.refresh_token) }
    return $tok.access_token
}

function Get-HttpStatusCode($ErrRecord) {
    foreach ($ex in @($ErrRecord.Exception, $ErrRecord.Exception.InnerException)) {
        if ($ex -and $ex.Response -and $ex.Response.StatusCode) {
            return [int]$ex.Response.StatusCode
        }
    }
    return $null
}

# Runs a Drive API action; on 401 refreshes the token once and retries.
function Invoke-DriveWithRefresh([scriptblock]$Action) {
    try {
        return (& $Action)
    } catch {
        if ((Get-HttpStatusCode $_) -eq 401) {
            Write-Log 'Got 401, refreshing access token and retrying.'
            $tok = $null
            $json = [System.Text.Encoding]::UTF8.GetString((Unprotect-Bytes ([System.IO.File]::ReadAllBytes($TokenPath))))
            $tok = $json | ConvertFrom-Json
            $script:AccessToken = Refresh-AccessToken $tok.refresh_token
            return (& $Action)
        }
        throw
    }
}

# ---- local map: full local path -> Drive file id (primary dedup, no search needed) ----
function Get-FileMap {
    if (Test-Path $MapPath) {
        try {
            $json = Get-Content $MapPath -Raw | ConvertFrom-Json
            $map = @{}
            foreach ($p in $json.PSObject.Properties) { $map[$p.Name] = $p.Value }
            return $map
        } catch {
            Write-Log "Could not read filemap.json, starting fresh: $($_.Exception.Message)"
        }
    }
    return @{}
}

function Save-FileMap($Map) {
    ($Map | ConvertTo-Json -Compress) | Set-Content $MapPath
}

function Test-DriveFileExists([string]$FileId) {
    try {
        $uri = "https://www.googleapis.com/drive/v3/files/$FileId`?fields=id"
        Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($script:AccessToken)" } | Out-Null
        return $true
    } catch {
        if ((Get-HttpStatusCode $_) -eq 404) { return $false }
        throw
    }
}

function Get-DriveFolderId {
    if ($script:Config.folder_id) { return $script:Config.folder_id }

    $q = "name='$DriveFolderName' and mimeType='application/vnd.google-apps.folder' and trashed=false"
    $uri = 'https://www.googleapis.com/drive/v3/files?q=' + [System.Uri]::EscapeDataString($q) + '&fields=files(id)&pageSize=1'
    $res = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($script:AccessToken)" }
    $matches = @($res.files)  # @() : single JSON results unwrap to a scalar without it
    if ($matches.Count -gt 0) {
        $id = $matches[0].id
    } else {
        $body = @{ name = $DriveFolderName; mimeType = 'application/vnd.google-apps.folder' } | ConvertTo-Json -Compress
        $created = Invoke-RestMethod -Uri 'https://www.googleapis.com/drive/v3/files?fields=id' `
            -Method Post -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $($script:AccessToken)" } -Body $body
        $id = $created.id
    }
    $script:Config | Add-Member -NotePropertyName 'folder_id' -NotePropertyValue $id -Force
    ($script:Config | ConvertTo-Json) | Set-Content $ConfigPath
    return $id
}

function Find-ExistingFile([string]$FolderId, [string]$Name) {
    # Exact-match query first. Escape ' as \' per Drive query syntax.
    # NOTE: use .Replace (literal), not -replace (regex replacement patterns
    # silently double the backslash and the query becomes malformed).
    $safe = $Name.Replace("'", "\'")
    $q = "name='$safe' and '$FolderId' in parents and trashed=false"
    Write-Log "Find-ExistingFile query: $q"
    try {
        $uri = 'https://www.googleapis.com/drive/v3/files?q=' + [System.Uri]::EscapeDataString($q) + '&fields=files(id)&pageSize=1'
        $res = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($script:AccessToken)" }
        $matches = @($res.files)  # @() : single JSON results unwrap to a scalar without it
        if ($matches.Count -gt 0) {
            Write-Log "Find-ExistingFile: matched $($matches[0].id)"
            return $matches[0].id
        }
    } catch {
        Write-Log "Find-ExistingFile: exact query failed ($($_.Exception.Message)); trying client-side match."
    }
    # Fallback: list the folder and compare names locally. Sidesteps every
    # Drive query-escaping quirk (apostrophes, unicode, etc.).
    Write-Log 'Find-ExistingFile: trying client-side name match.'
    try {
        $bq = "'$FolderId' in parents and trashed=false"
        $buri = 'https://www.googleapis.com/drive/v3/files?q=' + [System.Uri]::EscapeDataString($bq) + '&fields=files(id,name)&pageSize=100'
        $bres = Invoke-RestMethod -Uri $buri -Headers @{ Authorization = "Bearer $($script:AccessToken)" }
        $bfiles = @($bres.files)
        foreach ($f in $bfiles) {
            if ($f.name -ieq $Name) {
                Write-Log "Find-ExistingFile: client-side matched $($f.id) (name='$($f.name)')"
                return $f.id
            }
        }
        $names = @($bfiles | ForEach-Object { $_.name }) -join '; '
        Write-Log "Diagnostic: folder lists $($bfiles.Count) file(s): $names"
    } catch {
        Write-Log "Diagnostic folder listing failed: $($_.Exception.Message)"
    }
    return $null
}

function New-ConvertedFile([string]$FolderId, [string]$LocalPath, [string]$Name, [string]$SrcMime, [string]$DstMime) {
    $meta = @{ name = $Name; mimeType = $DstMime; parents = @($FolderId) } | ConvertTo-Json -Compress
    $len = (Get-Item $LocalPath).Length
    # Resumable upload: start session, then PUT the bytes. Avoids multipart encoding issues.
    $sess = Invoke-WebRequest -Uri 'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable' `
        -Method Post -UseBasicParsing `
        -Headers @{ Authorization = "Bearer $($script:AccessToken)"; 'X-Upload-Content-Type' = $SrcMime; 'X-Upload-Content-Length' = "$len" } `
        -ContentType 'application/json; charset=UTF-8' -Body $meta
    $uploadUri = $sess.Headers['Location']
    if (-not $uploadUri) { throw 'Google Drive did not return an upload URL.' }
    $file = Invoke-RestMethod -Uri $uploadUri -Method Put -InFile $LocalPath -ContentType $SrcMime
    return $file.id
}

function Update-ConvertedFile([string]$FileId, [string]$LocalPath, [string]$SrcMime) {
    $uri = "https://www.googleapis.com/upload/drive/v3/files/$FileId`?uploadType=media&fields=id"
    $file = Invoke-RestMethod -Uri $uri -Method Patch -InFile $LocalPath -ContentType $SrcMime `
        -Headers @{ Authorization = "Bearer $($script:AccessToken)" }
    return $file.id
}

function Set-DriveFileName([string]$FileId, [string]$Name) {
    $uri = "https://www.googleapis.com/drive/v3/files/$FileId`?fields=id"
    $body = @{ name = $Name } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri $uri -Method Patch -ContentType 'application/json' `
        -Headers @{ Authorization = "Bearer $($script:AccessToken)" } -Body $body | Out-Null
}

function Log-CreatedFileDetails([string]$FileId) {
    try {
        $uri = "https://www.googleapis.com/drive/v3/files/$FileId`?fields=id,name,parents"
        $m = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = "Bearer $($script:AccessToken)" }
        Write-Log "Created file details: name='$($m.name)' parents=$($m.parents -join ',')"
    } catch {
        Write-Log "Could not read created file details: $($_.Exception.Message)"
    }
}

# ---------------- main ----------------
try {
    if (-not (Test-Path $FilePath)) { Show-Error "File not found:`n$FilePath" }

    $ext = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    if (-not $TypeMap.ContainsKey($ext)) { Show-Error "Unsupported file type: $ext" }
    $t = $TypeMap[$ext]

    if (-not (Test-Path $ConfigPath)) {
        Show-Error 'Not set up yet. Run Install.ps1 with your Google client JSON first (see SETUP.md).'
    }
    $script:Config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    if (-not $script:Config.client_id) { Show-Error 'config.json is missing client_id. Re-run Install.ps1.' }

    $script:AccessToken = Get-AccessToken
    $name = [System.IO.Path]::GetFileName($FilePath)

    $id = Invoke-DriveWithRefresh {
        $folderId = Get-DriveFolderId
        $map = Get-FileMap
        $targetId = $null

        # 1) Primary dedup: do we already know this local file's Drive id?
        if ($map.ContainsKey($FilePath)) {
            $candidate = [string]$map[$FilePath]
            Write-Log "Map hit for $FilePath -> $candidate, verifying it still exists."
            if (Test-DriveFileExists $candidate) {
                $targetId = $candidate
            } else {
                Write-Log "Mapped Drive file $candidate no longer exists; will create a new one."
                $map.Remove($FilePath)
            }
        }

        # 2) Fallback: search the folder by filename (kept for files uploaded
        #    before the map existed, or opened from another PC).
        if (-not $targetId) {
            $existingId = Find-ExistingFile $folderId $name
            if ($existingId) {
                $mappedElsewhere = $false
                foreach ($k in $map.Keys) {
                    if ([string]$map[$k] -eq $existingId -and $k -ne $FilePath) { $mappedElsewhere = $true; break }
                }
                if ($mappedElsewhere) {
                    Write-Log "Found Drive file $existingId belongs to a different local file; creating a new one."
                } else {
                    $targetId = $existingId
                }
            }
        }

        # 3) Update the existing Drive file, or create it.
        $newId = $null
        if ($targetId) {
            Write-Log "Updating existing Drive file $targetId for $name"
            try {
                Update-ConvertedFile $targetId $FilePath $t.SrcMime | Out-Null
                # Keep the Drive filename in sync if the local file was renamed.
                # Non-fatal: content is already updated at this point.
                try { Set-DriveFileName $targetId $name }
                catch { Write-Log "Rename after update failed (non-fatal): $($_.Exception.Message)" }
                $newId = $targetId
            } catch {
                if ((Get-HttpStatusCode $_) -eq 404) {
                    Write-Log 'Update target is gone (404); creating a new file instead.'
                    $targetId = $null
                } else {
                    throw  # surface real errors instead of silently duplicating
                }
            }
        }

        if (-not $targetId) {
            Write-Log "Uploading new file $name"
            $newId = New-ConvertedFile $folderId $FilePath $name $t.SrcMime $t.DstMime
            Log-CreatedFileDetails $newId
            $verify = Find-ExistingFile $folderId $name
            if ($verify) { Write-Log "Post-upload search found: $verify" }
            else { Write-Log 'Post-upload search found nothing (search may be lagging or broken).' }
        }

        $map[$FilePath] = $newId
        Save-FileMap $map
        return $newId
    }

    $url = "https://docs.google.com/$($t.Editor)/d/$id/edit"
    Write-Log "Opening $url"
    Start-Process $url
} catch {
    $msg = $_.Exception.Message
    if (-not $msg) { $msg = $_.ToString() }
    Show-Error ("Something went wrong:`n`n" + $msg + "`n`nDetails saved to:`n$LogPath")
}
