# OneFS.Report.psm1 — rich HTML report with embedded raw outputs

function ConvertTo-HtmlSafeText {
  [CmdletBinding()]
  param([AllowNull()][AllowEmptyString()][string]$Text)
  if ($null -eq $Text) { return "" }
  try { return [System.Web.HttpUtility]::HtmlEncode([string]$Text) } catch { return [string]$Text }
}

function Get-FirstProp {
  param(
    [Parameter(Mandatory)]$Object,
    [Parameter(Mandatory)][string[]]$Names,
    $Default = $null
  )
  if ($null -eq $Object) { return $Default }
  foreach ($n in $Names) {
    $p = $Object.PSObject.Properties |
      Where-Object { $_.Name -ieq $n -and $null -ne $_.Value } |
      Select-Object -First 1
    if ($p) { return $p.Value }
  }
  return $Default
}

function Normalize-Section {
  param([Parameter(Mandatory)]$Section)
  $name   = Get-FirstProp $Section @('Name','Title','Section','Id') '<unnamed>'
  $status = Get-FirstProp $Section @('Status','Level','State','Health') 'Unknown'
  $notes  = Get-FirstProp $Section @('Notes','Message','Summary','Detail','Details') $null

  # Build compact summary if common counters exist
  $counters = @()
  foreach ($k in 'Critical','Error','Warn','Warning','Info','OK','Ok','Pass','Fail','Total') {
    $v = Get-FirstProp $Section @($k) $null
    if ($null -ne $v -and $v -ne '') { $counters += ('{0}:{1}' -f $k, $v) }
  }
  if (-not $notes -and $counters.Count -gt 0) { $notes = ($counters -join ', ') }

  [pscustomobject]@{
    Name   = [string]$name
    Status = [string]$status
    Notes  = if ($notes) { [string]$notes } else { '' }
  }
}

function Add-SectionSummary {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SummaryPath,
    [Parameter(Mandatory)]$Classification
  )

  $sections = @()
  if ($Classification -and $Classification.Sections) {
    foreach ($s in @($Classification.Sections)) {
      $sections += (Normalize-Section -Section $s)
    }
  }

  $grouped = $sections | Group-Object -Property Status | Sort-Object -Property Name
  "Section Status Totals:" | Out-File $SummaryPath -Append -Encoding UTF8
  foreach ($g in $grouped) {
    ("  {0}: {1}" -f $g.Name, $g.Count) | Out-File $SummaryPath -Append -Encoding UTF8
  }

  "" | Out-File $SummaryPath -Append -Encoding UTF8
  "Sections:" | Out-File $SummaryPath -Append -Encoding UTF8
  foreach ($row in $sections) {
    ("  - {0} => {1}{2}" -f $row.Name, $row.Status, ($(if ($row.Notes) { " ($($row.Notes))" } else { "" }))) |
      Out-File $SummaryPath -Append -Encoding UTF8
  }
}

