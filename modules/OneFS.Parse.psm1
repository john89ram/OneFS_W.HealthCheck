# OneFS.Parse.psm1 — PS 5.1 friendly, ASCII-only
# Hardened readers + resilient Parse-OneFSData with section classifiers

# -----------------------------
# Safe readers
# -----------------------------
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

# -----------------------------
# Tiny helpers for classification
# -----------------------------
function New-ParseResult {
  param([string]$Status, [string]$Notes = "")
  return @{ Status = $Status; Notes = $Notes }
}

function Test-Regex {
  param(
    [string]$Text,
    [string]$Pattern,
    [System.Text.RegularExpressions.RegexOptions]$Options = [System.Text.RegularExpressions.RegexOptions]::Multiline
  )
  if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
  return [regex]::IsMatch($Text, $Pattern, $Options)
}

function Safe-Get {
  param($Obj, [string]$Path)
  try {
    $cur = $Obj
    foreach ($part in $Path -split '\.') {
      if ($null -eq $cur) { return $null }
      if ($part -match '^\[(\d+)\]$') {
        $idx = [int]$Matches[1]
        if ($cur -is [System.Collections.IList] -and $idx -lt $cur.Count) { $cur = $cur[$idx] } else { return $null }
      } else {
        if ($cur.PSObject.Properties.Match($part).Count -gt 0) { $cur = $cur.$part } else { return $null }
      }
    }
    return $cur
  } catch { return $null }
}

# -----------------------------
# Section classifiers
# -----------------------------
function Classify-ClusterNodeStatus {
  param(
    [string]$RawClusterTxt
  )
  if ([string]::IsNullOrWhiteSpace($RawClusterTxt)) { return New-ParseResult "Unknown" "No data" }

  # Node health column not OK
  $nodeBad = Test-Regex $RawClusterTxt '^\s*\d+\|[0-9\.]+\s+\|\s*(?!OK)\S'

  # External network not connected (C/N column != C)
  $extNotConnected = Test-Regex $RawClusterTxt '^\s*\d+\|[0-9\.]+.*\|\s*[^C]\s*\|'

  # Critical Events block has rows
  $hasCriticalEventsBlock = Test-Regex $RawClusterTxt '^\s*Critical Events:\s*\r?\n[ -]+\r?\n\s*\S'

  if ($nodeBad -or $extNotConnected -or $hasCriticalEventsBlock) {
    return New-ParseResult "Critical" "Node or external link unhealthy, or critical events present."
  }

  # If cluster health not explicitly [OK], degrade to Warning
  $clusterHealthOk = Test-Regex $RawClusterTxt '^\s*Cluster Health:\s*\[\s*OK\s*\]'
  if (-not $clusterHealthOk) {
    return New-ParseResult "Warning" "Cluster health not reported OK."
  }

  return New-ParseResult "Pass"
}

function Classify-StoragePools {
  param(
    $StoragePoolJson,
    $DrivesJson
  )

  if ($null -eq $StoragePoolJson -and $null -eq $DrivesJson) { return New-ParseResult "Unknown" "No data" }

  $poolOverall = Safe-Get $StoragePoolJson 'summary.overall_health'
  $poolMsg     = Safe-Get $StoragePoolJson 'summary.message'
  $poolsHealthy =
      ($poolOverall -match '^(?i:healthy|ok|good)$') -or
      ($poolMsg -match '(?i)all pools are healthy')

  if (-not $poolsHealthy -and $StoragePoolJson) {
    $anyPoolBad = @($StoragePoolJson.pools | Where-Object {
      ($_.health -match '(?i:critical|degraded|failed)') -or
      ($_.status -match '(?i:critical|degraded|failed)')
    }).Count -gt 0
    if ($anyPoolBad) { return New-ParseResult "Warning" "Pool health not fully healthy." }
  }

  # Devices: explicit device failure is critical; ignore L3 by design
  if ($DrivesJson) {
    $failed = @($DrivesJson | Where-Object {
      ($_.health -match '(?i:smart\s*fail|smartfailed|failed|unreadable)') -or
      ($_.state  -match '(?i:failed|smartfailed)') -or
      ($_.status -match '(?i:failed)')
    }).Count
    if ($failed -gt 0) { return New-ParseResult "Critical" "Drive failure detected." }
  }

  if ($poolsHealthy) { return New-ParseResult "Pass" }
  return New-ParseResult "Warning" "Pool health not explicitly healthy."
}

