# BGInfo Deployment Automation

Automated, hands-off deployment of [Sysinternals BGInfo](https://learn.microsoft.com/en-us/sysinternals/downloads/bginfo) so it runs at every interactive user logon and applies a standardized desktop wallpaper with system information.

The deployment is handled by a single idempotent script: [DeployAndConfigureBgInfo.ps1](./DeployAndConfigureBgInfo.ps1). It can be re-run safely at any time and requires zero manual follow-up.

---

## What the script does

1. **Acquires the files it needs** (executables, configuration, wallpaper) from the best available source — see [Source priority](#source-priority) below.
2. **Keeps files up to date by default.** On every run (unless `-SkipOnlineUpdateCheck` is used or a `-SourcePath` share is supplied), the local executable, `.bgi` and wallpaper are compared (SHA-256) against their online sources and replaced when the content differs.
3. **Verifies the BGInfo configuration (`.bgi`) file exists.** This file is authored in the BGInfo GUI and is treated as read-only input: the script **never generates or modifies it** — it only deploys the file you provide.
4. **Ensures the wallpaper image referenced inside the `.bgi` is present.** A missing wallpaper is a warning, not a fatal error (BGInfo still applies, just without the background image).
5. **Removes the legacy `HKLM\...\Run` registry value** (`BgInfo`) if an older deployment created it, preventing BGInfo from launching twice at logon.
6. **Creates/refreshes the all-users Startup shortcut** so BGInfo runs for every user at logon. The `.lnk` is generated from scratch on every run (self-healing); it never needs to be staged anywhere.
7. **Runs BGInfo immediately** so the wallpaper is applied in the current session without waiting for the next logon.

### Default paths

| Item | Default location |
|---|---|
| BGInfo executable | `C:\SysAdmin\Tools\SysinternalsSuite\Bginfo64.exe` |
| Configuration file | `C:\ProgramData\BGInfo\BGInfoStandard.bgi` |
| Wallpaper image | `C:\SysAdmin\Images\WindowsServer2028.jpg` |
| Startup shortcut | `C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Bginfo64.exe.lnk` |

The shortcut launches:

```
Bginfo64.exe "C:\ProgramData\BGInfo\BGInfoStandard.bgi" /timer:0 /nolicprompt /silent
```

---

## Source priority

For each required file the script works down this list and stops at the first source that provides it:

| File | 1st choice | 2nd choice | 3rd choice |
|---|---|---|---|
| `Bginfo64.exe` / `Bginfo.exe` | `-SourcePath` file share | Sysinternals `BGInfo.zip` download | GitHub repo (`-OnlineSourceUrl`) |
| `BGInfoStandard.bgi` | `-SourcePath` file share | Existing local copy | GitHub repo (`-OnlineSourceUrl`) |
| `WindowsServer2028.jpg` | `-SourcePath` file share | Existing local copy / `-WallpaperUrl` | GitHub repo (`-OnlineSourceUrl`) |
| `Bginfo64.exe.lnk` | *Always generated from scratch — never copied or downloaded* | | |

Notes:

- **The file share always wins and overwrites local copies.** When `-SourcePath` is used, the share is the single source of truth.
- **A partially stocked share still works.** Missing files log a warning and fall through to the next source instead of failing.
- The default online source is the companion GitHub repository
  [WorkingHardInIT/BgInfoDeployment](https://github.com/WorkingHardInIT/BgInfoDeployment), which hosts `Bginfo.exe`, `Bginfo64.exe`, `BGInfoStandard.bgi` and `WindowsServer2028.jpg`.
  Raw URLs on `main` always serve the latest commit, so pushing an updated `.bgi` or wallpaper automatically updates deployments.
- **Online update checking is on by default**: each run compares the local executable (against Sysinternals), the `.bgi` and the wallpaper (against the GitHub repo) by SHA-256 and replaces any file whose content differs. Opt out with `-SkipOnlineUpdateCheck` on metered/slow links. The check is skipped automatically when `-SourcePath` is supplied (the share is then authoritative) and a failed check never touches the existing local file.
- Downloads go to a temp file first and are moved into place only on success, so a failed download can never leave a corrupt file behind.

---

## Usage

Run from an elevated PowerShell prompt (the script enforces `#Requires -RunAsAdministrator`).

```powershell
# Standard run - keeps everything up to date against Sysinternals and the GitHub repo
.\DeployAndConfigureBgInfo.ps1

# Deploy from an internal file share (share contents are authoritative; online check skipped)
.\DeployAndConfigureBgInfo.ps1 -SourcePath '\\fileserver\Deploy\BGInfo'

# Fast run without any online update checking (metered/slow connections)
.\DeployAndConfigureBgInfo.ps1 -SkipOnlineUpdateCheck

# Opt in to hands-free monthly maintenance (scheduled task, 1st of the month, 03:00, SYSTEM)
.\DeployAndConfigureBgInfo.ps1 -RegisterMonthlyTask

# Force a fresh download of the latest BGInfo executable
.\DeployAndConfigureBgInfo.ps1 -UpdateBgInfo

# Use a custom online source for the wallpaper only
.\DeployAndConfigureBgInfo.ps1 -WallpaperUrl 'https://intranet.contoso.com/branding/WindowsServer2028.jpg'

# Air-gapped machine: disable all online sources and rely on the share only
.\DeployAndConfigureBgInfo.ps1 -SourcePath '\\fileserver\Deploy\BGInfo' -OnlineSourceUrl ''
```

### Parameters

| Parameter | Default | Purpose |
|---|---|---|
| `-SourcePath` | *(none)* | UNC share or folder with the deployment source files. Copied with overwrite when supplied. |
| `-BgInfoExe` | `C:\SysAdmin\Tools\SysinternalsSuite\Bginfo64.exe` | Where the BGInfo executable lives (and is installed to). |
| `-BgInfoConfig` | `C:\ProgramData\BGInfo\BGInfoStandard.bgi` | The `.bgi` configuration used by the shortcut and the immediate run. |
| `-StartupShortcut` | `C:\ProgramData\...\Startup\Bginfo64.exe.lnk` | All-users Startup shortcut path. |
| `-WallpaperPath` | `C:\SysAdmin\Images\WindowsServer2028.jpg` | Local wallpaper path. **Must match the Wallpaper path stored inside the `.bgi`.** |
| `-WallpaperUrl` | *(none)* | Explicit online source for the wallpaper; overrides the online source repo for that file. |
| `-OnlineSourceUrl` | `https://raw.githubusercontent.com/WorkingHardInIT/BgInfoDeployment/main` | Base URL of the online fallback repository. Set to `''` to disable online fallbacks. |
| `-BgInfoDownloadUrl` | `https://download.sysinternals.com/files/BGInfo.zip` | Primary download for the BGInfo executable. |
| `-UpdateBgInfo` | off | Re-download the executable even if it already exists (ignored when the share supplies it). |
| `-SkipOnlineUpdateCheck` | off (checking enabled) | Skip the default per-run SHA-256 comparison against the online sources. Checking is also skipped automatically when `-SourcePath` is supplied. |
| `-RegisterMonthlyTask` | off (opt-in) | Register/refresh the `BGInfo Monthly Maintenance` scheduled task. Without this switch no task is ever created or modified. |

---

## Scheduled monthly maintenance (opt-in)

Running the script with `-RegisterMonthlyTask` registers a scheduled task that keeps the machine current with zero further interaction:

| Setting | Value |
|---|---|
| Task name | `BGInfo Monthly Maintenance` |
| Schedule | 1st of every month, 03:00 |
| Account | `SYSTEM` (highest privileges) |
| Action | Re-runs `DeployAndConfigureBgInfo.ps1` with default settings (online update check enabled) |
| Logging | All output appended to `DeployAndConfigureBgInfo.log` next to the script |

Notes:

- **Strictly opt-in**: normal runs never create or modify the task; the configuration banner reminds you with `Monthly task : not requested (opt in with -RegisterMonthlyTask)`.
- Re-running with the switch refreshes the task definition (idempotent, `/F`).
- Remove it with: `schtasks /Delete /TN "BGInfo Monthly Maintenance" /F`.
- Verified end-to-end: the task was force-run under SYSTEM, returned `Last Result: 0`, and wrote a complete successful run to the log.

---

## Design decisions

### Startup shortcut vs. registry Run entry

Both an all-users Startup folder shortcut and an `HKLM\...\Run` value are **functionally equivalent**: both run at every interactive logon for all users, both appear in Task Manager's Startup tab, and both require admin rights to modify. This deployment uses the **Startup shortcut** because it is self-documenting and visible, while the script **removes the legacy registry value** so BGInfo can never start twice.

### The `.lnk` is generated, never copied

A pre-built shortcut would hard-code paths from the machine it was created on. Generating it from the script's parameters guarantees it always points at the correct local paths, and rewriting it on every run makes it self-healing against deletion or tampering.

### The `.bgi` is deployed verbatim, never edited in code

The `.bgi` file is an undocumented, proprietary binary serialization (typed records with embedded RTF). Programmatic editing is unsafe and risks corruption. The supported workflow is:

1. Edit the configuration in the BGInfo GUI (`Bginfo64.exe`, open `BGInfoStandard.bgi`, save).
2. Publish the updated file to the file share and/or the GitHub repo.
3. Re-run the script on target machines (or just wait — users get the new config at next deployment).

### Wallpaper caveat

The `.bgi` references the wallpaper by **absolute local path** (`C:\SysAdmin\Images\WindowsServer2028.jpg`). That image must exist at that exact path on every target machine — which is why the script deploys it alongside the other files. If you change the wallpaper path inside the `.bgi`, pass the matching `-WallpaperPath`.

---

## Verified scenarios

All four acquisition paths were tested end-to-end:

| Scenario | Setup | Result |
|---|---|---|
| **A — All local, default run** | Everything in place, update check on | Exe/`.bgi`/wallpaper verified against online sources: "already the latest ... (SHA256 match)"; shortcut refreshed |
| **B — Online config/wallpaper** | `.bgi` and wallpaper missing locally | Both auto-downloaded from the GitHub repo; SHA-256 hashes match the masters |
| **C — Sysinternals outage** | Executable missing, Sysinternals URL unreachable | Warning logged; `Bginfo64.exe` fetched from the GitHub repo; hash matches |
| **D — Internal file share** | `-SourcePath` stocked with exe, `.bgi`, wallpaper | Hash-compared per file: unchanged files report "up to date - no copy needed", changed files report "UPDATED from source" |
| **E — Stale local file, default run** | Local `.bgi` content differs from the GitHub repo | Auto-replaced: "UPDATED from online source"; resulting hash matches the repo master |
| **F — `-SkipOnlineUpdateCheck`** | Everything local | No downloads at all; files kept as-is; still idempotent |

---

## Error handling & logging

- `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` throughout.
- Timestamped, color-coded log output (`INFO` / `SUCCESS` / `WARNING` / `ERROR`), including an **effective-configuration banner** (all paths and URLs in play), per-file detail (size, modification date, SHA-256 prefix, exe version) and a **deployment summary** of the final state.
- Fatal problems (no executable from any source, no `.bgi` from any source, shortcut folder missing, BGInfo non-zero exit code) terminate with **exit code 1** so RMM/GPO/scheduler tooling detects failures.
- Non-fatal problems (file absent from the share, wallpaper unavailable, a failed online update check) log a `WARNING` and continue — an update-check failure always keeps the current local file.

## Requirements

- Windows with PowerShell 5.1 or later
- Administrator rights (enforced via `#Requires -RunAsAdministrator`)
- TLS 1.2 capable (enabled by the script; relevant for Windows Server 2016)
- Internet access is only required when a file is missing locally and no `-SourcePath` share provides it