function New-OneFSHtmlReport {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$OutFolder,
    [Parameter(Mandatory)][string]$ClusterName,
    [Parameter(Mandatory)]$Classification,
    [Parameter(Mandatory)]$Parsed,
    $Files
  )

  if (-not (Test-Path -LiteralPath $OutFolder)) {
    New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
  }

  # Map report section -> expected file name (produced by Invoke-OneFSWeeklyBlocks)
  $fileMap = @{
    'Cluster & Node Status'         = '01_Cluster_Node_Status.txt'
    'Storage Pools & Drive Health'  = '02_StoragePools_DriveHealth.txt'
    'Capacity & Performance'        = '03_Capacity_Performance.txt'
    'Data Protection & Replication' = '04_DataProtection_Replication.txt'
    'Snapshots & Backup Coverage'   = '05_Snapshots_BackupCoverage.txt'
    'Deduplication / SmartDedupe'   = '06_Dedupe_SmartDedupe.txt'
    'Quotas & Profile Capacity'     = '07_Quotas_Capacity.txt'
    'Shares & Protocol Services'    = '08_Shares_Protocols.txt'
  }

  function Read-TextSafe([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return "" }
    if (-not (Test-Path -LiteralPath $path)) { return "" }
    try { return Get-Content -LiteralPath $path -Raw -ErrorAction Stop } catch { return "" }
  }

  function Get-StatusClass([string]$status) {
    if (-not $status) { return 'unknown' }
    switch -Regex ($status) {
      'crit|fail|bad|down' { 'crit' ; break }
      'warn|degrad'        { 'warn' ; break }
      'ok|good|pass|up'    { 'ok'   ; break }
      default              { 'unknown' }
    }
  }

  # Normalize sections for top summary + body
  $sections = @()
  if ($Classification -and $Classification.Sections) {
    foreach ($s in @($Classification.Sections)) {
      $sections += (Normalize-Section -Section $s)
    }
  }

  # Build rows for the summary table
  $rowsHtml = foreach ($r in $sections) {
    '<tr><td>{0}</td><td class="{1}">{2}</td><td>{3}</td></tr>' -f
      (ConvertTo-HtmlSafeText $r.Name),
      (Get-StatusClass $r.Status),
      (ConvertTo-HtmlSafeText $r.Status),
      (ConvertTo-HtmlSafeText $r.Notes)
  }

  # Build collapsible cards per section, embedding raw text when available
  $cardsHtml = foreach ($r in $sections) {
    $fname = $fileMap[$r.Name]
    $fpath = if ($fname) { Join-Path $OutFolder $fname } else { $null }
    $raw   = Read-TextSafe $fpath

    $summaryBar = '<div class="pill {0}">{1}</div> <span class="secname">{2}</span>' -f (Get-StatusClass $r.Status), (ConvertTo-HtmlSafeText $r.Status), (ConvertTo-HtmlSafeText $r.Name)
    $noteLine   = if ($r.Notes) { '<div class="notes">{0}</div>' -f (ConvertTo-HtmlSafeText $r.Notes) } else { '' }
    $rawBlock   = if ($raw) { '<pre class="raw">{0}</pre>' -f (ConvertTo-HtmlSafeText $raw) } else { '<div class="muted">No raw output available.</div>' }

    @"
<section class="card">
  <details open>
    <summary>$summaryBar</summary>
    $noteLine
    $rawBlock
    $(if($fpath){ '<div class="muted path">Raw file: ' + (ConvertTo-HtmlSafeText $fpath) + '</div>' })
  </details>
</section>
"@
  }

  # Try to display OneFS version line from the Cluster & Node Status raw file
  $cnRaw = Read-TextSafe (Join-Path $OutFolder $fileMap['Cluster & Node Status'])
  $version = ''
  if ($cnRaw) {
    $m = [regex]::Match($cnRaw, 'Isilon OneFS\s+[^\r\n]+')
    if ($m.Success) { $version = $m.Value }
  }

  $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $fileName = Join-Path $OutFolder 'OneFS_Weekly_Health.html'

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>OneFS Weekly Health — $(ConvertTo-HtmlSafeText $ClusterName)</title>
<style>
  :root { --bg:#0b132b; --card:#1c2541; --line:#3a506b; --ok:#13a10e; --warn:#c19a00; --crit:#d13438; --unk:#838383; --text:#e6e6e6; --muted:#a7a7a7; --code:#0f1a33; }
  html,body { background: var(--bg); color: var(--text); font-family: system-ui, Segoe UI, Arial, sans-serif; }
  body { margin: 24px; }
  h1 { margin: 0 0 4px 0; font-size: 24px; }
  .sub { color: var(--muted); margin-bottom: 16px; }
  .grid { display: grid; gap: 12px; grid-template-columns: 1fr; }
  .tablewrap { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 10px 12px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { border-bottom: 1px solid var(--line); padding: 10px 8px; }
  th { text-align: left; color: var(--muted); font-weight: 600; font-size: 12px; letter-spacing: .04em; text-transform: uppercase; }
  tr:last-child td { border-bottom: none; }
  .pill { display:inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; font-weight: 700; }
  .ok   { background:#12391b; color:#6ee786; border:1px solid #1f7a2e; }
  .warn { background:#3b2a05; color:#ffd46d; border:1px solid #9a6b00; }
  .crit { background:#3a0f14; color:#ff8a8a; border:1px solid #a11b26; }
  .unknown { background:#2b2b2b; color:#cfcfcf; border:1px solid #5a5a5a; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 0; }
  details { padding: 12px 14px; }
  summary { cursor: pointer; list-style: none; padding: 6px 0 10px 0; }
  summary::-webkit-details-marker { display: none; }
  summary .secname { font-size: 16px; font-weight: 600; margin-left: 8px; }
  .notes { color: var(--muted); margin: 6px 0 10px 0; }
  .raw { background: var(--code); border:1px solid var(--line); border-radius: 10px; padding: 12px; overflow: auto; white-space: pre; max-height: 520px; }
  .muted { color: var(--muted); }
  .path { margin-top: 8px; font-size: 12px; }
  .meta { color: var(--muted); margin-top: 14px; font-size: 12px; }
</style>
</head>
<body>
  <h1>OneFS Weekly Health — $(ConvertTo-HtmlSafeText $ClusterName)</h1>
  <div class="sub">
    Generated: $(ConvertTo-HtmlSafeText $ts)
    $(if($version){ ' • ' + (ConvertTo-HtmlSafeText $version) })
  </div>

  <div class="tablewrap">
    <table>
      <thead><tr><th style="width:40%">Section</th><th style="width:12%">Status</th><th>Notes</th></tr></thead>
      <tbody>
        $($rowsHtml -join "`n        ")
      </tbody>
    </table>
  </div>

  <div class="grid" style="margin-top:14px;">
    $($cardsHtml -join "`n")
  </div>

  <div class="meta">Report folder: $(ConvertTo-HtmlSafeText $OutFolder)</div>
</body>
</html>
"@

  $html | Out-File -FilePath $fileName -Encoding UTF8
  return $fileName
}

Export-ModuleMember -Function Add-SectionSummary, New-OneFSHtmlReport
