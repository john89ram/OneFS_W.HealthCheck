OneFS_W.HealthCheck

PowerShell toolkit for running a weekly health check against Dell EMC PowerScale (Isilon) OneFS clusters.
It reads your config, runs modular checks, and outputs a concise report you can drop into a ticket, email, or a wiki.

Repo layout: Run-OneFSWeeklyCheck.ps1 (entry point), configs/ (your environment settings), modules/ (functions), .vscode/ (editor settings). 
GitHub

Features

Modular checks for OneFS status (cluster, capacity, hardware, services, jobs)

Config-driven targets and credentials

Friendly console output and optional saved report (CSV / HTML / Markdown)

Easy to schedule via Windows Task Scheduler

Requirements

Windows 10/11 or Windows Server with PowerShell 5.1+ (PowerShell 7+ recommended)

Network access to OneFS cluster(s)

OneFS account with read privileges (Platform/API read, or SSH read-only if modules use CLI)

Execution policy that allows running local scripts

# Run PowerShell as Administrator once:
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

Quick start

Clone the repo

git clone https://github.com/john89ram/OneFS_W.HealthCheck.git
cd OneFS_W.HealthCheck


Configure your environment

Copy the sample config from configs/ and update values:

Cluster list (FQDN or IP)

Auth method (API token, username/password, or SSH key path)

Output preferences (path, formats)

Email settings (optional)

Example configs/env.sample.json

{
  "clusters": [
    {"name": "DataCenter1", "host": "10.10.10.10"},
    {"name": "DataCenter2_DR",   "host": "10.100.10.10"}
  ],
  "auth": {
    "method": "basic",
    "username": "readonly",
    "password_secret_name": "ONEFS_READONLY"
  },
  "output": {
    "path": ".\\reports",
    "formats": ["markdown", "csv"]
  },
  "email": {
    "enabled": false,
    "smtp_server": "smtp.example.com",
    "from": "onefs-bot@example.com",
    "to": ["storage-team@example.com"]
  }
}


Tip: store secrets in Windows Credential Manager and reference them by name.
If you prefer environment variables, note that in the config and the script will read them.

Run it

# From repo root
.\Run-OneFSWeeklyCheck.ps1 -ConfigPath ".\configs\env.json"


Common parameters:

-ConfigPath Path to your config file

-Cluster Run against a single cluster name from your config

-OutPath Override output directory for this run

-Verbose Get more detail during execution

-WhatIf Dry run to validate config and connectivity

What the checks include

The exact set depends on the functions under modules/. Here’s the intended coverage—add/remove as your modules evolve.

Cluster health: summary state, alerts, quorum, node states

Capacity: total/used/free, efficiency, hot thresholds

Hardware: disk health, smartfail/suspect, PSU/fan, node sensors

Services & jobs: protocol services, SyncIQ / Job Engine status and recent failures

Protection: RF/erasure coding target vs actual, rebalance progress

SMB/NFS exposure (optional): shares/exports sanity, orphan paths

Errors & events: last 7 days critical warnings

Output

Markdown report for tickets/wikis

CSV tables for quick filtering

HTML (optional) if you want a styled report

Output files are saved under reports\YYYY-MM-DD\ unless overridden.

Scheduling (Windows Task Scheduler)

Open Task Scheduler → Create Task…

Triggers: Weekly, pick your day/time.

Actions:

Program/script: pwsh.exe (or powershell.exe)

Arguments:

-NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\OneFS_W.HealthCheck\Run-OneFSWeeklyCheck.ps1" -ConfigPath "C:\Path\To\OneFS_W.HealthCheck\configs\env.json"


Start in: C:\Path\To\OneFS_W.HealthCheck

Run whether user is logged on or not and Run with highest privileges.

Developing modules

Put new functions under modules/ as separate .ps1 files.

Use a simple pattern:

function Invoke-Check-Capacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Cluster,
        [Parameter(Mandatory)]$Session
    )
    # return a PSCustomObject with standardized fields
    [pscustomobject]@{
        Cluster = $Cluster.Name
        Check   = 'Capacity'
        Status  = 'OK'       # OK | Warning | Critical | Unknown
        Detail  = 'Used 62.4% (412 / 660 TB), threshold 80%'
        Data    = @{ UsedPct = 62.4; TotalTB = 660; UsedTB = 412 }
    }
}


The main runner should:

Import all modules/*.ps1

Build a OneFS session (API/SSH) per cluster

Invoke each Invoke-Check-* function

Aggregate results and render outputs

Logging & exit codes

Console logs go to stdout/stderr.

A run summary is written to reports\YYYY-MM-DD\run.log.

Exit code: 0 success, 1 partial failures, 2 hard failure (no clusters reached).

Troubleshooting

Auth fails: verify the account role on OneFS and that the time is in sync (Kerberos/AD envs can be strict).

No output: run with -Verbose and check run.log.

Modules not found: ensure modules\ is on the $PSScriptRoot import path in the runner.

Execution policy: run Get-ExecutionPolicy -List and set CurrentUser to RemoteSigned.

Roadmap

Optional HTML dashboard with sparkline trends

Slack/Teams notifications on warnings/criticals

Per-cluster baselines with drift detection

Contributing

PRs welcome—lint with PSScriptAnalyzer, keep public functions verb-noun, and return typed objects that can be converted to CSV/MD cleanly.

License

MIT (or your preference—add a LICENSE file if you want something else).