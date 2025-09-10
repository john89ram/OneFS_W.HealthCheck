# OneFS.Commands.psm1
# Runs OneFS command blocks via Posh-SSH and classifies results.

# Ensure Posh-SSH (needed for Invoke-SSHCommand)
try {
  if (-not (Get-Command -Name Invoke-SSHCommand -ErrorAction SilentlyContinue)) {
    if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
      throw "Missing dependency 'Posh-SSH'. Install once: Install-Module Posh-SSH -Scope CurrentUser"
    }
    Import-Module Posh-SSH -ErrorAction Stop
  }
} catch {
  throw "Unable to load Posh-SSH: $($_.Exception.Message)"
}

function Resolve-OneFSSessionId {
  <#
    .SYNOPSIS
      Resolve a usable SessionId for Posh-SSH from various client inputs.
    .PARAMETER Client
      Can be:
        - an Int or String SessionId
        - a Posh-SSH session object (has .SessionId)
        - a Renci.SshNet.SshClient (will be mapped back to SessionId)
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Client)

  # If caller gave a SessionId directly
  if ($Client -is [int]) { return $Client }
  if ($Client -is [string] -and ($Client -as [int])) { return [int]$Client }

  # Posh-SSH session object (has SessionId)
  if ($Client.PSObject -and ($Client.PSObject.Properties.Name -contains 'SessionId')) {
    return [int]$Client.SessionId
  }

  # Inner Renci client -> map back to SessionId
  if ($Client -is [Renci.SshNet.SshClient]) {
    $match = Get-SSHSession | Where-Object { $_.Session -eq $Client } | Select-Object -First 1
    if ($match) { return [int]$match.SessionId }
  }

  throw "Unable to resolve SessionId from -Client (type: $($Client.GetType().FullName))."
}

function Invoke-SSHBlock {
  <#
    .SYNOPSIS
      Execute a batch of shell commands over SSH and save raw outputs.
    .PARAMETER Client
      Posh-SSH session object, Renci.SshNet.SshClient, or SessionId.
    .PARAMETER Title
      Logical block name (written to the file header).
    .PARAMETER Commands
      Array of shell commands to run on the OneFS side.
    .PARAMETER OutFile
      Destination text file for raw captures.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$Client,
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string[]]$Commands,
    [Parameter(Mandatory)][string]$OutFile,
    [int]$TimeoutSec = 180
  )

  $sessionId = Resolve-OneFSSessionId -Client $Client

  $sb = New-Object System.Text.StringBuilder
  $null = $sb.AppendLine("===== $Title =====")
  $null = $sb.AppendLine("Run at: $(Get-Date -Format o)")

  foreach ($cmd in $Commands) {
    $null = $sb.AppendLine("---- CMD: $cmd")
    try {
      $res = Invoke-SSHCommand -SessionId $sessionId -Command $cmd -TimeOut $TimeoutSec -ErrorAction Stop
      if ($res.Error)  { $null = $sb.AppendLine("[STDERR]"); $null = $sb.AppendLine(($res.Error  | Out-String).TrimEnd()) }
      if ($res.Output) { $null = $sb.AppendLine("[STDOUT]"); $null = $sb.AppendLine(($res.Output | Out-String).TrimEnd()) }
      if (-not $res.Output -and -not $res.Error) { $null = $sb.AppendLine("[STDOUT] <no output>") }
    } catch {
      $null = $sb.AppendLine("[EXCEPTION] $($_.Exception.Message)")
    }
    $null = $sb.AppendLine("")
  }

  # Ensure directory exists then write
  $dir = Split-Path -Parent $OutFile
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $sb.ToString() | Out-File -FilePath $OutFile -Encoding UTF8
}

