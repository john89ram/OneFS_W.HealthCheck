# OneFS.Connection.psm1
# Provides New-OneFSSession (approved verb) and a compat alias Open-OneFSSession.

# Load dependency (Posh-SSH). We don't auto-install here to keep behavior explicit.
try {
  if (-not (Get-Module -ListAvailable -Name Posh-SSH)) {
    throw "Missing dependency 'Posh-SSH'. Install it first: Install-Module Posh-SSH -Scope CurrentUser"
  }
  Import-Module Posh-SSH -ErrorAction Stop
} catch {
  throw "Unable to load Posh-SSH: $($_.Exception.Message)"
}

function New-OneFSSession {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$TargetHost,
    [int]$Port = 22,

    # Password auth:
    [string]$Username,
    [System.Management.Automation.PSCredential]$Credential,

    # Key auth (takes precedence if provided and file exists):
    [string]$KeyPath,

    # Advanced: opt-out of accepting host keys on first connect
    [switch]$DoNotAcceptKey
  )

  try {
    $accept = -not $DoNotAcceptKey.IsPresent

    if ($KeyPath -and (Test-Path -Path $KeyPath)) {
      if (-not $Username) {
        throw "Key auth requires -Username as well as -KeyPath."
      }
      $sess = New-SSHSession `
        -ComputerName $TargetHost `
        -Port         $Port `
        -Username     $Username `
        -KeyFile      $KeyPath `
        -AcceptKey:$accept `
        -ErrorAction  Stop
    }
    else {
      if (-not $Credential -or -not $Username) {
        throw "Password auth requires both -Username and -Credential."
      }
      $sess = New-SSHSession `
        -ComputerName $TargetHost `
        -Port         $Port `
        -Credential   $Credential `
        -AcceptKey:$accept `
        -ErrorAction  Stop
    }

    if (-not $sess) { throw "New-SSHSession returned no session." }

    # Return whatever Posh-SSH returns (can be an array). Callers usually take the first item.
    return $sess
  }
  catch {
    throw "SSH connection failed: $($_.Exception.Message)"
  }
}

# Back-compat alias so existing scripts calling Open-OneFSSession continue to work
Set-Alias -Name Open-OneFSSession -Value New-OneFSSession -Option ReadOnly -Force

# Export the approved function and the alias
Export-ModuleMember -Function New-OneFSSession -Alias Open-OneFSSession