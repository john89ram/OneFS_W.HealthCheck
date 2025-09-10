param(
  [string]$ConfigPath,
  [string]$TargetHost,       
  [string]$Username,
  [string]$ZoneName = "System",
  [int]$Port = 22,
  [string]$KeyPath,
  [string]$OutputRoot = "$PSScriptRoot\out",
  [int]$TimeoutSec = 180
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$modPath = Join-Path $here "modules"
$ErrorActionPreference = "Stop"

# Ensure modules folder exists
if (-not (Test-Path $modPath)) {
  throw "Modules folder not found at '$modPath'. Verify your script layout."
}

# Import OneFS helper modules
Import-Module (Join-Path $modPath "OneFS.Utils.psm1")       -Force
Import-Module (Join-Path $modPath "OneFS.UI.psm1")          -Force
Import-Module (Join-Path $modPath "OneFS.Connection.psm1")  -Force
Import-Module (Join-Path $modPath "OneFS.Commands.psm1")    -Force
Import-Module (Join-Path $modPath "OneFS.Parse.psm1")       -Force
Import-Module (Join-Path $modPath "OneFS.Report.psm1")      -Force

# Posh-SSH is required by the connection layer
Ensure-Module "Posh-SSH"

# Load config if present (we do not read any password from config or env)
$config = @{}
if ($ConfigPath -and (Test-Path $ConfigPath)) {
  try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
  } catch {
    throw "Failed to parse JSON config at '$ConfigPath': $($_.Exception.Message)"
  }
}

# Merge from config (use $TargetHost, not $Host)
if (-not $TargetHost -and $config.host)     { $TargetHost = [string]$config.host }
if (-not $Username   -and $config.username) { $Username   = [string]$config.username }
if (-not $ZoneName   -and $config.zone)     { $ZoneName   = [string]$config.zone } else { if (-not $ZoneName) { $ZoneName = "System" } }

if (-not $PSBoundParameters.ContainsKey('Port')) {
  if ($config.port) { $Port = [int]$config.port } else { if (-not $Port) { $Port = 22 } }
}

# Normalize blanks
if ([string]::IsNullOrWhiteSpace($KeyPath)) { $KeyPath = $null }

# Show GUI if any required field is missing (host/user when password auth, zone, or port)
$needDialog = (-not $TargetHost) -or (-not $ZoneName) -or (-not $Port) -or (-not $Username -and -not $KeyPath)
if ($needDialog) {
  $login = Show-SSHLoginDialog -DefaultHost $TargetHost -DefaultUser $Username -DefaultZone $ZoneName -DefaultPort $Port
  if (-not $login) { throw "Login canceled." }
  $TargetHost = $login.Host
  $Port       = $login.Port
  $ZoneName   = $login.Zone
  $Credential = $login.Credential
  # IMPORTANT: dialog returns Credential (with username), not a separate Username field
  if (-not $Username -and $Credential) { $Username = $Credential.UserName }
} else {
  # Non-dialog path: if no key, ensure Username exists, then prompt for password
  if (-not $KeyPath) {
    if ([string]::IsNullOrWhiteSpace($Username)) {
      $Username = Read-Host "Enter SSH username for $TargetHost"
    }
    $sec = Read-Host "Enter SSH password for $Username@$TargetHost" -AsSecureString
    $Credential = New-Object System.Management.Automation.PSCredential($Username, $sec)
  } else {
    $Credential = $null  # key-based auth path
  }
}

# Final validation AFTER dialog/prompt
if (-not $TargetHost) { throw "TargetHost is required." }
if (-not $ZoneName)   { throw "ZoneName is required." }
if (-not $Port)       { throw "Port is required." }
if ($KeyPath -and -not $Username) { throw "Username is required when using key-based auth." }
if (-not $KeyPath -and -not $Username) { throw "Username is required for password-based auth." }

# (Optional) quick auth-mode debug line
Write-Host ("Auth mode: {0} | Username: {1} | Credential set: {2} | KeyPath: {3}" -f
  ($(if($KeyPath){"key"}else{"password"})), $Username, [bool]$Credential, $(if($KeyPath){$KeyPath}else{"<none>"}))

# Prepare output root
try {
  if (-not (Test-Path $OutputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
  }
} catch {
  throw "Unable to ensure output root at '$OutputRoot': $($_.Exception.Message)"
}

# Prepare report folder and summary
$OutFolder = New-ReportFolder -Root $OutputRoot
$summary   = Join-Path $OutFolder "SUMMARY.txt"
"OneFS Weekly Environmental Check Summary" | Out-File $summary -Encoding UTF8
"Generated: $(Get-Date -Format o)"         | Out-File $summary -Encoding UTF8 -Append
"Host: $TargetHost"                        | Out-File $summary -Encoding UTF8 -Append

# Connect (branch correctly for password vs key)
try {
  if ($KeyPath) {
    # Key based
    $session = Open-OneFSSession -TargetHost $TargetHost -Port $Port -Username $Username -KeyPath $KeyPath -ErrorAction Stop
  } else {
    # Password based — wrapper expects BOTH -Username and -Credential
    $session = Open-OneFSSession -TargetHost $TargetHost -Port $Port -Username $Username -Credential $Credential -ErrorAction Stop
  }
} catch {
  throw ("Failed to open SSH session to {0}:{1} — {2}" -f $TargetHost, $Port, $_.Exception.Message)
}

# Posh-SSH can return a collection. Unwrap safely.
$session0 = @($session)[0]
$client   = if ($session0.PSObject.Properties['Session']) { $session0.Session } else { $session0 }

# Collect raw sections
$files = Invoke-OneFSWeeklyBlocks -Client $client -OutFolder $OutFolder -ZoneName $ZoneName -TimeoutSec $TimeoutSec

# --- Derive a friendly display name for the report header ---
# Default to whatever was targeted
$ClusterDisplayName = $TargetHost

try {
  # Prefer parsing the raw 'isi status' output we just collected
  $statusFile = Join-Path $OutFolder '01_Cluster_Node_Status.txt'
  if (Test-Path -LiteralPath $statusFile) {
    $raw = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      # Look for: "Cluster Name: Arete-AT4-PS01"
      $m = [regex]::Match($raw, '^\s*Cluster Name:\s*(.+?)\s*$', 'Multiline')
      if ($m.Success -and $m.Groups[1].Value) {
        $ClusterDisplayName = $m.Groups[1].Value.Trim()
      }
    }
  }
} catch {
  Write-Warning "Unable to parse cluster name from isi status: $($_.Exception.Message)"
}

# Classify health and write quick summary
$classification = Classify-Sections -Files $files
Add-SectionSummary -SummaryPath $summary -Classification $classification

# Parse JSON and build HTML report
$parsed = Parse-OneFSData -Client $client -OutFolder $OutFolder -ZoneName $ZoneName -TimeoutSec $TimeoutSec -Files $files
$report = New-OneFSHtmlReport -OutFolder $OutFolder -ClusterName $ClusterDisplayName -Classification $classification -Parsed $parsed -Files $files

Write-Host "Report created: $report"
