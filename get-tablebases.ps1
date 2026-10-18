<#
.SYNOPSIS
    Downloads and verifies the Gaviota or Syzygy chess endgame tablebases from the
    Lichess mirror (https://tablebase.lichess.ovh/tables/standard/).

.DESCRIPTION
    Interactive and resumable downloader. One run handles ONE set of tables:

        Gaviota            3-4-5 pieces, compressed (.gtb.cp4)
        Syzygy 3-4-5       WDL + DTZ, up to 5 pieces
        Syzygy 3-4-5-6     WDL + DTZ, up to 6 pieces
        Syzygy 3-4-5-6-7   WDL + DTZ, up to 7 pieces (about 17 TiB)

    and ONE action: download the set (verification offered at the end), or
    verify it only.

    Resulting layout below -Root:

        Gaviota\   *.gtb.cp4 + Gaviota.cp4.md5
        Syzygy\    *.rtbw + *.rtbz + exactly one checksum file
                   (3-4-5.md5, 3-4-5-6.md5 or 3-4-5-6-7.md5)

    File lists, sizes and checksums are read from the server at every run:
    the sizes displayed by the menu are the real remote ones.

    Robustness, in short (README.md has the details):
      * a file is complete when its local size equals the remote size;
        downloads go to <name>.part, are flushed to disk, then renamed;
      * after any failure the script restarts curl, which resumes from the
        last byte received (curl's own --retry would throw those bytes away);
      * free space and FAT32 limits are checked before downloading;
      * <script>.lock (next to the script) forbids concurrent runs;
        <script>.state remembers the job until it succeeds, so an interrupted
        run can be resumed, purged and restarted, or abandoned;
      * the layout of get-tablebases.ps1 v1 (3-4-5\, 6-WDL\, 6-DTZ\) is
        migrated silently into Syzygy\.

.PARAMETER Root
    Destination directory; Gaviota\ and Syzygy\ are created below it.
    Default: the directory of the script.

.PARAMETER Curl
    curl executable. Default: curl.exe, built into Windows since Windows 10
    version 1803. In Windows PowerShell 5.1, "curl" alone is an alias of
    Invoke-WebRequest, hence the explicit curl.exe.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\get-tablebases.ps1

.EXAMPLE
    pwsh -File .\get-tablebases.ps1 -Root D:\Tablebases

.NOTES
    Version 1.0.0
    Windows only (Windows PowerShell 5.1 or PowerShell 7 on Windows): the Win32
    disk calls and the open-handle lock have no equivalent elsewhere. Linux and
    macOS get a separate shell script.
    Exit codes: 0 success (or the user quit), 1 error or unfinished job,
    2 another instance is running, 3 the stale lock of an interrupted run was
    kept (the user declined to remove it).
#>
#Requires -Version 5.1
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Interactive console tool: colors and an in-place progress line are intended.')]
[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot,
    [string]$Curl = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

#region ------------------------------------------------------------------ Settings

$script:ScriptVersion = '1.0.0'
$script:StateFormat   = 1          # bump if the layout of the .state file changes
$script:BaseUrl       = 'https://tablebase.lichess.ovh/tables/standard'
$script:UserAgent     = 'get-tablebases.ps1/' + $script:ScriptVersion
$script:MaxStalled    = 6          # curl runs in a row without any progress before giving up on a file
$script:CheckpointSec = 5          # how often (seconds) a verification saves its progress

# The four sets of the menu. RemoteDirs: top-level directories of the server making up the set.
# MaxPieces: used to filter checksum files (a 3-4-5-6-7.md5 also covers 3-4-5-6 and 3-4-5).
$script:Sets = [ordered]@{
    'gaviota' = [pscustomobject]@{ Key = 'gaviota'; Label = 'Gaviota';          Kind = 'Gaviota'; SubDir = 'Gaviota'
                                   MaxPieces = 5; RemoteDirs = @('Gaviota'); Md5Name = 'Gaviota.cp4.md5' }
    '345'     = [pscustomobject]@{ Key = '345';     Label = 'Syzygy 3-4-5';     Kind = 'Syzygy';  SubDir = 'Syzygy'
                                   MaxPieces = 5; RemoteDirs = @('3-4-5-wdl', '3-4-5-dtz'); Md5Name = '3-4-5.md5' }
    '3456'    = [pscustomobject]@{ Key = '3456';    Label = 'Syzygy 3-4-5-6';   Kind = 'Syzygy';  SubDir = 'Syzygy'
                                   MaxPieces = 6; RemoteDirs = @('3-4-5-wdl', '3-4-5-dtz', '6-wdl', '6-dtz')
                                   Md5Name = '3-4-5-6.md5' }
    '34567'   = [pscustomobject]@{ Key = '34567';   Label = 'Syzygy 3-4-5-6-7'; Kind = 'Syzygy';  SubDir = 'Syzygy'
                                   MaxPieces = 7; RemoteDirs = @('3-4-5-wdl', '3-4-5-dtz', '6-wdl', '6-dtz', '7')
                                   Md5Name = '3-4-5-6-7.md5' }
}
$script:SyzygyKeys = @('345', '3456', '34567')

# File name patterns. Remote names are always checked against them, so a malformed server
# answer can never make the script write outside its directories (no "..", no separators).
$script:SyzygyNameRx  = '^K[QRBNP]*vK[QRBNP]*\.rtb[wz]$'
$script:GaviotaNameRx = '^[a-z]+\.gtb\.cp4$'
$script:Md5LineRx     = '^\s*([0-9A-Fa-f]{32})\s+\*?(\S+)\s*$'

# Runtime state, shared by the functions below.
$script:LockStream   = $null       # open handle on the lock file (held during the whole run)
$script:CurlProcess  = $null       # curl currently running, killed on exit if still alive
$script:CurlPath     = $null       # resolved curl executable, $null when curl is missing
$script:StatusActive = $false      # an in-place progress line is on screen
$script:PlainOutput  = $false      # output redirected: no in-place progress line
$script:StartedAt    = (Get-Date).ToString('s')
$script:RootGiven    = $PSBoundParameters.ContainsKey('Root')

#endregion

#region ------------------------------------------------------------------ Console helpers

function Format-Invariant {
    # String formatting independent of the user's culture (decimal point, digit grouping).
    param([string]$Format, [object[]]$Value)
    return [string]::Format([Globalization.CultureInfo]::InvariantCulture, $Format, $Value)
}

function Format-Size {
    # Binary size for humans: 1536 -> "1.50 KiB".
    param([double]$Bytes)
    $units = @('B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB')
    $i = 0
    while ($Bytes -ge 1024 -and $i -lt $units.Count - 1) { $Bytes = $Bytes / 1024; $i++ }
    if ($i -eq 0) { return (Format-Invariant -Format '{0:0} {1}' -Value @($Bytes, $units[$i])) }
    return (Format-Invariant -Format '{0:0.00} {1}' -Value @($Bytes, $units[$i]))
}

function Format-Duration {
    # Compact duration: "17d 04h", "5h 12m", "3m 20s", "42s"; "?" when unknown.
    param([double]$Seconds)
    if ([double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds) -or $Seconds -lt 0) { return '?' }
    $t = [TimeSpan]::FromSeconds([Math]::Round($Seconds))
    if ($t.TotalDays -ge 1) {
        return (Format-Invariant -Format '{0}d {1:00}h' -Value @([int][Math]::Floor($t.TotalDays), $t.Hours))
    }
    if ($t.TotalHours -ge 1) { return (Format-Invariant -Format '{0}h {1:00}m' -Value @($t.Hours, $t.Minutes)) }
    if ($t.TotalMinutes -ge 1) { return (Format-Invariant -Format '{0}m {1:00}s' -Value @($t.Minutes, $t.Seconds)) }
    return (Format-Invariant -Format '{0}s' -Value @($t.Seconds))
}

function Format-Stamp {
    # Dates read back from JSON are strings in Windows PowerShell 5.1 but DateTime objects in
    # PowerShell 7 (which would then be printed in the local culture): one display for both.
    param($Value)
    if ($Value -is [DateTime]) {
        return $Value.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
    }
    return ([string]$Value).Replace('T', ' ')
}

function Get-ConsoleWidth {
    # Console width, with a sane fallback when there is no real console.
    $width = 0
    try { $width = [Console]::WindowWidth } catch { $width = 0 }
    if ($width -lt 40) { $width = 80 }
    return $width
}

function Clear-StatusLine {
    # Erases the in-place progress line before a regular message is printed.
    if ($script:StatusActive) {
        $width = Get-ConsoleWidth
        Write-Host -NoNewline ("`r" + (' ' * ($width - 1)) + "`r")
        $script:StatusActive = $false
    }
}

function Write-Status {
    # One self-overwriting progress line (skipped when the output is redirected to a file).
    param([string]$Text)
    if ($script:PlainOutput) { return }
    $width = Get-ConsoleWidth
    if ($Text.Length -gt $width - 1) { $Text = $Text.Substring(0, $width - 1) }
    Write-Host -NoNewline ("`r" + $Text.PadRight($width - 1))
    $script:StatusActive = $true
}

function Write-Msg {
    # Regular message, colored by level.
    param(
        [string]$Text,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error', 'Note', 'Title')][string]$Level = 'Info'
    )
    Clear-StatusLine
    switch ($Level) {
        'Ok'    { Write-Host $Text -ForegroundColor Green }
        'Warn'  { Write-Host ('WARNING: ' + $Text) -ForegroundColor Yellow }
        'Error' { Write-Host ('ERROR: ' + $Text) -ForegroundColor Red }
        'Note'  { Write-Host $Text -ForegroundColor DarkGray }
        'Title' { Write-Host $Text -ForegroundColor Cyan }
        default { Write-Host $Text }
    }
}

function Read-Choice {
    # Asks until one of the allowed answers is typed (case-insensitive).
    # Returns it in upper case, $Default on an empty line, $null when the input is closed.
    param([string]$Prompt, [string[]]$Allowed, [string]$Default = '')
    while ($true) {
        Clear-StatusLine
        $answer = Read-Host -Prompt $Prompt
        if ($null -eq $answer) { return $null }
        $answer = $answer.Trim()
        if ($answer -eq '' -and $Default -ne '') { return $Default.ToUpperInvariant() }
        foreach ($item in $Allowed) {
            if ($answer -ieq $item) { return $item.ToUpperInvariant() }
        }
        Write-Msg -Level Warn -Text ('Please answer one of: ' + ($Allowed -join ', '))
    }
}

function Read-YesNo {
    # Yes/no question. An empty answer selects the default; a closed input means "no".
    param([string]$Prompt, [bool]$Default = $false)
    if ($Default) { $hint = '[Y/n]'; $fallback = 'Y' } else { $hint = '[y/N]'; $fallback = 'N' }
    $answer = Read-Choice -Prompt ($Prompt + ' ' + $hint) -Allowed @('Y', 'N', 'YES', 'NO') -Default $fallback
    return ($answer -eq 'Y' -or $answer -eq 'YES')
}

function Read-Confirmation {
    # Destructive or huge operations: the user must type a word, in capitals.
    param([string]$Prompt, [string]$Word)
    Clear-StatusLine
    $answer = Read-Host -Prompt ('{0} Type {1} to confirm (anything else cancels)' -f $Prompt, $Word)
    return ($null -ne $answer -and $answer.Trim() -ceq $Word)
}

#endregion

#region ------------------------------------------------------------------ Paths and volumes

function Resolve-RootPath {
    # Absolute destination path, resolved against the PowerShell location (may not exist yet).
    param([string]$Path)
    if (-not $Path) { $Path = (Get-Location).ProviderPath }
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}

function Get-ExistingAncestor {
    # Nearest existing directory of a path (the destination may not be created yet).
    param([string]$Path)
    $current = $Path
    while ($current -and -not (Test-Path -LiteralPath $current -PathType Container)) {
        $parent = Split-Path -Path $current -Parent
        if ($parent -eq $current) { break }
        $current = $parent
    }
    return $current
}

function Initialize-NativeDisk {
    # Win32 calls giving the free space and the file system of ANY directory: local drive,
    # mount point or UNC share (System.IO.DriveInfo only understands drive letters).
    if ('TablebaseTools.NativeDisk' -as [type]) { return }
    Add-Type -Namespace 'TablebaseTools' -Name 'NativeDisk' -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetDiskFreeSpaceEx(string lpDirectoryName, out ulong lpFreeBytesAvailable,
    out ulong lpTotalNumberOfBytes, out ulong lpTotalNumberOfFreeBytes);

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetVolumePathName(string lpszFileName, System.Text.StringBuilder lpszVolumePathName,
    uint cchBufferLength);

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
[return: MarshalAs(UnmanagedType.Bool)]
public static extern bool GetVolumeInformation(string lpRootPathName, System.Text.StringBuilder lpVolumeNameBuffer,
    uint nVolumeNameSize, out uint lpVolumeSerialNumber, out uint lpMaximumComponentLength,
    out uint lpFileSystemFlags, System.Text.StringBuilder lpFileSystemNameBuffer, uint nFileSystemNameSize);
'@
}

function Get-VolumeInfo {
    # Free space available to the current user (quotas included) and file system name of the
    # volume holding an existing directory. Free = -1 when it cannot be determined.
    param([string]$Path)
    try {
        Initialize-NativeDisk
        $dir = $Path.TrimEnd('\') + '\'      # a UNC path needs the trailing backslash
        $free = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
        if (-not [TablebaseTools.NativeDisk]::GetDiskFreeSpaceEx($dir, [ref]$free, [ref]$total, [ref]$totalFree)) {
            throw ('GetDiskFreeSpaceEx failed (Win32 error {0})' -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
        }
        $fileSystem = ''
        $volume = New-Object -TypeName System.Text.StringBuilder -ArgumentList 1024
        if ([TablebaseTools.NativeDisk]::GetVolumePathName($dir, $volume, 1024)) {
            $name = New-Object -TypeName System.Text.StringBuilder -ArgumentList 64
            $serial = [uint32]0; $maxLength = [uint32]0; $flags = [uint32]0
            if ([TablebaseTools.NativeDisk]::GetVolumeInformation($volume.ToString(), $null, 0, [ref]$serial,
                    [ref]$maxLength, [ref]$flags, $name, 64)) {
                $fileSystem = $name.ToString()
            }
        }
        return [pscustomobject]@{ Free = [int64]$free; FileSystem = $fileSystem }
    } catch {
        Write-Msg -Level Warn -Text ('Cannot read the free space of {0}: {1}' -f $Path, $_.Exception.Message)
        return [pscustomobject]@{ Free = [int64]-1; FileSystem = '' }
    }
}

function Get-FreeSpaceText {
    # "1.23 TiB (NTFS)" for the menu header, '' when unknown.
    param([string]$Path)
    $existing = Get-ExistingAncestor -Path $Path
    if (-not $existing) { return '' }
    $volume = Get-VolumeInfo -Path $existing
    if ($volume.Free -lt 0) { return '' }
    $text = Format-Size -Bytes $volume.Free
    if ($volume.FileSystem) { $text += ' (' + $volume.FileSystem + ')' }
    return $text
}

function Move-FileWithRetry {
    # Rename/move a file, retrying a few times: on Windows an antivirus or the search indexer may
    # hold a freshly written file for a moment, which makes a plain move fail.
    param([string]$Source, [string]$Destination)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            [IO.File]::Move($Source, $Destination)
            return
        } catch [System.IO.IOException] {
            if ($attempt -eq 5 -or -not (Test-Path -LiteralPath $Source)) { throw }
            Start-Sleep -Seconds $attempt
        }
    }
}

function Sync-FileToDisk {
    # Forces the data of a file out of the OS cache (FlushFileBuffers). A power cut can
    # otherwise leave a renamed file whose last blocks were never written.
    param([string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
}

#endregion

#region ------------------------------------------------------------------ Lock and job state

function Read-LockInfo {
    # Content of the lock file, read without disturbing the instance that may hold it.
    try {
        $stream = [IO.File]::Open($script:LockPath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                                  [IO.FileShare]::ReadWrite)
        try {
            $reader = New-Object -TypeName System.IO.StreamReader -ArgumentList $stream
            $text = $reader.ReadToEnd()
        } finally { $stream.Dispose() }
        if ($text.Trim()) { return ($text | ConvertFrom-Json) }
    } catch {
        Write-Verbose ('lock file unreadable: ' + $_.Exception.Message)
    }
    return $null
}

function Format-LockInfo {
    # One line describing the owner of a lock file.
    param($Info)
    if ($null -eq $Info) { return '(no details: the lock file is empty or unreadable)' }
    try { return ('PID {0} on {1}, started {2}, job: {3}' -f $Info.Pid, $Info.Host, (Format-Stamp -Value $Info.Started), $Info.Job) }
    catch { return '(no details: unexpected lock file content)' }
}

function Write-LockInfo {
    # Describes this run inside the lock file (shown to a second instance).
    param([string]$Job)
    if ($null -eq $script:LockStream) { return }
    $info = [ordered]@{ Pid = $PID; Host = [Environment]::MachineName; User = [Environment]::UserName
                        Started = $script:StartedAt; Job = $Job; Script = $PSCommandPath }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($info | ConvertTo-Json))
    $script:LockStream.SetLength(0)
    $script:LockStream.Write($bytes, 0, $bytes.Length)
    $script:LockStream.Flush($true)
}

function Lock-Instance {
    # The lock file stays OPEN for the whole run, so Windows itself tells a running instance
    # from a dead one (sharing violation on the open). A live lock cannot even be deleted.
    # A stale lock (no live holder) is removed only if the user says so.
    # Returns 0 (acquired), 2 (another instance is running), 3 (stale lock kept) or 1 (failure).
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if (Test-Path -LiteralPath $script:LockPath) {
            $alive = $false
            try {
                $probe = [IO.File]::Open($script:LockPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite,
                                         [IO.FileShare]::None)
                $probe.Dispose()
            } catch [System.IO.FileNotFoundException] {
                continue                                  # released and deleted meanwhile: try again
            } catch [System.IO.IOException] {
                $alive = $true                            # sharing violation: a live instance holds it
            }
            $owner = Format-LockInfo -Info (Read-LockInfo)
            if ($alive) {
                Write-Msg -Level Error -Text 'Another instance of this script is running:'
                Write-Msg -Text ('  ' + $owner)
                return 2
            }
            Write-Msg -Level Warn -Text 'A previous run was interrupted (reboot, power cut, killed process...):'
            Write-Msg -Text ('  ' + $owner)
            Write-Msg -Text '  No running process holds its lock any more.'
            # Explicit acknowledgement; "no", an empty answer or a closed input keep the lock.
            if (-not (Read-YesNo -Prompt 'Remove this stale lock and continue?' -Default $false)) {
                Write-Msg -Text ('Lock kept: ' + $script:LockPath)
                return 3
            }
            try {
                Remove-Item -LiteralPath $script:LockPath -Force
                Write-Msg -Level Note -Text 'Stale lock removed.'
            } catch {
                Write-Verbose ('stale lock removal: ' + $_.Exception.Message)   # taken meanwhile: examine it again
            }
            continue                                      # next attempt creates our own lock
        }
        try {
            $script:LockStream = [IO.File]::Open($script:LockPath, [IO.FileMode]::CreateNew,
                                                 [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
            Write-LockInfo -Job 'menu'
            return 0
        } catch [System.IO.IOException] {
            continue                                      # created by another instance: examine it
        }
    }
    Write-Msg -Level Error -Text ('Could not acquire the lock file ' + $script:LockPath)
    return 1
}

function Unlock-Instance {
    # Normal end, error or Ctrl+C (finally blocks run on Ctrl+C): the lock disappears,
    # the job state stays, so the next run offers to resume.
    if ($null -ne $script:LockStream) {
        $script:LockStream.Dispose()
        $script:LockStream = $null
        Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction SilentlyContinue
    }
}

function Initialize-JobState {
    # A new job description (not saved yet).
    param($Set, [string]$Action, [string]$RootPath)
    return [pscustomobject]@{
        Format        = $script:StateFormat
        ScriptVersion = $script:ScriptVersion
        Action        = $Action           # Download or Verify
        Set           = $Set.Key
        Root          = $RootPath
        Started       = (Get-Date).ToString('s')
        Verify        = $null             # verification checkpoint (files already validated)
    }
}

function Read-JobState {
    # The unfinished job, or $null. An unreadable state file is reported and ignored.
    if (-not (Test-Path -LiteralPath $script:StatePath)) { return $null }
    try {
        $state = [IO.File]::ReadAllText($script:StatePath) | ConvertFrom-Json
        if ($state.Format -ne $script:StateFormat) { throw 'unknown format' }
        if (-not $script:Sets.Contains([string]$state.Set)) { throw 'unknown set' }
        if (@('Download', 'Verify') -notcontains [string]$state.Action) { throw 'unknown action' }
        if (-not [string]$state.Root) { throw 'no destination' }
        $null = $state.Started, $state.Verify       # StrictMode: both properties must exist
        return $state
    } catch {
        Write-Msg -Level Warn -Text ('Ignoring the unreadable job state file {0} ({1}).' -f $script:StatePath,
                                     $_.Exception.Message)
        return $null
    }
}

function Save-JobState {
    # Atomic write: a crash in the middle leaves either the old or the new state, never a mix.
    param($State)
    $temp = $script:StatePath + '.tmp'
    [IO.File]::WriteAllText($temp, ($State | ConvertTo-Json -Depth 6), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
    Sync-FileToDisk -Path $temp
    if (Test-Path -LiteralPath $script:StatePath) {
        [IO.File]::Replace($temp, $script:StatePath, [NullString]::Value)
    } else {
        [IO.File]::Move($temp, $script:StatePath)
    }
}

function Clear-JobState {
    # The job succeeded (or was abandoned): nothing to resume any more.
    foreach ($path in @($script:StatePath, ($script:StatePath + '.tmp'))) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

#endregion

#region ------------------------------------------------------------------ curl

function Resolve-Curl {
    # Full path of the curl executable, or $null. Only real executables are accepted, so the
    # Windows PowerShell 5.1 alias "curl" (Invoke-WebRequest) can never be picked.
    param([string]$Name)
    if (-not $Name) { $Name = 'curl.exe' }
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Path
}

function ConvertTo-CommandLineArgument {
    # Quotes one argument following the Windows (MSVCRT) rules, so curl receives it unchanged.
    param([string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', { param($m) ($m.Groups[1].Value * 2) + '\"' })
    $escaped = [regex]::Replace($escaped, '(\\+)$', { param($m) $m.Groups[1].Value * 2 })
    return '"' + $escaped + '"'
}

function Open-CurlProcess {
    # Starts curl without waiting. It shares our console, so Ctrl+C stops it as well.
    param([string[]]$ArgumentList)
    $quoted = foreach ($argument in $ArgumentList) { ConvertTo-CommandLineArgument -Value $argument }
    $info = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:CurlPath
    $info.Arguments = ($quoted -join ' ')
    $info.UseShellExecute = $false
    $script:CurlProcess = [System.Diagnostics.Process]::Start($info)
    return $script:CurlProcess
}

function Close-CurlProcess {
    # Never leave a curl behind (exception, Ctrl+C): it would keep its .part file busy.
    if ($null -ne $script:CurlProcess) {
        try {
            if (-not $script:CurlProcess.HasExited) { $script:CurlProcess.Kill() }
        } catch {
            Write-Verbose ('curl cleanup: ' + $_.Exception.Message)
        }
        $script:CurlProcess.Dispose()
        $script:CurlProcess = $null
    }
}

function Get-CurlError {
    # Last meaningful line written by curl into its --stderr file.
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $lines = @([IO.File]::ReadAllLines($Path) | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { return '' }
    return $lines[-1].Trim()
}

function Invoke-Curl {
    # Runs curl to completion; returns its exit code and error message.
    param([string[]]$ArgumentList)
    $errorFile = [IO.Path]::GetTempFileName()
    try {
        $process = Open-CurlProcess -ArgumentList (@('--stderr', $errorFile) + $ArgumentList)
        $process.WaitForExit()
        $code = $process.ExitCode
        Close-CurlProcess
        return [pscustomobject]@{ Code = $code; Error = (Get-CurlError -Path $errorFile) }
    } finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-CurlVersion {
    # "8.13.0" for the banner (useful in bug reports).
    $info = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $info.FileName = $script:CurlPath
    $info.Arguments = '--version'
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $out = $process.StandardOutput.ReadToEnd()
    $process.WaitForExit()
    $process.Dispose()
    if ($out -match '^curl\s+(\S+)') { return $Matches[1] }
    return 'unknown version'
}

#endregion

#region ------------------------------------------------------------------ Remote catalog

function Get-RemoteText {
    # Downloads a small text file (file lists, checksums) and returns its content.
    param([string]$Url)
    $temp = [IO.Path]::GetTempFileName()
    try {
        $result = Invoke-Curl -ArgumentList @('-sS', '-f', '-L', '-A', $script:UserAgent, '--connect-timeout', '20',
                                              '--max-time', '300', '--retry', '3', '--retry-delay', '3',
                                              '-o', $temp, $Url)
        if ($result.Code -ne 0) { throw ('{0}: curl exit {1} ({2})' -f $Url, $result.Code, $result.Error) }
        return [IO.File]::ReadAllText($temp)
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-RemoteSize {
    # Size of a remote file from a HEAD request (fallback when a directory listing lacks it).
    param([string]$Url)
    $temp = [IO.Path]::GetTempFileName()
    try {
        $result = Invoke-Curl -ArgumentList @('-sS', '-f', '-L', '-I', '-A', $script:UserAgent, '--connect-timeout', '20',
                                              '--max-time', '60', '-o', $temp, $Url)
        if ($result.Code -ne 0) { throw ('{0}: curl exit {1} ({2})' -f $Url, $result.Code, $result.Error) }
        $size = $null
        foreach ($line in [IO.File]::ReadAllLines($temp)) {
            if ($line -match '^content-length:\s*(\d+)') { $size = [int64]$Matches[1] }   # last one wins
        }
        if ($null -eq $size) { throw ('{0}: no Content-Length header' -f $Url) }
        return $size
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-PieceCount {
    # "KRPvKQ.rtbw" or "KRPvKQ.rtbw.part" -> 5 (kings included).
    param([string]$Name)
    return ($Name.Split('.')[0] -creplace 'v', '').Length
}

function Read-Md5Text {
    # "md5  name" or "md5 *name" lines -> objects (Name, Md5), in file order. Lines whose name
    # does not match $NamePattern are ignored.
    param([string]$Text, [string]$NamePattern)
    $list = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -notmatch $script:Md5LineRx) { continue }
        $md5 = $Matches[1].ToLowerInvariant()
        $name = $Matches[2]
        if ($name -notmatch $NamePattern) { continue }
        $list.Add([pscustomobject]@{ Name = $name; Md5 = $md5 })
    }
    return $list.ToArray()
}

function Get-SyzygyCatalog {
    # Joins download.txt (URLs), bytes.tsv (sizes) and md5 (checksums) by file name.
    $urls  = Get-RemoteText -Url ($script:BaseUrl + '/download.txt')
    $sizes = Get-RemoteText -Url ($script:BaseUrl + '/bytes.tsv')
    $sums  = Get-RemoteText -Url ($script:BaseUrl + '/md5')
    $sizeOf = @{}
    foreach ($line in ($sizes -split "`r?`n")) {
        if ($line -match '^\s*(\d+)\s+(\S+)\s*$') { $sizeOf[$Matches[2]] = [int64]$Matches[1] }
    }
    $md5Of = @{}
    foreach ($item in @(Read-Md5Text -Text $sums -NamePattern $script:SyzygyNameRx)) { $md5Of[$item.Name] = $item.Md5 }
    $list = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($line in ($urls -split "`r?`n")) {
        $url = $line.Trim()
        # ".../tables/standard/<top>/[<sub>/]<name>": the 7-piece files live in sub-directories.
        if ($url -notmatch '/tables/standard/([^/]+)/(?:.*/)?([^/]+)$') { continue }
        $top = $Matches[1]
        $name = $Matches[2]
        if ($name -notmatch $script:SyzygyNameRx) { continue }
        if (-not $sizeOf.ContainsKey($name) -or -not $md5Of.ContainsKey($name)) {
            throw ('inconsistent Syzygy catalog: no size or checksum for ' + $name)
        }
        $list.Add([pscustomobject]@{ Name = $name; Url = $url; Size = $sizeOf[$name]; Md5 = $md5Of[$name]
                                     Top = $top; Pieces = (Get-PieceCount -Name $name) })
    }
    if ($list.Count -lt 290) { throw ('the Syzygy catalog looks truncated ({0} files)' -f $list.Count) }
    return $list.ToArray()
}

function Get-GaviotaCatalog {
    # Names and checksums from Gaviota.cp4.md5, sizes from the directory listing.
    $md5Text = Get-RemoteText -Url ($script:BaseUrl + '/Gaviota/Gaviota.cp4.md5')
    $listing = Get-RemoteText -Url ($script:BaseUrl + '/Gaviota/')
    $sizeOf = @{}
    foreach ($match in [regex]::Matches($listing, '<a href="([a-z]+\.gtb\.cp4)">[^<]*</a>\s+\S+\s+\S+\s+(\d+)')) {
        $sizeOf[$match.Groups[1].Value] = [int64]$match.Groups[2].Value
    }
    $list = New-Object -TypeName System.Collections.Generic.List[object]
    foreach ($item in @(Read-Md5Text -Text $md5Text -NamePattern $script:GaviotaNameRx)) {
        $url = $script:BaseUrl + '/Gaviota/' + $item.Name
        if ($sizeOf.ContainsKey($item.Name)) { $size = $sizeOf[$item.Name] } else { $size = Get-RemoteSize -Url $url }
        $list.Add([pscustomobject]@{ Name = $item.Name; Url = $url; Size = $size; Md5 = $item.Md5
                                     Top = 'Gaviota'; Pieces = 0 })
    }
    if ($list.Count -lt 100) { throw ('the Gaviota catalog looks truncated ({0} files)' -f $list.Count) }
    return [pscustomobject]@{ Entries = $list.ToArray(); Md5Text = $md5Text }
}

function Get-Catalog {
    # Everything the server knows, or $null: offline mode (verification with local checksums).
    if ($null -eq $script:CurlPath) { return $null }
    Write-Msg -Level Note -Text 'Reading the file lists, sizes and checksums from Lichess...'
    try {
        $syzygy = Get-SyzygyCatalog
        $gaviota = Get-GaviotaCatalog
        return [pscustomobject]@{ Syzygy = $syzygy; Gaviota = $gaviota.Entries; GaviotaMd5Text = $gaviota.Md5Text }
    } catch {
        Write-Msg -Level Warn -Text ('Lichess unreachable or unexpected answer: ' + $_.Exception.Message)
        Write-Msg -Level Warn -Text 'Offline mode: downloads are disabled, "Verify only" uses the local checksum files.'
        return $null
    }
}

function Get-SetFileList {
    # Remote entries (Name, Url, Size, Md5, Top, Pieces) making up a set, in server order.
    param($Set, $Catalog)
    if ($Set.Kind -eq 'Gaviota') { return @($Catalog.Gaviota) }
    return @($Catalog.Syzygy | Where-Object { $Set.RemoteDirs -contains $_.Top })
}

#endregion

#region ------------------------------------------------------------------ Local files

function Get-LocalFileTable {
    # name -> length for the files of a directory (one directory read, fast with thousands of files).
    param([string]$Dir)
    $table = @{}
    if (Test-Path -LiteralPath $Dir -PathType Container) {
        foreach ($file in [IO.DirectoryInfo]::new($Dir).GetFiles()) { $table[$file.Name] = $file.Length }
    }
    return $table
}

function Get-EntryRemaining {
    # Bytes still to download for one remote entry. A file is complete when its size is right;
    # a shorter <name>.part (or a shorter <name>, written by v1 of this script) is resumed.
    param($Entry, [hashtable]$Local)
    $final = [int64]-1
    $part = [int64]-1
    if ($Local.ContainsKey($Entry.Name)) { $final = [int64]$Local[$Entry.Name] }
    if ($Local.ContainsKey($Entry.Name + '.part')) { $part = [int64]$Local[$Entry.Name + '.part'] }
    if ($final -eq $Entry.Size) { return [int64]0 }
    $have = [Math]::Max($final, $part)
    if ($have -lt 0 -or $have -gt $Entry.Size) { return [int64]$Entry.Size }
    return [int64]($Entry.Size - $have)
}

function Measure-SetStatus {
    # Count, total size, remaining bytes and incomplete tables of a set, for the menu.
    param($Set, $Catalog, [hashtable]$Local)
    $total = [int64]0
    $remaining = [int64]0
    $count = 0
    $pending = 0                     # tables not complete under their final name
    foreach ($entry in @(Get-SetFileList -Set $Set -Catalog $Catalog)) {
        $count++
        $total += $entry.Size
        $remaining += Get-EntryRemaining -Entry $entry -Local $Local
        if (-not $Local.ContainsKey($entry.Name) -or $Local[$entry.Name] -ne $entry.Size) { $pending++ }
    }
    return [pscustomobject]@{ Count = $count; Total = $total; Remaining = $remaining; Pending = $pending }
}

function Move-LegacyLayout {
    # Silent migration of the v1 layout (3-4-5\, 6-WDL\, 6-DTZ\ + syzygy-lichess.md5) into Syzygy\.
    # Nothing is ever overwritten: a table already present in Syzygy\ (complete or partial) keeps
    # its legacy twin where it is, with a warning. Emptied legacy directories are removed; their
    # .md5 files are superseded by the per-set checksum file written after each download.
    param([string]$RootPath)
    $legacy = @(@('3-4-5', '6-WDL', '6-DTZ') | ForEach-Object { Join-Path -Path $RootPath -ChildPath $_ } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    $oldSums = Join-Path -Path $RootPath -ChildPath 'syzygy-lichess.md5'
    if ($legacy.Count -eq 0 -and -not (Test-Path -LiteralPath $oldSums)) { return }
    $syzygy = Join-Path -Path $RootPath -ChildPath 'Syzygy'
    if (-not (Test-Path -LiteralPath $syzygy)) { $null = New-Item -ItemType Directory -Path $syzygy -Force }
    $moved = 0
    $kept = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($dir in $legacy) {
        foreach ($file in [IO.DirectoryInfo]::new($dir).GetFiles()) {
            if ($file.Name -match $script:SyzygyNameRx) {
                $target = Join-Path -Path $syzygy -ChildPath $file.Name
                if ((Test-Path -LiteralPath $target) -or (Test-Path -LiteralPath ($target + '.part'))) {
                    $kept.Add($file.FullName)
                    continue
                }
                Move-FileWithRetry -Source $file.FullName -Destination $target
                $moved++
            } elseif ($file.Extension -ieq '.md5') {
                Remove-Item -LiteralPath $file.FullName -Force
            }
        }
        if (@(Get-ChildItem -LiteralPath $dir -Force).Count -eq 0) { Remove-Item -LiteralPath $dir -Force }
    }
    if (Test-Path -LiteralPath $oldSums) { Remove-Item -LiteralPath $oldSums -Force }
    if ($moved -gt 0) { Write-Msg -Level Note -Text ('Legacy layout: {0} table file(s) moved into {1}' -f $moved, $syzygy) }
    if ($kept.Count -gt 0) {
        Write-Msg -Level Warn -Text ('Legacy layout: {0} file(s) left in place, Syzygy\ already has a file with the same name:' -f $kept.Count)
        foreach ($path in ($kept | Select-Object -First 5)) { Write-Msg -Text ('  ' + $path) }
    }
}

function Get-SetLocalFile {
    # Local files belonging to a set: its tables, their .part files and its checksum file.
    param($Set, [string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
    $files = [IO.DirectoryInfo]::new($Dir).GetFiles()
    if ($Set.Kind -eq 'Gaviota') {
        return @($files | Where-Object { $_.Name -match '^[a-z]+\.gtb\.cp4(\.part)?$' -or $_.Name -ieq $Set.Md5Name })
    }
    return @($files | Where-Object {
        ($_.Name -match '^K[QRBNP]*vK[QRBNP]*\.rtb[wz](\.part)?$' -and (Get-PieceCount -Name $_.Name) -le $Set.MaxPieces) -or
        $_.Name -ieq $Set.Md5Name
    })
}

function Clear-SetFile {
    # "Purge": deletes the files of a set after a typed confirmation. Returns $false if cancelled.
    param($Set, [string]$RootPath)
    $dir = Join-Path -Path $RootPath -ChildPath $Set.SubDir
    $victims = @(Get-SetLocalFile -Set $Set -Dir $dir)
    if ($victims.Count -eq 0) {
        Write-Msg -Text 'Nothing to purge.'
        return $true
    }
    $bytes = ($victims | Measure-Object -Property Length -Sum).Sum
    Write-Msg -Level Warn -Text ('Purge deletes {0} file(s) of {1}, {2}, in {3}' -f $victims.Count, $Set.Label,
                                 (Format-Size -Bytes $bytes), $dir)
    if (-not (Read-Confirmation -Prompt 'This cannot be undone.' -Word 'PURGE')) {
        Write-Msg -Text 'Purge cancelled, the job is kept.'
        return $false
    }
    foreach ($file in $victims) { Remove-Item -LiteralPath $file.FullName -Force }
    Write-Msg -Level Ok -Text ('{0} file(s) deleted.' -f $victims.Count)
    return $true
}

function Clear-PartialFile {
    # After "Abandon": reports the .part files left behind and offers to delete them.
    param([string]$RootPath)
    $parts = @(foreach ($sub in @('Syzygy', 'Gaviota')) {
        $dir = Join-Path -Path $RootPath -ChildPath $sub
        if (Test-Path -LiteralPath $dir -PathType Container) { [IO.DirectoryInfo]::new($dir).GetFiles('*.part') }
    })
    if ($parts.Count -eq 0) { return }
    $bytes = ($parts | Measure-Object -Property Length -Sum).Sum
    Write-Msg -Text ('{0} partial download(s), {1}, remain. They are reused if the same tables are downloaded again.' -f
                     $parts.Count, (Format-Size -Bytes $bytes))
    if (Read-YesNo -Prompt 'Delete them?' -Default $false) {
        foreach ($file in $parts) { Remove-Item -LiteralPath $file.FullName -Force }
        Write-Msg -Level Ok -Text 'Partial downloads deleted.'
    }
}

#endregion

#region ------------------------------------------------------------------ Checksums

function Get-FileMd5 {
    # MD5 of a file, read by 4 MiB blocks; refreshes the progress line twice a second.
    param([string]$Path, [hashtable]$Context)
    $md5 = [Security.Cryptography.MD5]::Create()
    $buffer = [byte[]]::new(4MB)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $last = [DateTime]::MinValue
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$md5.TransformBlock($buffer, 0, $read, $null, 0)
            if ($null -ne $Context) {
                $Context.Done += $read
                if (([DateTime]::UtcNow - $last).TotalMilliseconds -ge 500) {
                    Write-VerifyStatus -Context $Context
                    $last = [DateTime]::UtcNow
                }
            }
        }
        [void]$md5.TransformFinalBlock($buffer, 0, 0)
        return ([BitConverter]::ToString($md5.Hash) -replace '-', '').ToLowerInvariant()
    } finally {
        $stream.Dispose()
        $md5.Dispose()
    }
}

function Write-VerifyStatus {
    # Progress line of a verification.
    param([hashtable]$Context)
    $elapsed = ([DateTime]::UtcNow - $Context.Started).TotalSeconds
    $speed = 0.0
    if ($elapsed -gt 0) { $speed = $Context.Done / $elapsed }
    $eta = '?'
    if ($speed -gt 0) { $eta = Format-Duration -Seconds (($Context.Total - $Context.Done) / $speed) }
    $percent = 100.0
    if ($Context.Total -gt 0) { $percent = 100.0 * $Context.Done / $Context.Total }
    Write-Status -Text (Format-Invariant -Format 'Verifying [{0}/{1}] {2} | {3} / {4} ({5:0.0}%) | {6}/s | ETA {7}' -Value @(
        $Context.Index, $Context.Count, $Context.Name, (Format-Size -Bytes $Context.Done),
        (Format-Size -Bytes $Context.Total), $percent, (Format-Size -Bytes $speed), $eta))
}

function Get-ChecksumList {
    # Expected checksums of a set. A local checksum file covering the set comes first (works
    # offline, like chek-Syzygy.ps1 did); when Lichess is reachable it is cross-checked against the
    # server and replaced by the server list if they differ (a wrong local file must never get
    # good tables deleted). Returns (Entries, Source).
    param($Set, [string]$Dir, $Catalog)
    if ($Set.Kind -eq 'Gaviota') {
        $candidates = @($Set.Md5Name)
        $pattern = $script:GaviotaNameRx
    } else {
        # Largest set first: 3-4-5-6-7.md5 covers every smaller set once filtered by pieces.
        $candidates = @($script:SyzygyKeys | Where-Object { $script:Sets[$_].MaxPieces -ge $Set.MaxPieces } |
                        ForEach-Object { $script:Sets[$_].Md5Name })
        [array]::Reverse($candidates)
        $pattern = $script:SyzygyNameRx
    }
    $remote = $null
    if ($null -ne $Catalog) {
        $remote = @(Get-SetFileList -Set $Set -Catalog $Catalog | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Md5 = $_.Md5 } })
    }
    foreach ($candidate in $candidates) {
        $path = Join-Path -Path $Dir -ChildPath $candidate
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $list = @(Read-Md5Text -Text ([IO.File]::ReadAllText($path)) -NamePattern $pattern |
                  Where-Object { $Set.Kind -eq 'Gaviota' -or (Get-PieceCount -Name $_.Name) -le $Set.MaxPieces })
        if ($list.Count -eq 0) { continue }
        if ($null -ne $remote) {
            $expected = (@($remote | ForEach-Object { $_.Name + '=' + $_.Md5 }) | Sort-Object) -join '|'
            $found = (@($list | ForEach-Object { $_.Name + '=' + $_.Md5 }) | Sort-Object) -join '|'
            if ($expected -ne $found) {
                Write-Msg -Level Warn -Text ('{0} does not match the server checksums of {1}: using the server ones.' -f
                                             $candidate, $Set.Label)
                break
            }
        }
        return [pscustomobject]@{ Entries = $list; Source = $path }
    }
    if ($null -eq $remote) { throw ('no local checksum file covers {0} and Lichess is unreachable' -f $Set.Label) }
    return [pscustomobject]@{ Entries = $remote; Source = 'the Lichess server' }
}

function Save-ChecksumFile {
    # Writes the checksum file describing the directory and returns its path.
    # Syzygy: the largest set whose files are ALL complete (at least the chosen one) gets its .md5,
    # the other per-set .md5 files are removed: exactly one checksum file remains.
    param($Set, [string]$RootPath, $Catalog)
    $dir = Join-Path -Path $RootPath -ChildPath $Set.SubDir
    if ($Set.Kind -eq 'Gaviota') {
        $path = Join-Path -Path $dir -ChildPath $Set.Md5Name
        [IO.File]::WriteAllText($path, $Catalog.GaviotaMd5Text, [Text.Encoding]::ASCII)   # the server file, as is
        return $path
    }
    $local = Get-LocalFileTable -Dir $dir
    $best = $Set
    foreach ($key in $script:SyzygyKeys) {
        $candidate = $script:Sets[$key]
        if ($candidate.MaxPieces -le $best.MaxPieces) { continue }
        $incomplete = @(Get-SetFileList -Set $candidate -Catalog $Catalog |
                        Where-Object { -not $local.ContainsKey($_.Name) -or $local[$_.Name] -ne $_.Size })
        if ($incomplete.Count -eq 0) { $best = $candidate }
    }
    # Same format and order as the server's md5 file (LF line ends, two spaces).
    $lines = foreach ($entry in @(Get-SetFileList -Set $best -Catalog $Catalog)) { $entry.Md5 + '  ' + $entry.Name }
    $path = Join-Path -Path $dir -ChildPath $best.Md5Name
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), [Text.Encoding]::ASCII)
    foreach ($key in $script:SyzygyKeys) {
        $other = Join-Path -Path $dir -ChildPath $script:Sets[$key].Md5Name
        if ($script:Sets[$key].Md5Name -ne $best.Md5Name -and (Test-Path -LiteralPath $other)) {
            Remove-Item -LiteralPath $other -Force
        }
    }
    $extra = @($local.Keys | Where-Object { $_ -match $script:SyzygyNameRx -and (Get-PieceCount -Name $_) -gt $best.MaxPieces }).Count
    if ($extra -gt 0) {
        Write-Msg -Level Note -Text ('{0} table file(s) of a larger, incomplete set are not covered by {1}.' -f $extra, $best.Md5Name)
    }
    return $path
}

function Invoke-Verification {
    # Hashes the files of a set and compares them with the expected sums. Progress is saved in the
    # job state every few seconds (and on Ctrl+C): an interrupted verification resumes where it
    # stopped; files validated before are only re-checked for presence and size.
    param([object[]]$Entries, [string]$Dir, $State, [string]$Source)
    $ok = @{}
    if ($null -ne $State.Verify) {
        $saved = $State.Verify.Ok
        if ($saved -is [hashtable]) { foreach ($key in $saved.Keys) { $ok[$key] = [int64]$saved[$key] } }
        elseif ($null -ne $saved) { foreach ($property in $saved.PSObject.Properties) { $ok[$property.Name] = [int64]$property.Value } }
    }
    $local = Get-LocalFileTable -Dir $Dir
    $problems = New-Object -TypeName System.Collections.Generic.List[object]
    $todo = New-Object -TypeName System.Collections.Generic.List[object]
    $skipped = 0
    foreach ($entry in $Entries) {
        if ($ok.ContainsKey($entry.Name)) {
            if ($local.ContainsKey($entry.Name) -and $local[$entry.Name] -eq $ok[$entry.Name]) { $skipped++; continue }
            $ok.Remove($entry.Name)                       # gone or changed since validated: check again
        }
        if (-not $local.ContainsKey($entry.Name)) {
            $problems.Add([pscustomobject]@{ Kind = 'MISSING'; Name = $entry.Name; Detail = '' })
            continue
        }
        $todo.Add($entry)
    }
    if ($skipped -gt 0) {
        Write-Msg -Level Note -Text ('{0} file(s) already verified before the interruption (still present, same size).' -f $skipped)
    }
    $total = [int64]0
    foreach ($entry in $todo) { $total += $local[$entry.Name] }
    $context = @{ Done = [int64]0; Started = [DateTime]::UtcNow; Index = 0; Count = $todo.Count; Total = $total; Name = '' }
    $State.Verify = [pscustomobject]@{ Source = $Source; Ok = $ok }
    $lastSave = [DateTime]::UtcNow
    try {
        foreach ($entry in $todo) {
            $context.Index++
            $context.Name = $entry.Name
            try {
                $hash = Get-FileMd5 -Path (Join-Path -Path $Dir -ChildPath $entry.Name) -Context $context
            } catch {
                $problems.Add([pscustomobject]@{ Kind = 'UNREADABLE'; Name = $entry.Name; Detail = $_.Exception.Message })
                continue
            }
            if ($hash -eq $entry.Md5) { $ok[$entry.Name] = $local[$entry.Name] }
            else { $problems.Add([pscustomobject]@{ Kind = 'CORRUPT'; Name = $entry.Name; Detail = '' }) }
            if (([DateTime]::UtcNow - $lastSave).TotalSeconds -ge $script:CheckpointSec) {
                Save-JobState -State $State
                $lastSave = [DateTime]::UtcNow
            }
        }
    } finally {
        Save-JobState -State $State                       # also runs on Ctrl+C
    }
    Clear-StatusLine
    return [pscustomobject]@{ Checked = @($Entries).Count; Problems = $problems.ToArray() }
}

#endregion

#region ------------------------------------------------------------------ Jobs

function Write-DownloadStatus {
    # Progress line of a download: file, whole job, speed over the last 30 s, ETA.
    param([hashtable]$Progress, $Entry)
    $done = $Progress.DoneBefore + ($Progress.FileDone - $Progress.FileStart)
    $now = [DateTime]::UtcNow
    $Progress.Samples.Enqueue(@($now, $done))
    while ($Progress.Samples.Count -gt 2 -and ($now - $Progress.Samples.Peek()[0]).TotalSeconds -gt 30) {
        [void]$Progress.Samples.Dequeue()
    }
    $first = $Progress.Samples.Peek()
    $span = ($now - $first[0]).TotalSeconds
    $speed = 0.0
    if ($span -gt 0) { $speed = ($done - $first[1]) / $span }
    $eta = '?'
    if ($speed -gt 0) { $eta = Format-Duration -Seconds (($Progress.Total - $done) / $speed) }
    $filePercent = 100.0
    if ($Entry.Size -gt 0) { $filePercent = 100.0 * $Progress.FileDone / $Entry.Size }
    $jobPercent = 100.0
    if ($Progress.Total -gt 0) { $jobPercent = 100.0 * $done / $Progress.Total }
    Write-Status -Text (Format-Invariant -Format '[{0}/{1}] {2} {3:0}% | {4} / {5} ({6:0.0}%) | {7}/s | ETA {8}' -Value @(
        $Progress.Index, $Progress.Count, $Entry.Name, $filePercent, (Format-Size -Bytes $done),
        (Format-Size -Bytes $Progress.Total), $jobPercent, (Format-Size -Bytes $speed), $eta))
}

function Get-PartLength {
    # Current size of a file, 0 when it does not exist.
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [int64](Get-Item -LiteralPath $Path).Length }
    return [int64]0
}

function Invoke-FileDownload {
    # Downloads one file into <name>.part, restarting curl (which resumes with -C -) until the file
    # is complete or makes no more progress; flushes it to disk, renames it, and MD5-checks it when
    # asked (files resumed after an interrupted run, repairs). Returns $null or an error message.
    param($Entry, [string]$Dir, [hashtable]$Progress, [bool]$CheckMd5)
    $final = Join-Path -Path $Dir -ChildPath $Entry.Name
    $part = $final + '.part'
    for ($pass = 1; $pass -le 2; $pass++) {
        # 1. Normalise what is on disk.
        if (Test-Path -LiteralPath $final) {
            $length = Get-PartLength -Path $final
            if ($length -eq $Entry.Size) {
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                return $null                              # completed meanwhile
            }
            $partLength = -1
            if (Test-Path -LiteralPath $part) { $partLength = Get-PartLength -Path $part }
            if ($length -lt $Entry.Size -and $length -gt $partLength) {
                # Partial file under its final name (v1 of this script): resume it as a .part file.
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                Move-FileWithRetry -Source $final -Destination $part
            } else {
                Remove-Item -LiteralPath $final -Force    # oversized (corrupt) or behind the .part file
            }
        }
        $current = Get-PartLength -Path $part
        if ($current -gt $Entry.Size) {
            Write-Msg -Level Warn -Text ('{0}: partial file larger than the remote one, starting over' -f $Entry.Name)
            Remove-Item -LiteralPath $part -Force
            $current = 0
        }
        $Progress.FileStart = $current
        $Progress.FileDone = $current
        # 2. Download. curl's own --retry is NOT used: on a retry it truncates the file back to where
        #    that curl started, throwing away everything received meanwhile. A new curl with -C -
        #    resumes from the last byte written instead.
        $stalled = 0
        $lastLength = $current
        while ($current -lt $Entry.Size) {
            $errorFile = [IO.Path]::GetTempFileName()
            $curlArgs = @('--stderr', $errorFile, '-sS', '-f', '-L', '-A', $script:UserAgent,
                          '--connect-timeout', '30', '--speed-limit', '1024', '--speed-time', '120',
                          '-C', '-', '-o', $part, $Entry.Url)
            $process = Open-CurlProcess -ArgumentList $curlArgs
            while (-not $process.WaitForExit(1000)) {
                $Progress.FileDone = Get-PartLength -Path $part
                Write-DownloadStatus -Progress $Progress -Entry $Entry
            }
            $code = $process.ExitCode
            Close-CurlProcess
            $message = Get-CurlError -Path $errorFile
            Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
            $current = Get-PartLength -Path $part
            $Progress.FileDone = $current
            Write-DownloadStatus -Progress $Progress -Entry $Entry
            if ($code -eq 0 -and $current -eq $Entry.Size) { break }
            if ($code -eq 0) { $message = 'size mismatch: {0} bytes instead of {1}' -f $current, $Entry.Size }
            if ($current -gt $Entry.Size -or $code -eq 33) {
                # Oversized result, or the server refused the byte range: this file starts over.
                Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
                $current = 0
                $Progress.FileStart = 0
                $Progress.FileDone = 0
                $Progress.Samples.Clear()                 # the speed window would otherwise go negative
            }
            if ($code -eq 22 -and $message -match '\b404\b') { return ('{0}: not found on the server (404)' -f $Entry.Name) }
            if ($current -gt $lastLength) { $stalled = 0 } else { $stalled++ }
            $lastLength = $current
            if ($stalled -ge $script:MaxStalled) { return ('{0}: curl exit {1}, {2}' -f $Entry.Name, $code, $message) }
            $delay = [int][Math]::Min(60, 5 * [Math]::Pow(2, $stalled))
            Write-Msg -Level Warn -Text ('{0}: curl exit {1} ({2}), new attempt in {3}s' -f $Entry.Name, $code, $message, $delay)
            Start-Sleep -Seconds $delay
        }
        # 3. Data on disk first, then the atomic rename that makes the table visible to engines.
        Sync-FileToDisk -Path $part
        Move-FileWithRetry -Source $part -Destination $final
        $Progress.DoneBefore += ($Entry.Size - $Progress.FileStart)
        $Progress.FileStart = 0
        $Progress.FileDone = 0
        if (-not $CheckMd5) { return $null }
        # 4. MD5 check (resumed after an interruption, or repair).
        Write-Status -Text ('Checking the MD5 of {0}...' -f $Entry.Name)
        if ((Get-FileMd5 -Path $final -Context $null) -eq $Entry.Md5) { return $null }
        Write-Msg -Level Warn -Text ('{0}: MD5 mismatch, downloading it again from scratch' -f $Entry.Name)
        $Progress.Total += $Entry.Size                    # the job grows by one full download
        Remove-Item -LiteralPath $final -Force
    }
    return ('{0}: MD5 mismatch even after a full download' -f $Entry.Name)
}

function Invoke-DownloadJob {
    # Downloads what is missing in a set. Modes:
    #   New      asks for confirmation, then creates the job state;
    #   Restart  after a purge: creates the job state without asking again;
    #   Resume   the job state exists;
    #   Repair   after a failed verification: every downloaded file is MD5-checked and no
    #            verification is offered at the end.
    # In every mode, a file that was partial when the job started (.part or short final file)
    # is MD5-checked once complete: after a power cut its tail may hold unwritten blocks.
    param($Set, [string]$RootPath, $Catalog, [ValidateSet('New', 'Restart', 'Resume', 'Repair')][string]$Mode)
    $dir = Join-Path -Path $RootPath -ChildPath $Set.SubDir
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $entries = @(Get-SetFileList -Set $Set -Catalog $Catalog)
    $local = Get-LocalFileTable -Dir $dir
    $work = New-Object -TypeName System.Collections.Generic.List[object]
    $partial = @{}
    $total = [int64]0
    foreach ($entry in $entries) {
        $left = Get-EntryRemaining -Entry $entry -Local $local
        if ($left -eq 0 -and $local.ContainsKey($entry.Name) -and $local[$entry.Name] -eq $entry.Size) {
            if ($local.ContainsKey($entry.Name + '.part')) {   # stray .part next to a complete table
                Remove-Item -LiteralPath (Join-Path -Path $dir -ChildPath ($entry.Name + '.part')) -Force
            }
            continue
        }
        # Bytes left, or a complete .part that still has to be flushed, renamed and MD5-checked
        # (the run stopped between the end of curl and the rename): Invoke-FileDownload does it.
        $work.Add($entry)
        $total += $left
        if ($left -lt $entry.Size) { $partial[$entry.Name] = $true }
    }
    if ($work.Count -eq 0) {
        Write-Msg -Level Ok -Text ('{0}: the {1} files are already present.' -f $Set.Label, $entries.Count)
    } else {
        # --- Safety checks, before anything is written ---
        $volume = Get-VolumeInfo -Path $dir
        $largest = [int64]($work | Measure-Object -Property Size -Maximum).Maximum
        if ($volume.FileSystem -match '^(FAT|FAT12|FAT16|FAT32)$' -and $largest -ge 4GB) {
            Write-Msg -Level Error -Text ('{0} is formatted {1}, which cannot store files of 4 GiB or more (largest here: {2}). Use NTFS, exFAT or ReFS.' -f
                                          $dir, $volume.FileSystem, (Format-Size -Bytes $largest))
            return 1
        }
        $margin = [int64](1GB + 0.005 * $total)
        if ($volume.Free -ge 0 -and $volume.Free -lt $total + $margin) {
            Write-Msg -Level Error -Text ('Not enough free space for {0} in {1}:' -f $Set.Label, $dir)
            Write-Msg -Text ('  to download {0} + safety margin {1}, free {2}' -f (Format-Size -Bytes $total),
                             (Format-Size -Bytes $margin), (Format-Size -Bytes $volume.Free))
            return 1
        }
        # --- Confirmation and job state (new jobs) ---
        Write-Msg -Text ('{0}: {1} file(s) to download, {2}, into {3}' -f $Set.Label, $work.Count,
                         (Format-Size -Bytes $total), $dir)
        if ($Mode -eq 'New') {
            if ($Set.Key -eq '34567') {
                $big = @($work | Where-Object { $_.Size -ge 4GB }).Count
                Write-Msg -Level Warn -Text 'This set is huge. Please read before starting:'
                Write-Msg -Text ('  largest file    : {0}' -f (Format-Size -Bytes $largest))
                Write-Msg -Text ('  at 1 Gbit/s     : about {0} (theoretical line rate)' -f (Format-Duration -Seconds ($total / 125000000)))
                Write-Msg -Text ('  at 100 Mbit/s   : about {0}' -f (Format-Duration -Seconds ($total / 12500000)))
                Write-Msg -Text ('  {0} files are 4 GiB or larger: NTFS, exFAT or ReFS only.' -f $big)
                Write-Msg -Text '  Ctrl+C is safe at any time: the next run resumes where it stopped.'
                if (-not (Read-Confirmation -Prompt 'Start this download?' -Word 'YES')) {
                    Write-Msg -Text 'Cancelled.'
                    return 0
                }
            } elseif (-not (Read-YesNo -Prompt 'Start the download?' -Default $true)) {
                Write-Msg -Text 'Cancelled.'
                return 0
            }
        }
        if ($Mode -eq 'New' -or $Mode -eq 'Restart') {
            Save-JobState -State (Initialize-JobState -Set $Set -Action 'Download' -RootPath $RootPath)
        }
        # --- Download loop ---
        Write-Msg -Level Note -Text 'Downloading. Ctrl+C stops at any time; run the script again to resume.'
        $progress = @{ Index = 0; Count = $work.Count; Total = $total; DoneBefore = [int64]0
                       FileStart = [int64]0; FileDone = [int64]0; Samples = (New-Object -TypeName System.Collections.Queue) }
        $failed = 0
        foreach ($entry in $work) {
            $progress.Index++
            $check = ($Mode -eq 'Repair') -or $partial.ContainsKey($entry.Name)
            $problem = Invoke-FileDownload -Entry $entry -Dir $dir -Progress $progress -CheckMd5 $check
            if ($null -ne $problem) {
                $failed++
                Write-Msg -Level Error -Text $problem
            } elseif ($script:PlainOutput) {
                Write-Msg -Text ('[{0}/{1}] {2} OK' -f $progress.Index, $progress.Count, $entry.Name)
            }
        }
        Clear-StatusLine
        if ($failed -gt 0) {
            Write-Msg -Level Error -Text ('{0} file(s) could not be downloaded. The job is kept: run the script again and choose Resume.' -f $failed)
            return 1
        }
    }
    # --- Success: checksum file, end of the job, optional verification ---
    $checksumFile = Save-ChecksumFile -Set $Set -RootPath $RootPath -Catalog $Catalog
    Clear-JobState
    Write-Msg -Level Ok -Text ('{0} is complete in {1} (checksum file: {2}).' -f $Set.Label, $dir, (Split-Path -Path $checksumFile -Leaf))
    if ($Mode -eq 'Repair') { return 0 }
    $bytes = ($entries | Measure-Object -Property Size -Sum).Sum
    if (Read-YesNo -Prompt ('Verify the MD5 checksums of the {0} files now ({1} to read)?' -f $entries.Count, (Format-Size -Bytes $bytes)) -Default $false) {
        return (Invoke-VerifyJob -Set $Set -RootPath $RootPath -Catalog $Catalog -State $null)
    }
    return 0
}

function Resolve-VerificationResult {
    # Reports a verification. CORRUPT files are deleted (their size is right, so a download would
    # skip them), then the repair becomes a download job, kept until it succeeds.
    param($Set, [string]$RootPath, $Catalog, $Result)
    $problems = @($Result.Problems)
    if ($problems.Count -eq 0) {
        Clear-JobState
        Write-Msg -Level Ok -Text ('{0}: the {1} files are verified, checksums OK.' -f $Set.Label, $Result.Checked)
        return 0
    }
    $dir = Join-Path -Path $RootPath -ChildPath $Set.SubDir
    foreach ($problem in ($problems | Select-Object -First 30)) {
        $line = '{0,-10} {1}' -f $problem.Kind, $problem.Name
        if ($problem.Detail) { $line += ' (' + $problem.Detail + ')' }
        Write-Msg -Level Error -Text $line
    }
    if ($problems.Count -gt 30) { Write-Msg -Text ('... and {0} more.' -f ($problems.Count - 30)) }
    $corrupt = @($problems | Where-Object { $_.Kind -eq 'CORRUPT' })
    foreach ($problem in $corrupt) {
        Remove-Item -LiteralPath (Join-Path -Path $dir -ChildPath $problem.Name) -Force -ErrorAction SilentlyContinue
    }
    if ($corrupt.Count -gt 0) { Write-Msg -Level Warn -Text ('{0} corrupt file(s) deleted.' -f $corrupt.Count) }
    $unreadable = @($problems | Where-Object { $_.Kind -eq 'UNREADABLE' }).Count
    if ($unreadable -gt 0) {
        Write-Msg -Level Warn -Text ('{0} file(s) could not be read (disk or permission problem); they were left untouched.' -f $unreadable)
    }
    $toFetch = $problems.Count - $unreadable
    if ($toFetch -eq 0) {
        Clear-JobState
        return 1
    }
    Save-JobState -State (Initialize-JobState -Set $Set -Action 'Download' -RootPath $RootPath)
    if ($null -eq $Catalog) {
        Write-Msg -Text 'Run the script again when Lichess is reachable and choose Resume to download them.'
        return 1
    }
    if (Read-YesNo -Prompt ('Download the {0} missing or deleted file(s) now?' -f $toFetch) -Default $true) {
        return (Invoke-DownloadJob -Set $Set -RootPath $RootPath -Catalog $Catalog -Mode 'Repair')
    }
    Write-Msg -Text 'The job is kept: run the script again and choose Resume to download them.'
    return 1
}

function Invoke-VerifyJob {
    # "Verify only", or the verification offered after a download. $State: saved job when resuming.
    param($Set, [string]$RootPath, $Catalog, $State)
    $dir = Join-Path -Path $RootPath -ChildPath $Set.SubDir
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        Write-Msg -Level Error -Text ('Nothing to verify: {0} does not exist.' -f $dir)
        if ($null -ne $State) { Clear-JobState }
        return 1
    }
    try {
        $sums = Get-ChecksumList -Set $Set -Dir $dir -Catalog $Catalog
    } catch {
        Write-Msg -Level Error -Text $_.Exception.Message
        return 1
    }
    if ($null -eq $State) {
        $State = Initialize-JobState -Set $Set -Action 'Verify' -RootPath $RootPath
        Save-JobState -State $State
    }
    $entries = @($sums.Entries)
    Write-Msg -Text ('Verifying {0}: {1} files, checksums from {2}' -f $Set.Label, $entries.Count, $sums.Source)
    Write-Msg -Level Note -Text 'Ctrl+C stops at any time; the next run resumes the verification.'
    $result = Invoke-Verification -Entries $entries -Dir $dir -State $State -Source $sums.Source
    return (Resolve-VerificationResult -Set $Set -RootPath $RootPath -Catalog $Catalog -Result $result)
}

function Show-Menu {
    # Two steps: the set, then the action. Returns (Set, Action), or $null to quit.
    param([string]$RootPath, $Catalog)
    $keys = @($script:Sets.Keys)
    while ($true) {
        Write-Msg -Text ''
        Write-Msg -Level Title -Text ('Destination: ' + $RootPath)
        $free = Get-FreeSpaceText -Path $RootPath
        if ($free) { Write-Msg -Level Note -Text ('Free space : ' + $free) }
        $syzygyLocal = Get-LocalFileTable -Dir (Join-Path -Path $RootPath -ChildPath 'Syzygy')
        $gaviotaLocal = Get-LocalFileTable -Dir (Join-Path -Path $RootPath -ChildPath 'Gaviota')
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $set = $script:Sets[$keys[$i]]
            $line = '  {0}) {1,-17}' -f ($i + 1), $set.Label
            if ($null -ne $Catalog) {
                $local = $syzygyLocal
                if ($set.Kind -eq 'Gaviota') { $local = $gaviotaLocal }
                $status = Measure-SetStatus -Set $set -Catalog $Catalog -Local $local
                if ($status.Pending -eq 0) { $todo = 'complete' }
                elseif ($status.Remaining -eq 0) { $todo = 'to finalize: {0} complete .part file(s)' -f $status.Pending }
                else { $todo = 'to download: ' + (Format-Size -Bytes $status.Remaining) }
                $line += ' {0,11}  {1,4} files  {2}' -f (Format-Size -Bytes $status.Total), $status.Count, $todo
            }
            Write-Msg -Text $line
        }
        Write-Msg -Text '  Q) Quit'
        $choice = Read-Choice -Prompt 'Tables' -Allowed @('1', '2', '3', '4', 'Q')
        if ($null -eq $choice -or $choice -eq 'Q') { return $null }
        $set = $script:Sets[$keys[[int]$choice - 1]]
        if ($null -eq $Catalog) {
            $action = Read-Choice -Prompt ('{0} (offline): [V] Verify only, [B] Back' -f $set.Label) -Allowed @('V', 'B')
        } else {
            $action = Read-Choice -Prompt ('{0}: [D] Download, [V] Verify only, [B] Back' -f $set.Label) -Allowed @('D', 'V', 'B')
        }
        if ($null -eq $action) { return $null }
        if ($action -eq 'B') { continue }
        if ($action -eq 'D') { return [pscustomobject]@{ Set = $set; Action = 'Download' } }
        return [pscustomobject]@{ Set = $set; Action = 'Verify' }
    }
}

function Invoke-Main {
    # Lock, pending job (resume / purge / abandon / quit), legacy migration, menu, job.
    # Returns the exit code.
    Write-Msg -Level Title -Text ('get-tablebases {0} - Lichess mirror {1}' -f $script:ScriptVersion, $script:BaseUrl)
    $lockCode = Lock-Instance
    if ($lockCode -ne 0) { return $lockCode }

    $script:CurlPath = Resolve-Curl -Name $Curl
    if ($null -eq $script:CurlPath) {
        Write-Msg -Level Warn -Text 'curl not found: downloads are disabled (-Curl can point to a curl executable).'
    } else {
        Write-Msg -Level Note -Text ('curl {0}: {1}' -f (Get-CurlVersion), $script:CurlPath)
    }

    $rootPath = Resolve-RootPath -Path $Root
    $job = $null
    $state = Read-JobState
    if ($null -ne $state) {
        $set = $script:Sets[[string]$state.Set]
        if ($script:RootGiven -and $rootPath -ne [string]$state.Root) {
            Write-Msg -Level Note -Text ('-Root is ignored while a job is pending: its destination is ' + $state.Root)
        }
        $rootPath = [string]$state.Root
        Move-LegacyLayout -RootPath $rootPath
        Write-Msg -Level Warn -Text 'An unfinished job was found:'
        Write-Msg -Text ('  {0} {1} into {2} (started {3})' -f $state.Action, $set.Label, $rootPath, (Format-Stamp -Value $state.Started))
        if ($state.Action -eq 'Download') {
            $prompt = '[R] Resume, [P] Purge the files of this set and start over, [A] Abandon (keep the files), [Q] Quit'
        } else {
            $prompt = '[R] Resume, [P] Restart the verification from the first file, [A] Abandon, [Q] Quit'
        }
        $answer = Read-Choice -Prompt $prompt -Allowed @('R', 'P', 'A', 'Q')
        if ($null -eq $answer -or $answer -eq 'Q') { return 0 }
        if ($answer -eq 'R') {
            $job = [pscustomobject]@{ Set = $set; Action = [string]$state.Action; Mode = 'Resume'; State = $state }
        } elseif ($answer -eq 'P') {
            Write-LockInfo -Job ('Purge {0} into {1}' -f $set.Label, $rootPath)
            if ($state.Action -eq 'Download') {
                if (-not (Clear-SetFile -Set $set -RootPath $rootPath)) { return 0 }
                $job = [pscustomobject]@{ Set = $set; Action = 'Download'; Mode = 'Restart'; State = $null }
            } else {
                $job = [pscustomobject]@{ Set = $set; Action = 'Verify'; Mode = 'New'; State = $null }
            }
        } else {
            Clear-JobState
            Write-Msg -Level Ok -Text 'Job abandoned, files kept.'
            Clear-PartialFile -RootPath $rootPath
            $rootPath = Resolve-RootPath -Path $Root
        }
    }
    if ($null -eq $job) { Move-LegacyLayout -RootPath $rootPath }

    $catalog = Get-Catalog
    if ($null -eq $job) {
        $choice = Show-Menu -RootPath $rootPath -Catalog $catalog
        if ($null -eq $choice) { return 0 }
        $job = [pscustomobject]@{ Set = $choice.Set; Action = $choice.Action; Mode = 'New'; State = $null }
    }
    Write-LockInfo -Job ('{0} {1} into {2}' -f $job.Action, $job.Set.Label, $rootPath)
    if ($job.Action -eq 'Verify') {
        return (Invoke-VerifyJob -Set $job.Set -RootPath $rootPath -Catalog $catalog -State $job.State)
    }
    if ($null -eq $catalog) {
        Write-Msg -Level Error -Text 'Downloading needs Lichess and curl. Run the script again when they are available.'
        return 1
    }
    return (Invoke-DownloadJob -Set $job.Set -RootPath $rootPath -Catalog $catalog -Mode $job.Mode)
}

#endregion

#region ------------------------------------------------------------------ Entry point

try { $script:PlainOutput = [Console]::IsOutputRedirected } catch { $script:PlainOutput = $true }
if ($Host.Name -match 'ISE') { $script:PlainOutput = $true }       # no in-place line in the ISE

# Lock and state files live next to the script (not in the destination): a run started
# without -Root still finds the pending job, whose destination is recorded inside.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = (Get-Location).ProviderPath }
$scriptBase = 'get-tablebases'
if ($PSCommandPath) { $scriptBase = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath) }
$script:LockPath = Join-Path -Path $scriptDir -ChildPath ($scriptBase + '.lock')
$script:StatePath = Join-Path -Path $scriptDir -ChildPath ($scriptBase + '.state')

$exitCode = 1
try {
    $result = @(Invoke-Main)
    $exitCode = [int]$result[-1]
    if ($result.Count -gt 1) { Write-Verbose ('unexpected pipeline output: ' + ($result -join ', ')) }
} catch {
    Clear-StatusLine
    Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
    $exitCode = 1
} finally {
    Close-CurlProcess
    Unlock-Instance
}
exit $exitCode

#endregion