function Invoke-OneFSWeeklyBlocks {
  <#
    .SYNOPSIS
      Runs the standard weekly health blocks and returns a hashtable of output files.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][object]$Client,
    [Parameter(Mandatory)][string]$OutFolder,
    [Parameter(Mandatory)][string]$ZoneName,
    [int]$TimeoutSec = 180
  )

  $files = @{
    Cluster = Join-Path $OutFolder "01_Cluster_Node_Status.txt"
    Pools   = Join-Path $OutFolder "02_StoragePools_DriveHealth.txt"
    Perf    = Join-Path $OutFolder "03_Capacity_Performance.txt"
    Sync    = Join-Path $OutFolder "04_DataProtection_Replication.txt"
    Snap    = Join-Path $OutFolder "05_Snapshots_BackupCoverage.txt"
    Dedupe  = Join-Path $OutFolder "06_Dedupe_SmartDedupe.txt"
    Quota   = Join-Path $OutFolder "07_Quotas_Capacity.txt"
    Shares  = Join-Path $OutFolder "08_Shares_Protocols.txt"
  }

  Invoke-SSHBlock -Client $Client -Title "Cluster and Node Status" -OutFile $files.Cluster -TimeoutSec $TimeoutSec -Commands @(
    'isi version',
    'isi status',
    "isi event events list --format=table | awk -v n=50 'NR==1{print;next} NR<=n+1'",
    'isi healthcheck checklists list --format=table',
    'isi healthcheck evaluations run basic',
    'isi healthcheck evaluations list'
  )

  Invoke-SSHBlock -Client $Client -Title "Storage Pools and Drive Health" -OutFile $files.Pools -TimeoutSec $TimeoutSec -Commands @(
    'isi storagepool health',
    'isi devices drive list'
  )

  Invoke-SSHBlock -Client $Client -Title "Capacity and Performance" -OutFile $files.Perf -TimeoutSec $TimeoutSec -Commands @(
    'isi statistics system list --nodes all'
  )

  Invoke-SSHBlock -Client $Client -Title "Data Protection and Replication (SyncIQ and Jobs)" -OutFile $files.Sync -TimeoutSec $TimeoutSec -Commands @(
    'isi sync policies list',
    'isi job jobs list',
    'isi job reports list',
    'isi sync reports list'
  )

  Invoke-SSHBlock -Client $Client -Title "Snapshots and Backup Coverage" -OutFile $files.Snap -TimeoutSec $TimeoutSec -Commands @(
    'isi snapshot snapshots list',
    'isi snapshot schedules list'
  )

  Invoke-SSHBlock -Client $Client -Title "Deduplication and SmartDedupe" -OutFile $files.Dedupe -TimeoutSec $TimeoutSec -Commands @(
    'isi dedupe stats',
    'isi dedupe reports list',
    'isi dedupe inline view 2>/dev/null || isi dedupe settings view'
  )

  Invoke-SSHBlock -Client $Client -Title "Quotas and Profile Folder Capacity" -OutFile $files.Quota -TimeoutSec $TimeoutSec -Commands @(
    'isi quota reports list',
    "isi quota reports list | egrep -i 'exceed|violation|threshold' || echo 'No quota threshold exceedances found'",
    'isi quota quotas list'
  )

  Invoke-SSHBlock -Client $Client -Title "Share Configuration and Protocols" -OutFile $files.Shares -TimeoutSec $TimeoutSec -Commands @(
    "isi smb shares list --zone $ZoneName",
    'isi services -a'
  )

  return $files
}

function Classify-Sections {
  <#
    .SYNOPSIS
      Naive health classification based on keyword scraping of raw outputs.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Files)

  $defs = @(
    @{ Name='Cluster & Node Status';            File=$Files.Cluster; Warn='Warn|warning|degraded|temp|threshold';  Crit='Critical|FAILED|Fail|Down|Error' },
    @{ Name='Storage Pools & Drive Health';     File=$Files.Pools;   Warn='realloc|predict|slow|hot';             Crit='failed|SMART.*fail|error|down' },
    @{ Name='Capacity & Performance';           File=$Files.Perf;    Warn='latency|queue|high';                   Crit='throttle|backpressure|unavailable' },
    @{ Name='Data Protection & Replication';    File=$Files.Sync;    Warn='retry|late|skipped';                   Crit='Failed|Error|Aborted' },
    @{ Name='Snapshots & Backup Coverage';      File=$Files.Snap;    Warn='skew|lag|overhead|miss';               Crit='error|failed|disabled' },
    @{ Name='Deduplication / SmartDedupe';      File=$Files.Dedupe;  Warn='backlog|queue|paused';                 Crit='error|failed|stopped' },
    @{ Name='Quotas & Profile Capacity';        File=$Files.Quota;   Warn='threshold|warn|hard';                  Crit='exceed|violation' },
    @{ Name='Shares & Protocol Services';       File=$Files.Shares;  Warn='degraded|restart';                     Crit='stopped|disabled|down|failed' }
  )

  $res = @()
  foreach ($d in $defs) {
    $status = 'Pass'
    if (Test-Path $d.File) {
      $crit = Select-String -Path $d.File -Pattern $d.Crit -ErrorAction SilentlyContinue
      if ($crit) {
        $status = 'Critical'
      } else {
        $warn = Select-String -Path $d.File -Pattern $d.Warn -ErrorAction SilentlyContinue
        if ($warn) { $status = 'Warning' }
      }
    } else { $status = 'Warning' }
    $res += [pscustomobject]@{ Name=$d.Name; File=(Split-Path $d.File -Leaf); Status=$status }
  }

  [pscustomobject]@{
    Sections = $res
    Total    = $res.Count
    Pass     = ($res | Where-Object { $_.Status -eq 'Pass'     }).Count
    Warn     = ($res | Where-Object { $_.Status -eq 'Warning'  }).Count
    Crit     = ($res | Where-Object { $_.Status -eq 'Critical' }).Count
  }
}

function Add-SectionSummary {
  <#
    .SYNOPSIS
      Append a one-liner summary of sections to a text file.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SummaryPath,
    [Parameter(Mandatory)]$Classification
  )

  " " | Out-File -FilePath $SummaryPath -Encoding UTF8 -Append
  "Sections and files:" | Out-File -FilePath $SummaryPath -Encoding UTF8 -Append
  foreach ($s in $Classification.Sections) {
    (" - {0} -> {1}" -f $s.Name, $s.File) | Out-File -FilePath $SummaryPath -Encoding UTF8 -Append
  }
  ("`nQuick counts: Pass={0} Warn={1} Critical={2}" -f $Classification.Pass, $Classification.Warn, $Classification.Crit) |
    Out-File -FilePath $SummaryPath -Encoding UTF8 -Append
}

Export-ModuleMember -Function Resolve-OneFSSessionId,Invoke-SSHBlock,Invoke-OneFSWeeklyBlocks,Classify-Sections,Add-SectionSummary