function Classify-CapacityPerformance {
  param(
    $PerfJson
  )
  if ($null -eq $PerfJson) { return New-ParseResult "Unknown" "No data" }
  # Simple pass for now; add numeric thresholds if desired
  return New-ParseResult "Pass"
}

function Classify-DataProtectionReplication {
  param(
    $SyncReportsJson
  )
  if ($null -eq $SyncReportsJson) { return New-ParseResult "Unknown" "No data" }

  $failed = @($SyncReportsJson | Where-Object {
    ($_.result -match '(?i:fail|failed|error)') -or
    ($_.state  -match '(?i:fail|failed|error)')
  }).Count
  if ($failed -gt 0) { return New-ParseResult "Warning" "Failed SyncIQ reports present." }

  $disabledHints = @($SyncReportsJson | Where-Object { $_.message -match '(?i:disabled)' }).Count
  if ($disabledHints -gt 0) { return New-ParseResult "Warning" "One or more policies disabled." }

  return New-ParseResult "Pass"
}

function Classify-SnapshotsBackup {
  param(
    $SnapshotsJson,
    $SchedulesJson,
    [string]$RawClusterTxtForEvents
  )

  if ($null -eq $SnapshotsJson -and $null -eq $SchedulesJson -and [string]::IsNullOrWhiteSpace($RawClusterTxtForEvents)) {
    return New-ParseResult "Unknown" "No data"
  }

  # Look for snapshot creation failures (commonly in events text)
  $snapCreateFail = Test-Regex $RawClusterTxtForEvents '(?mi)snapshot daemon failed to create snapshot'
  if (-not $snapCreateFail -and $SnapshotsJson) {
    $snapCreateFail = @($SnapshotsJson | Where-Object {
      ($_.message -match '(?i:failed|error)') -or ($_.error -ne $null)
    }).Count -gt 0
  }

  if ($snapCreateFail) { return New-ParseResult "Warning" "Snapshot creation failures detected. Check schedules and paths." }

  return New-ParseResult "Pass"
}

function Classify-Dedupe {
  param(
    $DedupeJson
  )
  if ($null -eq $DedupeJson) { return New-ParseResult "Unknown" "No data" }

  $hasErrors = $false
  if ($DedupeJson -is [System.Collections.IEnumerable]) {
    $hasErrors = @($DedupeJson | Where-Object { $_.status -match '(?i:error|fail)' }).Count -gt 0
  } elseif ($DedupeJson.PSObject.Properties.Name -contains 'status') {
    $hasErrors = ($DedupeJson.status -match '(?i:error|fail)')
  }
  if ($hasErrors) { return New-ParseResult "Warning" "Dedupe errors detected." }

  return New-ParseResult "Pass"
}

function Classify-Quotas {
  param(
    $QuotaReportsJson
  )
  if ($null -eq $QuotaReportsJson) { return New-ParseResult "Unknown" "No data" }

  # If the payload obviously says "no exceedances", pass
  if ($QuotaReportsJson -isnot [System.Collections.IEnumerable]) {
    $flat = ($QuotaReportsJson | ConvertTo-Json -Depth 5)
    if ($flat -match '(?i)no quota threshold exceedances found') { return New-ParseResult "Pass" }
  }

  $critical = $false; $warn = $false
  foreach ($q in ($QuotaReportsJson | ForEach-Object { $_ })) {
    $pct = $null
    foreach ($field in 'usage.pct_of_hard','usage.pct','pct','applied_usage.pct') {
      $v = Safe-Get $q $field
      if ($null -ne $v) {
        $d = $null
        if ([double]::TryParse("$v", [ref]$d)) { $pct = $d; break }
      }
    }
    if ($null -ne $pct) {
      if ($pct -ge 95) { $critical = $true; break }
      if ($pct -ge 90) { $warn = $true }
    }
  }

  if ($critical) { return New-ParseResult "Critical" "Quota usage at or over hard threshold (>=95%)." }
  if ($warn)     { return New-ParseResult "Warning"  "Quota nearing threshold (>=90%)." }
  return New-ParseResult "Pass"
}

