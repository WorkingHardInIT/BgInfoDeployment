#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Deploys and configures BGInfo to run at user logon via an all-users Startup folder shortcut.

.DESCRIPTION
    - Optionally copies the BGInfo executable(s), the .bgi configuration file and the wallpaper image from a file share (-SourcePath).
    - Ensures Bginfo64.exe is present in the Sysinternals tools folder (downloads it if still missing, or when -UpdateBgInfo is used).
      Downloads try Sysinternals first, then fall back to the online source repository (-OnlineSourceUrl).
    - By default, compares the local executable, .bgi configuration and wallpaper against their online sources on
      every run and updates any file whose content differs (opt out with -SkipOnlineUpdateCheck).
    - Verifies the BGInfo configuration (.bgi) file exists. The .bgi file is a binary file authored in the BGInfo
      GUI; this script never generates or modifies it - it only deploys the file you provide. If missing locally,
      it is downloaded from the online source repository.
    - Ensures the wallpaper image referenced by the .bgi is present, downloading it from -WallpaperUrl or the
      online source repository when missing.
    - Removes the legacy HKLM Run registry value (if present) so BGInfo does not start twice.
    - Creates/refreshes an all-users Startup shortcut so BGInfo runs at every interactive logon.
    - Applies the wallpaper immediately for the current session.

    The script is idempotent: it can be re-run safely at any time.

.PARAMETER SourcePath
    Optional UNC share or local folder containing the deployment source files:
    Bginfo64.exe (and optionally Bginfo.exe), the .bgi configuration file, and
    optionally the wallpaper image referenced by the .bgi.
    When supplied, those files are copied from the share (overwriting local copies),
    making the share the single source of truth. If the exe is absent from the share,
    the script falls back to downloading it from Sysinternals.

.PARAMETER BgInfoExe
    Full path to Bginfo64.exe.

.PARAMETER BgInfoConfig
    Full path to the BGInfo configuration (.bgi) file.

.PARAMETER StartupShortcut
    Full path to the all-users Startup folder shortcut (.lnk).

.PARAMETER WallpaperPath
    Full local path of the wallpaper image referenced inside the .bgi configuration.
    Must match the Wallpaper path stored in the .bgi file. The script ensures the image
    is present (from the share, then from -WallpaperUrl) and warns if it is missing.

.PARAMETER WallpaperUrl
    Optional online (HTTP/HTTPS) source for the wallpaper image. Used only when the
    image is not already present locally and was not copied from -SourcePath.
    When omitted, the online source repository (-OnlineSourceUrl) is used instead.

.PARAMETER OnlineSourceUrl
    Base URL of the online source repository hosting the deployment files
    (Bginfo64.exe, Bginfo.exe, the .bgi configuration and the wallpaper image).
    Used as a fallback when files are missing locally, absent from -SourcePath,
    or when the Sysinternals download fails. Set to '' to disable the fallback.

.PARAMETER UpdateBgInfo
    Re-download the latest BGInfo from Sysinternals even if Bginfo64.exe already exists.
    Ignored for the exe when -SourcePath supplies it.

.PARAMETER SkipOnlineUpdateCheck
    By default the script compares the local executable, .bgi configuration and wallpaper
    against their online sources (Sysinternals and -OnlineSourceUrl) on every run and
    replaces any file whose content differs (SHA256 comparison; files are downloaded to a
    temp location first and a failed download never touches the local copy). Use this
    switch to skip that check on metered or slow connections. The check is also skipped
    automatically when -SourcePath is supplied (the share is then the authoritative
    source) or when -OnlineSourceUrl is disabled.

.PARAMETER RegisterMonthlyTask
    Opt-in: register (or refresh) a scheduled task named 'BGInfo Monthly Maintenance'
    that re-runs this script as SYSTEM on the 1st of every month at 03:00, keeping the
    deployment up to date hands-free. Task output is appended to a log file next to the
    script. Without this switch, no scheduled task is created or modified.

.EXAMPLE
    .\DeployAndConfigureBgInfo.ps1

.EXAMPLE
    .\DeployAndConfigureBgInfo.ps1 -SourcePath '\\fileserver\Deploy\BGInfo'

.EXAMPLE
    .\DeployAndConfigureBgInfo.ps1 -WallpaperUrl 'https://intranet.contoso.com/branding/WindowsServer2028.jpg'

.EXAMPLE
    .\DeployAndConfigureBgInfo.ps1 -UpdateBgInfo

