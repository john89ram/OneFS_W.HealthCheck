📓 Changelog
All notable changes to OneFS_W.HealthCheck will be documented in this file.
This project uses Semantic Versioning
.

[Unreleased]
Add additional health modules (NFS, SMB, SyncIQ, etc.)
Expand output options (Teams/Slack notifications, dashboards)
Automate packaging (PowerShell module publishing)

[1.1.0] – 2025-09-09
Changed
Major refactor of module logic
Adjusted configs layout under configs/
Runner updated with new parameters
Issue: Source diverged from stable, required fallback to backup copy

[1.0.0] – 2025-08-15
Added
Initial working release (Run-OneFSWeeklyCheck.ps1)
Config-driven execution with JSON file
Core modules for: cluster health, capacity, hardware, services, jobs
Markdown/CSV reporting
Example configs/env.sample.json

[0.1.0] – 2025-08-01
Prototype
First functional draft, not yet stable
Console-only output
Hardcoded cluster values for testing