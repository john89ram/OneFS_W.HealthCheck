# OneFS.Parse.psm1 — hardened readers + resilient Parse-OneFSData

function Read-Json {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try {
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    return $null
  }
}

function Read-Text {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory=$true)][string]$Path
  )
  if (-not (Test-Path -LiteralPath $Path)) { return "" }
  try {
    return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
  } catch {
    return ""
  }
}

function Get-RemoteJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][Renci.SshNet.SshClient]$Client,
    [Parameter(Mandatory)][string]$Cmd,
    [Parameter(Mandatory)][string]$LocalPath,
    [int]$TimeoutSec = 180
  )
  try {
    # Caller appends '2>&1' so we capture anything that hits stderr on the node.
    $res = Invoke-SSHCommand -SessionId $Client.SessionId -Command $Cmd -TimeOut $TimeoutSec -ErrorAction Stop
    # Posh-SSH returns an object; Output is an array of lines
    $out = ($res | Select-Object -ExpandProperty Output) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($out)) {
      $out | Out-File -FilePath $LocalPath -Encoding UTF8
      return $true
    }
  } catch {
    # swallow; caller treats false as "no file produced"
  }
  return $false
}

function Parse-OneFSData {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][Renci.SshNet.SshClient]$Client,
    [Parameter(Mandatory)][string]$OutFolder,
    [Parameter(Mandatory)][string]$ZoneName,
    [int]$TimeoutSec = 180,
    $Files
  )

  $json = @{
    storagepool = Join-Path $OutFolder 'json_storagepool_health.txt'
    drives      = Join-Path $OutFolder 'json_devices_drive_list.txt'
    perf        = Join-Path $OutFolder 'json_statistics_system_list.txt'
    syncreports = Join-Path $OutFolder 'json_sync_reports.txt'
    snaps       = Join-Path $OutFolder 'json_snapshot_list.txt'
    snapsched   = Join-Path $OutFolder 'json_snapshot_schedules.txt'
    dedupe      = Join-Path $OutFolder 'json_dedupe_stats.txt'
    quotasrep   = Join-Path $OutFolder 'json_quota_reports.txt'
    smbshares   = Join-Path $OutFolder ("json_smb_shares_{0}.txt" -f $ZoneName)
    services    = Join-Path $OutFolder 'json_services.txt'
  }

  # Collect (capture stderr too)
  $null = Get-RemoteJson -Client $Client -Cmd 'isi storagepool health --format=json 2>&1' -LocalPath $json.storagepool -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi devices drive list --format=json 2>&1' -LocalPath $json.drives -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi statistics system list --nodes all --format=json 2>&1' -LocalPath $json.perf -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi sync reports list --format=json 2>&1' -LocalPath $json.syncreports -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi snapshot snapshots list --format=json 2>&1' -LocalPath $json.snaps -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi snapshot schedules list --format=json 2>&1' -LocalPath $json.snapsched -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi dedupe stats --format=json 2>&1' -LocalPath $json.dedupe -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi quota reports list --format=json 2>&1' -LocalPath $json.quotasrep -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd ("isi smb shares list --zone {0} --format=json 2>&1" -f $ZoneName) -LocalPath $json.smbshares -TimeoutSec $TimeoutSec
  $null = Get-RemoteJson -Client $Client -Cmd 'isi services -a 2>&1' -LocalPath $json.services -TimeoutSec $TimeoutSec

  # Services output isn't JSON; ensure file always exists to avoid Get-Content crashes downstream
  if (-not (Test-Path -LiteralPath $json.services)) {
    "" | Out-File -FilePath $json.services -Encoding UTF8
  }

  [pscustomobject]@{
    StoragePool = Read-Json $json.storagepool
    Drives      = Read-Json $json.drives
    Perf        = Read-Json $json.perf
    SyncReports = Read-Json $json.syncreports
    Snapshots   = Read-Json $json.snaps
    Schedules   = Read-Json $json.snapsched
    Dedupe      = Read-Json $json.dedupe
    QuotaReports= Read-Json $json.quotasrep
    Shares      = Read-Json $json.smbshares
    ServicesTxt = Read-Text $json.services
    Files       = $Files
    ZoneName    = $ZoneName
  }
}

Export-ModuleMember -Function Read-Json, Read-Text, Get-RemoteJson, Parse-OneFSData