.EXAMPLE
    .\DeployAndConfigureBgInfo.ps1 -SkipOnlineUpdateCheck

.EXAMPLE
    .\DeployAndConfigureBgInfo.ps1 -RegisterMonthlyTask
#>

[CmdletBinding()]
param (
    [string]$SourcePath,

    [ValidateNotNullOrEmpty()]
    [string]$BgInfoExe = 'C:\SysAdmin\Tools\SysinternalsSuite\Bginfo64.exe',

    [ValidateNotNullOrEmpty()]
    [string]$BgInfoConfig = 'C:\ProgramData\BGInfo\BGInfoStandard.bgi',

    [ValidateNotNullOrEmpty()]
    [string]$StartupShortcut = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup\Bginfo64.exe.lnk',

    [ValidateNotNullOrEmpty()]
    [string]$WallpaperPath = 'C:\SysAdmin\Images\WindowsServer2028.jpg',

    [string]$WallpaperUrl,

    [string]$OnlineSourceUrl = 'https://raw.githubusercontent.com/WorkingHardInIT/BgInfoDeployment/main',

    [ValidateNotNullOrEmpty()]
    [string]$BgInfoDownloadUrl = 'https://download.sysinternals.com/files/BGInfo.zip',

    [switch]$UpdateBgInfo,

    [switch]$SkipOnlineUpdateCheck,

    [switch]$RegisterMonthlyTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# BGInfo command-line arguments: apply config instantly, suppress EULA prompt and UI
$bgInfoArguments = '"{0}" /timer:0 /nolicprompt /silent' -f $BgInfoConfig

# Legacy autostart registry value created by earlier versions of this script (must be removed to avoid double start)
$legacyRegPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$legacyRegName = 'BgInfo'

# Opt-in monthly maintenance scheduled task (created only with -RegisterMonthlyTask)
$maintenanceTaskName = 'BGInfo Monthly Maintenance'
$maintenanceLogPath  = Join-Path -Path $PSScriptRoot -ChildPath 'DeployAndConfigureBgInfo.log'

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $color = switch ($Level) {
        'Info'    { 'Cyan' }
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host ('[{0}] [{1,-7}] {2}' -f $timestamp, $Level.ToUpper(), $Message) -ForegroundColor $color
}

function Get-RemoteFile {
    <#
        Downloads a file to a temp location first, then moves it into place,
        so a failed download never leaves a corrupt or partial file behind.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $destinationFolder = Split-Path -Path $Destination -Parent
    if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        Write-Log "Created folder: $destinationFolder"
    }

    $tempFile = Join-Path -Path $env:TEMP -ChildPath "Download_$([guid]::NewGuid())$([IO.Path]::GetExtension($Destination))"
    try {
        Write-Log "Downloading $Url ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing
        Move-Item -LiteralPath $tempFile -Destination $Destination -Force
        Write-Log ('Downloaded to: {0} ({1:N0} bytes)' -f $Destination, (Get-Item -LiteralPath $Destination).Length) -Level Success
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-FileDetail {
    <# Returns a human-readable one-liner with size, modification date and SHA256 prefix for log output. #>
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $item = Get-Item -LiteralPath $Path
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    '{0:N0} bytes, modified {1:yyyy-MM-dd HH:mm}, SHA256 {2}...' -f $item.Length, $item.LastWriteTime, $hash.Substring(0, 16)
}

function Copy-FileIfChanged {
    <#
        Copies a file only when the destination is missing or differs (SHA256 comparison),
        and reports exactly what happened: deployed new, updated, or already up to date.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$SourceFile,

        [Parameter(Mandatory)]
        [string]$DestinationFile
    )

    $name = Split-Path -Path $SourceFile -Leaf

    $destinationFolder = Split-Path -Path $DestinationFile -Parent
    if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        Write-Log "Created folder: $destinationFolder"
    }

    if (Test-Path -LiteralPath $DestinationFile -PathType Leaf) {
        $sourceHash      = (Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $DestinationFile -Algorithm SHA256).Hash
        if ($sourceHash -eq $destinationHash) {
            Write-Log "$name is already up to date (SHA256 match with source) - no copy needed"
            return
        }
        Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force
        Write-Log "$name UPDATED from source: local copy differed ($(Get-FileDetail $DestinationFile))" -Level Success
    }
    else {
        Copy-Item -LiteralPath $SourceFile -Destination $DestinationFile -Force
        Write-Log "$name deployed (new file): $(Get-FileDetail $DestinationFile)" -Level Success
    }
}

