<#  OneFS_W.HealthCheck
    Entry Script: Run-OneFSWeeklyCheck.ps1
    Purpose: Load config → connect to clusters → run modular checks → build data model → render outputs
#>

[CmdletBinding()]
param(
    [ValidateSet('dev','prod')]
    [string]$Env = 'dev',

    [string]$ConfigPath,

    [switch]$WhatIf
)

# --- Runtime Safety -----------------------------------------------------------
$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers -----------------------------------------------------------------
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level][$Step] $Message"
    if ($Level -eq 'ERROR') { Write-Error $line } elseif ($Level -eq 'WARN') { Write-Warning $line } else { Write-Host $line }
}

function Resolve-PathSafe {
    param([Parameter(Mandatory)][string]$Path)
    try { return (Resolve-Path -LiteralPath $Path).Path } catch { return $Path }
}

function Load-JsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Config file not found: $Path"
    }
    $raw = Get-Content -LiteralPath $Path -Raw
    try { return $raw | ConvertFrom-Json -Depth 10 } catch {
        throw "Invalid JSON in $Path: $($_.Exception.Message)"
    }
}

function Read-Version {
    $vf = Join-Path $PSScriptRoot 'VERSION'
    if (Test-Path $vf) { (Get-Content $vf -Raw).Trim() } else { '0.0.0' }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

# --- Locate Config ------------------------------------------------------------
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $PSScriptRoot ("configs\{0}.json" -f $Env)
}
$ConfigPath = Resolve-PathSafe $ConfigPath

Write-Log -Step 'CFG01' -Message "Env=$Env ConfigPath=$ConfigPath"

# --- Load Config --------------------------------------------------------------
try {
    $config = Load-JsonFile -Path $ConfigPath
    Write-Log -Step 'CFG02' -Message "Config loaded."
} catch {
    Write-Log -Step 'CFG02' -Level ERROR -Message $_.Exception.Message
    exit 2
}

# --- Validate Config (light schema) ------------------------------------------
try {
    if (-not $config.clusters -or $config.clusters.Count -eq 0) { throw "Config 'clusters' is empty." }
    if (-not $config.output) { throw "Config 'output' section missing." }
    if (-not $config.output.path) { $config.output.path = ".\reports" }
    if (-not $config.output.formats) { $config.output.formats = @('markdown','csv') }
    Write-Log -Step 'CFG03' -Message "Config validated. Formats: $(($config.output.formats -join ', '))"
} catch {
    Write-Log -Step 'CFG03' -Level ERROR -Message $_.Exception.Message
    exit 2
}

# --- Prepare Run Context ------------------------------------------------------
$runDate = Get-Date -Format 'yyyy-MM-dd'
$reportRoot = if ([IO.Path]::IsPathRooted($config.output.path)) { $config.output.path } else { Join-Path $PSScriptRoot $config.output.path }
$runDir = Join-Path $reportRoot $runDate
Ensure-Directory -Path $runDir
Write-Log -Step 'OUT50' -Message "Report directory: $runDir"

$scriptVersion = Read-Version
Write-Log -Step 'VER10' -Message "Version: $scriptVersion"

# --- Import Modules -----------------------------------------------------------
# Report model module
$reportModule = Join-Path $PSScriptRoot 'modules\OneFS.Report.psm1'
Import-Module $reportModule -Force
Write-Log -Step 'MOD10' -Message "Imported report module."

# Check modules (load *.psm1 and *.ps1 under modules)
$moduleDir = Join-Path $PSScriptRoot 'modules'
$checkFiles = @()
$checkFiles += Get-ChildItem -LiteralPath $moduleDir -Filter '*.psm1' -File -Recurse -ErrorAction SilentlyContinue
$checkFiles += Get-ChildItem -LiteralPath $moduleDir -Filter '*.ps1'  -File -Recurse -ErrorAction SilentlyContinue

foreach ($f in $checkFiles) {
    # Skip the renderers and report module (imported separately)
    if ($f.FullName -match '\\modules\\renderers\\') { continue }
    if ($f.Name -ieq 'OneFS.Report.psm1') { continue }
    try {
        if ($f.Extension -ieq '.psm1') { Import-Module $f.FullName -Force }
        else { . $f.FullName }  # dot-source .ps1
    } catch {
        Write-Log -Step 'MOD20' -Level WARN -Message "Failed to load $($f.Name): $($_.Exception.Message)"
    }
}
Write-Log -Step 'MOD21' -Message "Modules loaded."

# --- Session Builder (stub to be replaced with your real auth/session) -------
function New-OneFSSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Cluster,  # object with name/host/etc.
        $Auth                          # config.auth
    )
    # TODO: Implement your real API token/basic/SSH session logic here
    # Return a PSCustomObject with at least .Connected = $true/$false and .Reason on failure
    try {
        # Simulate success; replace with your logic
        [pscustomobject]@{ Connected = $true; Cluster = $Cluster; Handle = $null }
    } catch {
        [pscustomobject]@{ Connected = $false; Cluster = $Cluster; Reason = $_.Exception.Message }
    }
}

# --- Discover Check Functions -------------------------------------------------
$checkFunctions = Get-Command -CommandType Function | Where-Object { $_.Name -like 'Invoke-Check-*' } | Sort-Object Name
if (-not $checkFunctions) {
    Write-Log -Step 'CHK00' -Level WARN -Message "No Invoke-Check-* functions found. Did you load your check modules?"
}