function Classify-SharesProtocols {
  param(
    [string]$ServicesTxt
  )
  if ([string]::IsNullOrWhiteSpace($ServicesTxt)) { return New-ParseResult "Unknown" "No data" }

  # Essential services that must be up; non-essential disabled is OK
  $essential = @('lsass','lwio','lwreg','lwsm','isi_smb','isi_nfs','isi_webui','isi_snapsched','isi_quota')
  $pattern = '^(?:' + ($essential -join '|') + ')\s+.*\b(Stopped|Disabled|Failed)\b'

  if (Test-Regex $ServicesTxt $pattern) {
    return New-ParseResult "Critical" "Essential protocol or service stopped or failed."
  }

  return New-ParseResult "Pass"
}

# -----------------------------
# Main entry: Parse-OneFSData
# -----------------------------
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
    services    = Join-Path $OutFolder 'json_services.txt'   # plain text, not JSON
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

  # Services output is text; ensure file exists
  if (-not (Test-Path -LiteralPath $json.services)) {
    "" | Out-File -FilePath $json.services -Encoding UTF8
  }

  # Read JSON/text artifacts
  $StoragePool = Read-Json $json.storagepool
  $Drives      = Read-Json $json.drives
  $Perf        = Read-Json $json.perf
  $SyncReports = Read-Json $json.syncreports
  $Snapshots   = Read-Json $json.snaps
  $Schedules   = Read-Json $json.snapsched
  $Dedupe      = Read-Json $json.dedupe
  $QuotaReports= Read-Json $json.quotasrep
  $Shares      = Read-Json $json.smbshares
  $ServicesTxt = Read-Text $json.services

  # Human-readable cluster status text (for event-derived checks)
  $clusterTxtPath = Join-Path $OutFolder '01_Cluster_Node_Status.txt'
  $ClusterTxt     = Read-Text $clusterTxtPath

  # Compute section statuses
  $sec01 = Classify-ClusterNodeStatus       -RawClusterTxt $ClusterTxt
  $sec02 = Classify-StoragePools            -StoragePoolJson $StoragePool -DrivesJson $Drives
  $sec03 = Classify-CapacityPerformance     -PerfJson $Perf
  $sec04 = Classify-DataProtectionReplication -SyncReportsJson $SyncReports
  $sec05 = Classify-SnapshotsBackup         -SnapshotsJson $Snapshots -SchedulesJson $Schedules -RawClusterTxtForEvents $ClusterTxt
  $sec06 = Classify-Dedupe                  -DedupeJson $Dedupe
  $sec07 = Classify-Quotas                  -QuotaReportsJson $QuotaReports
  $sec08 = Classify-SharesProtocols         -ServicesTxt $ServicesTxt

  $sectionStatus = [pscustomobject]@{
    ClusterAndNodeStatus         = $sec01
    StoragePoolsAndDriveHealth   = $sec02
    CapacityAndPerformance       = $sec03
    DataProtectionAndReplication = $sec04
    SnapshotsAndBackupCoverage   = $sec05
    DeduplicationSmartDedupe     = $sec06
    QuotasAndProfileCapacity     = $sec07
    SharesAndProtocolServices    = $sec08
  }

  # Preserve original shape; append SectionStatus for the renderer
  [pscustomobject]@{
    StoragePool   = $StoragePool
    Drives        = $Drives
    Perf          = $Perf
    SyncReports   = $SyncReports
    Snapshots     = $Snapshots
    Schedules     = $Schedules
    Dedupe        = $Dedupe
    QuotaReports  = $QuotaReports
    Shares        = $Shares
    ServicesTxt   = $ServicesTxt
    Files         = $Files
    ZoneName      = $ZoneName
    SectionStatus = $sectionStatus
  }
}

Export-ModuleMember -Function Read-Json, Read-Text, Get-RemoteJson, Parse-OneFSData
