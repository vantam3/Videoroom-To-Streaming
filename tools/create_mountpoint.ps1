<#  create_mountpoint.ps1  —  FULL UPDATED
    Tạo RTP mountpoint cho Janus Streaming + log chi tiết để debug.
#>

param(
  [string]$JanusUrl = "http://127.0.0.1:8088",
  [string]$JanusApiSecret = "secret",

  [int]$Id = 7001,                        # ID bạn mong muốn (Janus có thể đổi)
  [string]$Name = "vr_live",
  [string]$Description = "Forward tu VideoRoom",

  [string]$RtpHost = "127.0.0.1",
  [ValidateRange(1,65535)][int]$AudioPort = 6004,
  [ValidateRange(1,65535)][int]$AudioRtcpPort = 6005,
  [ValidateRange(1,65535)][int]$VideoPort = 6006,
  [ValidateRange(1,65535)][int]$VideoRtcpPort = 6007,

  [ValidateRange(0,127)][int]$AudioPt = 111,   # Opus
  [ValidateRange(0,127)][int]$VideoPt = 96,    # VP8
  [string]$VideoRtpmap = "VP8/90000",
  [string]$AudioRtpmap = "opus/48000/2",

  [switch]$Force
)

function New-JanusTxn { [guid]::NewGuid().ToString("N") }

function Invoke-JanusRequest {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][hashtable]$Body
  )
  $json = $Body | ConvertTo-Json -Depth 10
  Invoke-RestMethod -Uri $Url -Method POST -ContentType "application/json" -Body $json
}

function Add-JanusApiSecret {
  param([hashtable]$Body)
  if ($JanusApiSecret -and $JanusApiSecret.Trim().Length -gt 0) { $Body.apisecret = $JanusApiSecret }
  $Body
}

Write-Host "JANUS_URL: $JanusUrl" -ForegroundColor Yellow