# --- Execute Checks per Cluster ----------------------------------------------
$results = New-Object System.Collections.Generic.List[object]
$clusters = @()

foreach ($cl in $config.clusters) {
    $clusterName = $cl.name ?? $cl.Name ?? $cl
    $clusters += $clusterName

    Write-Log -Step 'AUTH10' -Message "Connecting to cluster '$clusterName'..."
    $session = New-OneFSSession -Cluster $cl -Auth $config.auth
    if (-not $session.Connected) {
        Write-Log -Step 'AUTH19' -Level ERROR -Message "Auth failed for '$clusterName': $($session.Reason)"
        $results.Add([pscustomobject]@{
            Cluster = $clusterName; Check='Auth'; Status='Critical'; Detail="Failed to connect: $($session.Reason)"; Data=@{}
        })
        continue
    }

    # Run each check, catching errors but continuing
    foreach ($chk in $checkFunctions) {
        $checkName = $chk.Name
        try {
            Write-Log -Step 'CHK30' -Message "Running $checkName on $clusterName"
            $out = & $checkName -Cluster $cl -Session $session
            if ($null -ne $out) {
                if ($out -is [System.Collections.IEnumerable] -and -not ($out -is [string])) {
                    foreach ($row in $out) { $results.Add($row) }
                } else {
                    $results.Add($out)
                }
            } else {
                $results.Add([pscustomobject]@{
                    Cluster=$clusterName; Check=$checkName.Replace('Invoke-Check-',''); Status='Unknown'; Detail='No output'; Data=@{}
                })
            }
        } catch {
            $msg = $_.Exception.Message
            Write-Log -Step 'CHK39' -Level WARN -Message "$checkName on $clusterName errored: $msg"
            $results.Add([pscustomobject]@{
                Cluster=$clusterName; Check=$checkName.Replace('Invoke-Check-',''); Status='Unknown'; Detail=$msg; Data=@{}
            })
        }
    }
}

# --- Build Data Model ---------------------------------------------------------
try {
    $model = Get-OneFSReportData -Clusters $clusters -ChecksResults $results
    Write-Log -Step 'MDL10' -Message "Model built. Items: $($model.Items.Count)"
} catch {
    Write-Log -Step 'MDL10' -Level ERROR -Message "Failed to build model: $($_.Exception.Message)"
    exit 2
}

# Always save raw model for re-rendering later
$model | ConvertTo-Json -Depth 8 | Out-File (Join-Path $runDir 'model.json')

# --- Renderers ----------------------------------------------------------------
# Import renderer modules (only those requested in config.output.formats)
$formats = @($config.output.formats | ForEach-Object { $_.ToLowerInvariant() })
$renderers = @()

if ('html' -in $formats)     { $renderers += 'Html' }
if ('markdown' -in $formats) { $renderers += 'Markdown' }
if ('csv' -in $formats)      { $renderers += 'Csv' }

foreach ($r in $renderers) {
    $modPath = Join-Path $PSScriptRoot ("modules\renderers\OneFS.Render.{0}.psm1" -f $r)
    try {
        Import-Module $modPath -Force
        Write-Log -Step 'REN10' -Message "Renderer loaded: $r"
    } catch {
        Write-Log -Step 'REN11' -Level WARN -Message "Failed to load $r renderer: $($_.Exception.Message)"
    }
}

# Call renderers (individually guarded)
if ('html' -in $formats) {
    try { Export-OneFSReportHtml     -Model $model -OutFile (Join-Path $runDir 'report.html')
          Write-Log -Step 'OUT60' -Message "HTML written." }
    catch { Write-Log -Step 'OUT60' -Level WARN -Message "HTML render failed: $($_.Exception.Message)" }
}

if ('markdown' -in $formats) {
    try { Export-OneFSReportMarkdown -Model $model -OutFile (Join-Path $runDir 'report.md')
          Write-Log -Step 'OUT61' -Message "Markdown written." }
    catch { Write-Log -Step 'OUT61' -Level WARN -Message "Markdown render failed: $($_.Exception.Message)" }
}

if ('csv' -in $formats) {
    try { Export-OneFSReportCsv      -Model $model -OutFile (Join-Path $runDir 'tables.csv')
          Write-Log -Step 'OUT62' -Message "CSV written." }
    catch { Write-Log -Step 'OUT62' -Level WARN -Message "CSV render failed: $($_.Exception.Message)" }
}

# --- Notifications (optional) -------------------------------------------------
# If you later add config.email { enabled, smtp_server, from, to, ... }, do it here.
# Wrap in try/catch and never fail the run on notify errors.

# --- Exit Code Summary --------------------------------------------------------
$crit  = ($results | Where-Object { $_.Status -match '^(Critical|Error)$' }).Count
$warn  = ($results | Where-Object { $_.Status -match '^Warning$' }).Count
$ok    = ($results | Where-Object { $_.Status -match '^OK$' }).Count

Write-Log -Step 'END70' -Message "OK=$ok Warning=$warn Critical=$crit"

if ($crit -gt 0 -or $warn -gt 0) {
    exit 1   # partial failures / attention needed
} else {
    exit 0
}