function Update-FileFromUrl {
    <#
        Downloads the online version to a temp file, compares it (SHA256) with the local copy,
        and replaces the local copy only when the content differs. A failed download never
        touches the existing local file.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Url,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $name     = Split-Path -Path $Destination -Leaf
    $tempFile = Join-Path -Path $env:TEMP -ChildPath "Check_$([guid]::NewGuid())$([IO.Path]::GetExtension($Destination))"
    try {
        Write-Log "Checking $name against online source: $Url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $tempFile -UseBasicParsing

        $onlineHash = (Get-FileHash -LiteralPath $tempFile -Algorithm SHA256).Hash
        $localHash  = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
        if ($onlineHash -eq $localHash) {
            Write-Log "$name is already the latest online version (SHA256 match) - no update needed"
        }
        else {
            Move-Item -LiteralPath $tempFile -Destination $Destination -Force
            Write-Log "$name UPDATED from online source ($(Get-FileDetail $Destination))" -Level Success
        }
    }
    catch {
        Write-Log "Online update check for $name failed ($($_.Exception.Message)) - keeping the current local copy" -Level Warning
    }
    finally {
        Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Copy-BgInfoFromSource {
    param (
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$DestinationExe,

        [Parameter(Mandatory)]
        [string]$DestinationConfig,

        [Parameter(Mandatory)]
        [string]$DestinationWallpaper
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Source path not found or not reachable: $Source"
    }
    Write-Log "Using deployment source: $Source"

    # Copy the BGInfo executable(s): Bginfo64.exe is required for the shortcut; Bginfo.exe is copied if offered
    $exeFolder = Split-Path -Path $DestinationExe -Parent
    $exeNames  = @((Split-Path -Path $DestinationExe -Leaf), 'Bginfo.exe') | Select-Object -Unique
    foreach ($exeName in $exeNames) {
        $sourceExe = Join-Path -Path $Source -ChildPath $exeName
        if (Test-Path -LiteralPath $sourceExe -PathType Leaf) {
            Copy-FileIfChanged -SourceFile $sourceExe -DestinationFile (Join-Path -Path $exeFolder -ChildPath $exeName)
        }
        elseif ($exeName -eq (Split-Path -Path $DestinationExe -Leaf)) {
            Write-Log "$exeName not found on source share; will fall back to download if not already installed" -Level Warning
        }
    }

    # Copy the .bgi configuration file (the file you authored in the BGInfo GUI - never generated by this script)
    $configName   = Split-Path -Path $DestinationConfig -Leaf
    $sourceConfig = Join-Path -Path $Source -ChildPath $configName
    if (Test-Path -LiteralPath $sourceConfig -PathType Leaf) {
        Copy-FileIfChanged -SourceFile $sourceConfig -DestinationFile $DestinationConfig
    }
    else {
        Write-Log "$configName not found on source share; the existing local copy will be used if present" -Level Warning
    }

    # Copy the wallpaper image referenced by the .bgi configuration, if the share offers it
    $wallpaperName   = Split-Path -Path $DestinationWallpaper -Leaf
    $sourceWallpaper = Join-Path -Path $Source -ChildPath $wallpaperName
    if (Test-Path -LiteralPath $sourceWallpaper -PathType Leaf) {
        Copy-FileIfChanged -SourceFile $sourceWallpaper -DestinationFile $DestinationWallpaper
    }
    else {
        Write-Log "$wallpaperName not found on source share; existing local copy or -WallpaperUrl will be used" -Level Warning
    }
}

function Install-Wallpaper {
    param (
        [Parameter(Mandatory)]
        [string]$DestinationWallpaper,

        [string]$DownloadUrl
    )

    if (Test-Path -LiteralPath $DestinationWallpaper -PathType Leaf) {
        Write-Log "Wallpaper image found: $DestinationWallpaper ($(Get-FileDetail $DestinationWallpaper))"
        return
    }

    if (-not [string]::IsNullOrWhiteSpace($DownloadUrl)) {
        try {
            Get-RemoteFile -Url $DownloadUrl -Destination $DestinationWallpaper
            return
        }
        catch {
            Write-Log "Wallpaper download failed: $($_.Exception.Message)" -Level Warning
        }
    }

    # Missing wallpaper is not fatal: BGInfo still applies, just without the background image
    Write-Log "Wallpaper image not found: $DestinationWallpaper. The .bgi references it; the desktop background may be blank until it is provided." -Level Warning
}

function Install-BgInfoExecutable {
    param (
        [Parameter(Mandatory)]
        [string]$DestinationExe,

        [Parameter(Mandatory)]
        [string]$DownloadUrl,

        [string]$FallbackUrlBase,

        [switch]$Force,

        [switch]$CheckUpdate
    )

    $alreadyPresent = Test-Path -LiteralPath $DestinationExe -PathType Leaf
    if ($alreadyPresent) {
        $version = (Get-Item -LiteralPath $DestinationExe).VersionInfo.ProductVersion
        Write-Log "BGInfo executable present: $DestinationExe (version $version; $(Get-FileDetail $DestinationExe))"
        if (-not $Force -and -not $CheckUpdate) {
            Write-Log 'Online update check disabled for this run; the current executable is kept as-is'
            return
        }
    }

    $destinationFolder = Split-Path -Path $DestinationExe -Parent
    if (-not (Test-Path -LiteralPath $destinationFolder -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationFolder -Force | Out-Null
        Write-Log "Created folder: $destinationFolder"
    }

    $exeName     = Split-Path -Path $DestinationExe -Leaf
    $tempZip     = Join-Path -Path $env:TEMP -ChildPath "BGInfo_$([guid]::NewGuid()).zip"
    $tempExtract = Join-Path -Path $env:TEMP -ChildPath "BGInfo_$([guid]::NewGuid())"

    try {
        Write-Log "Downloading BGInfo from $DownloadUrl ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $tempZip -UseBasicParsing

        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force

        $extractedExe = Join-Path -Path $tempExtract -ChildPath $exeName
        if (-not (Test-Path -LiteralPath $extractedExe -PathType Leaf)) {
            throw "Downloaded archive does not contain '$exeName'."
        }

        # When the executable already exists, only replace it if the online version actually differs
        if ($alreadyPresent) {
            $onlineHash = (Get-FileHash -LiteralPath $extractedExe -Algorithm SHA256).Hash
            $localHash  = (Get-FileHash -LiteralPath $DestinationExe -Algorithm SHA256).Hash
            if ($onlineHash -eq $localHash) {
                Write-Log "$exeName is already the latest Sysinternals version (SHA256 match) - no update needed"
                return
            }
            $oldVersion = (Get-Item -LiteralPath $DestinationExe).VersionInfo.ProductVersion
            Copy-Item -LiteralPath $extractedExe -Destination $DestinationExe -Force
            Write-Log "$exeName UPDATED from Sysinternals: version $oldVersion -> $((Get-Item -LiteralPath $DestinationExe).VersionInfo.ProductVersion) ($(Get-FileDetail $DestinationExe))" -Level Success
            return
        }

        Copy-Item -LiteralPath $extractedExe -Destination $DestinationExe -Force
        Write-Log "BGInfo executable installed: $DestinationExe (version $((Get-Item -LiteralPath $DestinationExe).VersionInfo.ProductVersion); $(Get-FileDetail $DestinationExe))" -Level Success
    }
    catch {
        # During an update check of an existing executable, never let a download failure disturb it
        if ($alreadyPresent) {
            Write-Log "Online update check for $exeName failed ($($_.Exception.Message)) - keeping the current version" -Level Warning
            return
        }
        # Sysinternals is unreachable or the archive was unusable: fall back to the online source repository
        if ([string]::IsNullOrWhiteSpace($FallbackUrlBase)) { throw }
        Write-Log "Sysinternals download failed ($($_.Exception.Message)); trying fallback source" -Level Warning
        Get-RemoteFile -Url ("{0}/{1}" -f $FallbackUrlBase.TrimEnd('/'), $exeName) -Destination $DestinationExe
        Write-Log "BGInfo executable installed from fallback source: $DestinationExe (version $((Get-Item -LiteralPath $DestinationExe).VersionInfo.ProductVersion))" -Level Success
    }
    finally {
        Remove-Item -LiteralPath $tempZip, $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Remove-LegacyAutostartRegistryValue {
    param (
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $existing = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Remove-ItemProperty -Path $Path -Name $Name -Force
        Write-Log "Removed legacy autostart registry value '$Name' from $Path (prevents BGInfo starting twice)" -Level Warning
    }
    else {
        Write-Log 'No legacy autostart registry value found'
    }
}

function Set-StartupShortcut {
    param (
        [Parameter(Mandatory)]
        [string]$ShortcutPath,

        [Parameter(Mandatory)]
        [string]$TargetPath,

        [Parameter(Mandatory)]
        [string]$Arguments
    )

    $shortcutFolder = Split-Path -Path $ShortcutPath -Parent
    if (-not (Test-Path -LiteralPath $shortcutFolder -PathType Container)) {
        throw "Startup folder not found: $shortcutFolder"
    }

    $wshShell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $wshShell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath       = $TargetPath
        $shortcut.Arguments        = $Arguments
        $shortcut.WorkingDirectory = Split-Path -Path $TargetPath -Parent
        $shortcut.Description      = 'Applies the BGInfo desktop wallpaper at logon'
        $shortcut.Save()
        Write-Log "Startup shortcut created/updated: $ShortcutPath" -Level Success
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshShell)
    }
}

function Register-MonthlyMaintenanceTask {
    <#
        Registers (or refreshes) a scheduled task that re-runs this script as SYSTEM on the
        1st of every month at 03:00, appending all output to a log file for later review.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$TaskName,

        [Parameter(Mandatory)]
        [string]$ScriptPath,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $taskCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& '$ScriptPath' *>> '$LogPath'`""
    schtasks.exe /Create /TN $TaskName /SC MONTHLY /D 1 /ST 03:00 /RU SYSTEM /RL HIGHEST /F /TR $taskCommand | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register scheduled task '$TaskName' (schtasks exit code $LASTEXITCODE)."
    }
    Write-Log "Scheduled task registered: '$TaskName' - runs on the 1st of every month at 03:00 as SYSTEM" -Level Success
    Write-Log "Scheduled task output is appended to: $LogPath"
}

## ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

try {
    Write-Log 'Script started'

    # Resolve the effective wallpaper source up front so the configuration banner shows it
    $effectiveWallpaperUrl = $WallpaperUrl
    if ([string]::IsNullOrWhiteSpace($effectiveWallpaperUrl) -and -not [string]::IsNullOrWhiteSpace($OnlineSourceUrl)) {
        $effectiveWallpaperUrl = '{0}/{1}' -f $OnlineSourceUrl.TrimEnd('/'), (Split-Path -Path $WallpaperPath -Leaf)
    }

    # Online update checking is on by default; it is skipped when opted out or when a share is authoritative
    $shareSupplied = -not [string]::IsNullOrWhiteSpace($SourcePath)
    $checkOnline   = -not $SkipOnlineUpdateCheck -and -not $shareSupplied
    $updateCheckState = if ($shareSupplied) { 'Skipped (-SourcePath share is the authoritative source)' }
                        elseif ($SkipOnlineUpdateCheck) { 'Disabled (-SkipOnlineUpdateCheck)' }
                        else { 'Enabled (default)' }

    # Show the effective configuration so every run documents exactly what it will use
    Write-Log '--- Effective configuration -------------------------------------------------'
    Write-Log "Executable target   : $BgInfoExe"
    Write-Log "Configuration (.bgi): $BgInfoConfig"
    Write-Log "Wallpaper target    : $WallpaperPath"
    Write-Log "Startup shortcut    : $StartupShortcut"
    Write-Log ("Source share        : {0}" -f $(if ($shareSupplied) { $SourcePath } else { '(not supplied)' }))
    Write-Log "Sysinternals URL    : $BgInfoDownloadUrl"
    Write-Log ("Online source URL   : {0}" -f $(if ([string]::IsNullOrWhiteSpace($OnlineSourceUrl)) { '(disabled)' } else { $OnlineSourceUrl }))
    Write-Log ("Wallpaper URL       : {0}" -f $(if ([string]::IsNullOrWhiteSpace($effectiveWallpaperUrl)) { '(none)' } else { $effectiveWallpaperUrl }))
    Write-Log "Online update check : $updateCheckState"
    Write-Log ("Force exe update    : {0}" -f $UpdateBgInfo.IsPresent)
    Write-Log ("Monthly task        : {0}" -f $(if ($RegisterMonthlyTask) { "will be registered ('$maintenanceTaskName')" } else { 'not requested (opt in with -RegisterMonthlyTask)' }))
    Write-Log '------------------------------------------------------------------------------'

    # 1. If a source share was supplied, copy the executable(s), the .bgi configuration and the wallpaper from it
    if ($shareSupplied) {
        Copy-BgInfoFromSource -Source $SourcePath -DestinationExe $BgInfoExe -DestinationConfig $BgInfoConfig -DestinationWallpaper $WallpaperPath
    }

    # 2. Ensure the BGInfo executable is available and up to date (update check compares against Sysinternals)
    Install-BgInfoExecutable -DestinationExe $BgInfoExe -DownloadUrl $BgInfoDownloadUrl -FallbackUrlBase $OnlineSourceUrl -Force:$UpdateBgInfo -CheckUpdate:$checkOnline

    # 3. Ensure the BGInfo configuration file exists (authored in the BGInfo GUI - never generated here);
    #    fetch it from the online source repository when missing, or sync it when update checking is on
    if (-not (Test-Path -LiteralPath $BgInfoConfig -PathType Leaf)) {
        if (-not [string]::IsNullOrWhiteSpace($OnlineSourceUrl)) {
            Get-RemoteFile -Url ("{0}/{1}" -f $OnlineSourceUrl.TrimEnd('/'), (Split-Path -Path $BgInfoConfig -Leaf)) -Destination $BgInfoConfig
        }
        else {
            throw "BGInfo configuration file not found: $BgInfoConfig. Place your customized .bgi file there (or supply -SourcePath / -OnlineSourceUrl) and re-run this script."
        }
    }
    elseif ($checkOnline -and -not [string]::IsNullOrWhiteSpace($OnlineSourceUrl)) {
        Update-FileFromUrl -Url ("{0}/{1}" -f $OnlineSourceUrl.TrimEnd('/'), (Split-Path -Path $BgInfoConfig -Leaf)) -Destination $BgInfoConfig
    }
    Write-Log "BGInfo configuration file found: $BgInfoConfig ($(Get-FileDetail $BgInfoConfig))"

    # 4. Ensure the wallpaper image referenced by the .bgi is present and up to date
    if ((Test-Path -LiteralPath $WallpaperPath -PathType Leaf) -and $checkOnline -and -not [string]::IsNullOrWhiteSpace($effectiveWallpaperUrl)) {
        Update-FileFromUrl -Url $effectiveWallpaperUrl -Destination $WallpaperPath
    }
    Install-Wallpaper -DestinationWallpaper $WallpaperPath -DownloadUrl $effectiveWallpaperUrl

    # 5. Remove the legacy HKLM Run value so BGInfo does not launch twice at logon
    Remove-LegacyAutostartRegistryValue -Path $legacyRegPath -Name $legacyRegName

    # 6. Create or refresh the all-users Startup shortcut
    Set-StartupShortcut -ShortcutPath $StartupShortcut -TargetPath $BgInfoExe -Arguments $bgInfoArguments

    # 7. Apply the wallpaper immediately for the current session
    $process = Start-Process -FilePath $BgInfoExe -ArgumentList $bgInfoArguments -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "BGInfo exited with code $($process.ExitCode)."
    }
    Write-Log 'BGInfo executed successfully; wallpaper applied' -Level Success

    # 8. Opt-in: register the monthly maintenance scheduled task
    if ($RegisterMonthlyTask) {
        Register-MonthlyMaintenanceTask -TaskName $maintenanceTaskName -ScriptPath $PSCommandPath -LogPath $maintenanceLogPath
    }

    # 9. Deployment summary: the final state of everything this script manages
    Write-Log '--- Deployment summary -------------------------------------------------------'
    Write-Log "Executable : $BgInfoExe (version $((Get-Item -LiteralPath $BgInfoExe).VersionInfo.ProductVersion); $(Get-FileDetail $BgInfoExe))"
    Write-Log "Config     : $BgInfoConfig ($(Get-FileDetail $BgInfoConfig))"
    if (Test-Path -LiteralPath $WallpaperPath -PathType Leaf) {
        Write-Log "Wallpaper  : $WallpaperPath ($(Get-FileDetail $WallpaperPath))"
    }
    else {
        Write-Log "Wallpaper  : $WallpaperPath (MISSING - desktop background may be blank)" -Level Warning
    }
    Write-Log "Shortcut   : $StartupShortcut"
    Write-Log "Launches   : `"$BgInfoExe`" $bgInfoArguments"
    Write-Log '------------------------------------------------------------------------------'

    Write-Log 'Script completed' -Level Success
}
catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level Error
    exit 1
}