try {
  # --- Create session ---
  Write-Host "==> Creating Janus session..." -ForegroundColor Cyan
  $respCreate = Invoke-JanusRequest -Url "$JanusUrl/janus" -Body (Add-JanusApiSecret @{ janus="create"; transaction=(New-JanusTxn) })
  if ($respCreate.janus -ne 'success') { throw "Create session failed: $($respCreate.error.reason)" }
  $SID = $respCreate.data.id
  Write-Host "Session: $SID" -ForegroundColor Green

  # --- Attach plugin ---
  Write-Host "==> Attaching streaming plugin..." -ForegroundColor Cyan
  $respAttach = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID" -Body (Add-JanusApiSecret @{ janus="attach"; plugin="janus.plugin.streaming"; transaction=(New-JanusTxn) })
  if ($respAttach.janus -ne 'success') { throw "Attach failed: $($respAttach.error.reason)" }
  $HID = $respAttach.data.id
  Write-Host "Handle: $HID" -ForegroundColor Green

  # --- List mountpoints (trước) ---
  Write-Host "==> Listing mountpoints (pre)..." -ForegroundColor Cyan
  $respListPre = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID/$HID" -Body (Add-JanusApiSecret @{ janus="message"; transaction=(New-JanusTxn); body=@{ request="list" } })
  ($respListPre | ConvertTo-Json -Depth 10) | Write-Host

  $exists = $false
  if ($respListPre.plugindata.data.list) {
    foreach ($mp in $respListPre.plugindata.data.list) {
      if ($mp.id -eq $Id) { $exists = $true; break }
    }
  }

  if ($exists -and $Force) {
    Write-Host "==> Mountpoint $Id exists, destroying (Force)..." -ForegroundColor Yellow
    $respDel = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID/$HID" -Body (Add-JanusApiSecret @{
      janus="message"; transaction=(New-JanusTxn); body=@{ request="destroy"; id=$Id }
    })
    ($respDel | ConvertTo-Json -Depth 10) | Write-Host
    if ($respDel.janus -ne 'success') { throw "Destroy failed: $($respDel.error.reason)" }
    Write-Host "Destroyed." -ForegroundColor Green
    $exists = $false
  }

  # --- Create mountpoint ---
  if (-not $exists) {
    Write-Host "==> Creating RTP mountpoint id=$Id ($Name)..." -ForegroundColor Cyan
    $createMpBody = Add-JanusApiSecret @{
      janus="message"; transaction=(New-JanusTxn);
      body = @{
        request="create"; type="rtp"; id=$Id; name=$Name; description=$Description; is_private=$false
        video=$true; audio=$true
        videoip=$RtpHost;  videoport=$VideoPort;  videortcpport=$VideoRtcpPort;  videopt=$VideoPt;  videortpmap=$VideoRtpmap
        audioip=$RtpHost;  audioport=$AudioPort;  audiortcpport=$AudioRtcpPort;  audiopt=$AudioPt;  audiortpmap=$AudioRtpmap
      }
    }
    $respCreateMp = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID/$HID" -Body $createMpBody
    Write-Host "CREATE_RAW:" -ForegroundColor DarkGray
    ($respCreateMp | ConvertTo-Json -Depth 10) | Write-Host

    if ($respCreateMp.janus -ne 'success') {
      throw "Create FAILED (transport): code=$($respCreateMp.error.code) reason=$($respCreateMp.error.reason)"
    }
    $pd = $respCreateMp.plugindata
    $data = $pd.data
    if ($data.error_code -or $data.error) {
      throw ("Create FAILED (plugin): code={0} reason={1}" -f $data.error_code, $data.error)
    }

    # Lấy ID thực tế
    $ActualId = $null
    if ($data.stream -and $data.stream.id) { $ActualId = [int]$data.stream.id }
    elseif ($data.id)                       { $ActualId = [int]$data.id }
    else                                    { $ActualId = $Id }

    Write-Host ("Created OK. (actual id={0})" -f $ActualId) -ForegroundColor Green
  }
  else {
    $ActualId = $Id
    Write-Host ("Mountpoint {0} already exists (no Force)." -f $ActualId) -ForegroundColor Yellow
  }

  # --- Retry list() chờ mountpoint xuất hiện ---
  $maxRetry = 15
  $found = $false
  for ($i=1; $i -le $maxRetry; $i++) {
    Start-Sleep -Milliseconds 300
    $respList2 = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID/$HID" -Body (Add-JanusApiSecret @{
      janus="message"; transaction=(New-JanusTxn); body=@{ request="list" }
    })
    $mp = $respList2.plugindata.data.list | Where-Object { $_.id -eq $ActualId }
    if ($mp) { $found = $true; break }
    Write-Host ("Waiting for mountpoint {0} to appear... ({1}/{2})" -f $ActualId,$i,$maxRetry) -ForegroundColor DarkYellow
    if ($i -eq 5) { Start-Sleep -Milliseconds 500 }  # nới thêm chút ở mốc 5
  }

  Write-Host "LIST_RAW:" -ForegroundColor DarkGray
  ($respList2 | ConvertTo-Json -Depth 10) | Write-Host

  if ($found) {
    Write-Host "==> Ready. Mountpoint (from list):" -ForegroundColor Green
    $mp | ConvertTo-Json -Depth 10 | Write-Host
  } else {
    Write-Host ("WARN: mountpoint {0} not found after create (list)." -f $ActualId) -ForegroundColor Yellow
  }

  # --- INFO ---
  Write-Host "==> Getting mountpoint info..." -ForegroundColor Cyan
  $respInfo = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID/$HID" -Body (Add-JanusApiSecret @{
    janus="message"; transaction=(New-JanusTxn); body=@{ request="info"; id=$ActualId }
  })
  Write-Host "INFO_RAW:" -ForegroundColor DarkGray
  ($respInfo | ConvertTo-Json -Depth 10) | Write-Host

  if ($respInfo.janus -eq 'success') {
    $idata = $respInfo.plugindata.data
    if ($idata.error_code -or $idata.error) {
      Write-Host ("INFO error: code={0} reason={1}" -f $idata.error_code, $idata.error) -ForegroundColor Yellow
    } else {
      $info = $idata.info; if (-not $info) { $info = $idata }
      Write-Host ("Info: id={0} enabled={1} video={2} audio={3}" -f $info.id, $info.enabled, $info.video, $info.audio) -ForegroundColor Green
      $info | ConvertTo-Json -Depth 10 | Write-Host
    }
  } else {
    Write-Host "WARN: info failed: $($respInfo.error.reason)" -ForegroundColor Yellow
  }

  # --- ENABLE ---
  Write-Host "==> Enabling mountpoint..." -ForegroundColor Cyan
  $respEnable = Invoke-JanusRequest -Url "$JanusUrl/janus/$SID/$HID" -Body (Add-JanusApiSecret @{
    janus="message"; transaction=(New-JanusTxn); body=@{ request="enable"; id=$ActualId; enable=$true }
  })
  Write-Host "ENABLE_RAW:" -ForegroundColor DarkGray
  ($respEnable | ConvertTo-Json -Depth 10) | Write-Host

  if ($respEnable.janus -eq 'success' -and -not $respEnable.plugindata.data.error_code) {
    Write-Host ("Mountpoint {0} enabled successfully." -f $ActualId) -ForegroundColor Green
  } else {
    $ed = $respEnable.plugindata.data
    Write-Host ("WARN: enable may have failed: code={0} reason={1}" -f $ed.error_code, $ed.error) -ForegroundColor Yellow
  }

  Write-Host ("Open: http://localhost:4444/janode/?stream={0}" -f $ActualId) -ForegroundColor Green
}
catch {
  Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
  exit 1
}
