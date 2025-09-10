function Ensure-Module {
  param([Parameter(Mandatory)][string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Install-Module $Name -Scope CurrentUser -Force -ErrorAction Stop
  }
  Import-Module $Name -ErrorAction Stop
}

function New-ReportFolder {
  param([Parameter(Mandatory)][string]$Root)
  if (-not (Test-Path $Root)) { New-Item -ItemType Directory -Path $Root -Force | Out-Null }
  $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
  $path = Join-Path $Root $stamp
  New-Item -ItemType Directory -Path $path -Force | Out-Null
  return $path
}

function Write-Line {
  param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Text)
  $Text | Out-File -FilePath $Path -Encoding UTF8 -Append
}

Export-ModuleMember -Function Ensure-Module,New-ReportFolder,Write-Line
