# get-tablebases internals

How the two scripts work, for whoever wants to read or change them. The
[README](../README.md) is enough to use them.

Both scripts implement the same logic, function for function. The names in
brackets below are the PowerShell functions of `get-tablebases.ps1`; the shell
script uses the same structure with snake_case names (`lock_instance`,
`download_job`, `download_file`, `verify_job`...).

## How a run works

1. **Lock.** The script takes `get-tablebases.lock` next to itself and holds it
   until it exits (see [Lock and state files](#lock-and-state-files)).
2. **Unfinished job?** If `get-tablebases.state` exists, the previous job was
   interrupted. The script asks what to do with it: Resume, Purge, Abandon or
   Quit.
3. **Legacy layout** (Windows only). Tables left by the pre-release script in
   `3-4-5\`, `6-WDL\` and `6-DTZ\`, with its `syzygy-lichess.md5`, are moved
   silently into `Syzygy\`. Nothing is overwritten: a table already present in
   `Syzygy\` keeps its legacy twin where it is, with a warning. Emptied legacy
   directories are removed.
4. **Catalog.** File lists, sizes and checksums are read from the server:
   - Syzygy: `download.txt` (URLs, including the sub-directories of `7/`),
     `bytes.tsv` (sizes) and `md5`, joined by file name;
   - Gaviota: `Gaviota/Gaviota.cp4.md5` (names and checksums) and the directory
     listing (sizes), with a HEAD request as a fallback for a size missing from
     the listing.

   If Lichess is unreachable, the script runs in offline mode: downloads are
   disabled and "Verify only" uses the local checksum files.
5. **Menu.** First the set (with total size, file count and what is left to
   download), then the action.
6. **Job.** Download or verification, described below.

The directories `3-4-5-dtz-nr/` and `6-dtz-nr/` of the mirror are deliberately
ignored. They are specific to Lichess and outside the scope of these scripts.

Remote file names are checked against strict patterns (`K[QRBNP]*vK[QRBNP]*`
followed by `.rtbw` or `.rtbz`, `[a-z]+.gtb.cp4`). A malformed server answer
can never make the script write outside its directories.

## Download

- A file is **complete** when its local size equals the remote size. Complete
  files are never downloaded again.
- Each file is downloaded into `<name>.part`. When it is complete, its data is
  flushed to disk (`FlushFileBuffers` on Windows, `sync` elsewhere) and only then
  renamed. An engine reading the directory therefore never sees a truncated
  table, even after a power cut.
- A `.part` file that is already complete (the previous run stopped between the
  end of curl and the rename) is flushed, renamed and MD5-checked, not deleted.
  The menu lists such files as "to finalize".
- A file shorter than the remote one under its final name is turned into a
  `.part` and resumed. A file longer than the remote one is deleted and
  downloaded from zero.
- curl resumes partial files (`-C -`). After any failure the script starts a
  new curl, which continues from the last byte received. curl's own `--retry`
  is not used on purpose: on a retry, curl truncates the file back to where that
  curl invocation started, throwing away everything received in the meantime.
  A transfer slower than 1 KiB/s for 2 minutes is restarted the same way
  (`--speed-limit 1024 --speed-time 120`).
- If the server refuses the byte range (curl exit 33) or the `.part` file grew
  larger than the remote file, the file starts over from zero.
- A file is abandoned after 6 attempts in a row without any progress, or at once
  if the server answers 404. Attempts that do make progress reset that counter,
  so a multi-day download survives occasional network drops. The pause between
  attempts doubles from 5 s to a maximum of 60 s.
- Every file that was partial when the job started (a `.part` file, or a file
  shorter than the remote one under its final name) is MD5-checked once
  complete, whatever the way the job was started. After a power cut, the end of
  a partial file can contain blocks that were never written to disk; resuming it
  blindly would produce a file of the right size with wrong content. A wrong
  MD5 means one more download from zero, then the file is given up.
- In repair mode (after a failed verification), every downloaded file is
  MD5-checked.
- Before anything is written, the script refuses to start if the volume is FAT
  and a pending file is 4 GiB or larger, or if the free space is known and
  smaller than what is left to download plus 1 GiB plus 0.5 % of it. On Windows
  the free space takes per-user disk quotas into account.
- Syzygy 3-4-5-6-7 shows a summary before starting: largest file, theoretical
  duration at 1 Gbit/s (about 1d 17h) and at 100 Mbit/s (about 17 days), and
  the file system constraint. The user must type `YES`.
- When everything is downloaded, the checksum file is written, the job ends, and
  the script offers to verify the checksums.

## The checksum file

The checksum file of `Syzygy/` describes the **largest set that is complete** on
disk. Example: if the 6-piece tables are complete and 3-4-5 is downloaded again,
`3-4-5-6.md5` is written, not `3-4-5.md5`. The other per-set checksum files are
removed, so that exactly one remains. The files written are identical in content
to the server's `md5` file filtered by number of pieces; for 3-4-5-6-7 they are
identical byte for byte. `Gaviota/Gaviota.cp4.md5` is the server file, as is.

## Verification

- The expected checksums come from a local checksum file that covers the set. A
  `3-4-5-6-7.md5` also covers 3-4-5-6 and 3-4-5 once filtered by number of
  pieces; the largest candidate is tried first.
- When Lichess is reachable, that local file is cross-checked against the server.
  If they differ, the server checksums are used, so that a wrong local file can
  never get good tables deleted. With no suitable local file, the server
  checksums are used. Offline with no suitable local file, the verification is
  refused.
- Results: `MISSING`, `CORRUPT` (MD5 mismatch) and `UNREADABLE` (read error).
  At most 30 problems are listed, followed by the number of remaining ones.
- **CORRUPT files are deleted.** Their size is right, so a download would skip
  them otherwise. The repair then becomes a download job (kept in the state
  until it succeeds), and the script offers to run it immediately.
- UNREADABLE files are left untouched: the problem is the disk or the
  permissions, not the file.
- Progress is saved in the state file every 5 seconds, and on Ctrl+C. An
  interrupted verification resumes where it stopped: files validated before the
  interruption are only re-checked for presence and size.
- On Linux and macOS, files of 64 MiB or more are hashed by a background
  `md5sum` so that the progress line keeps living; smaller ones are hashed in
  the foreground. The speed and ETA of that line only count the files already
  hashed, because `md5sum` gives no progress inside a file: the figures stand
  still while a large table is being read.

## Pseudo-code

```text
main  [Invoke-Main, Lock-Instance]
    if the lock exists:
        if a running process holds it:
            show its owner (PID, host, start time, job); exit 2
        show who left it; ask "Remove this stale lock and continue? [y/N]"
        if the answer is not y: exit 3
        delete the lock
    create the lock, hold it until exit               # also on Ctrl+C

    root = -Root / --root, or the directory of the script
    job  = none
    if the state file exists:                         # unfinished job
        root = destination recorded in the job
        ask: Resume / Purge / Abandon / Quit
            Resume  -> job = saved job, mode Resume
            Purge   -> download job: delete the files of the set once PURGE
                                     is typed, then mode Restart
                       verify job:   start again from the first file
            Abandon -> delete the state; offer to delete leftover .part files
                       root = -Root / --root, or the directory of the script
            Quit    -> exit 0                         # the job is kept

    catalog = file lists, sizes, checksums from Lichess   # none: offline mode
    if job is none: menu -> set, then action (Download | Verify only), mode New
    run the job
    delete the lock

download job (set, mode)  [Invoke-DownloadJob]
    for each remote file of the set:
        left = remote size - local size    # local: final name, short file or .part
        if left > 0, or a complete .part is still waiting for its rename:
            add the file to the work list
    if the work list is not empty:
        refuse if the volume is FAT and a pending file is >= 4 GiB
        refuse if the free space is known and < left + 1 GiB + 0.5 %
        mode New:     confirm (type YES for the 7-piece set), then save the state
        mode Restart: save the state
        for each file of the work list:
            download file (MD5 check in mode Repair, and for every file that
                           was partial when the job started)
        if a file failed: keep the state; exit 1
    write the checksum file of the largest complete set; remove the other ones
    delete the state
    unless mode Repair: offer the verification -> verify job

download file (f)  [Invoke-FileDownload]
    turn a short file under the final name into f.part
    while f.part is shorter than the remote file:
        curl -C - -o f.part URL                   # resumes from the last byte written
        if the server refused the byte range, or f.part grew too long:
            delete f.part                         # this file starts over
        if HTTP 404: give up
        if f.part grew: stalled = 0, else: stalled = stalled + 1
        if stalled = 6: give up
        wait min(60, 5 x 2^stalled) seconds
    flush f.part to disk; rename f.part to f
    if an MD5 check is requested and the MD5 is wrong:
        delete f; download it once more from zero; still wrong: give up

verify job (set)  [Invoke-VerifyJob, Invoke-Verification, Resolve-VerificationResult]
    sums = the local .md5 covering the set (works offline);
           the server sums if they differ from it, or if there is none
    for each file of sums:
        validated before an interruption and same size: skip it
        absent: MISSING; read error: UNREADABLE; MD5 differs: CORRUPT
        every 5 s, and on Ctrl+C: save the progress in the state
    no problem: delete the state; exit 0
    only UNREADABLE files: delete the state; exit 1     # disk problem, files kept
    delete the CORRUPT files              # right size: a download would skip them
    the state becomes a download job for the set        # kept until it succeeds
    offline: exit 1 (the next run offers to resume)
    offer to download the missing files now (mode Repair)
```

## Lock and state files

Two files live next to the script, not in the destination. A run started without
`-Root` / `--root` therefore still finds the pending job, whose destination is
recorded inside.

| File | Lifetime | Purpose |
| --- | --- | --- |
| `get-tablebases.lock` | the running process | Forbids concurrent runs. |
| `get-tablebases.state` | the job, until it succeeds | Remembers the job (set, action, destination, verification progress). |

### The lock

The lock tells a live instance from a dead one:

- on Windows the lock is a file holding a small JSON record (PID, host, user,
  start time, job, script path). It is kept **open** by the running instance:
  a second instance cannot open it for writing, nor delete it;
- on Linux and macOS the lock is a directory, created atomically with `mkdir`,
  holding an `info` file with the same fields (`Pid=`, `Host=`, `User=`,
  `Started=`, `Job=`, `Script=`). It is live when that PID is still a running
  process on the same host whose command line names the script (`ps -p PID -o
  args=`, `kill -0` as a fallback). A lock taken from another host (script
  directory on a network share) cannot be probed and is reported as stale.

What happens then:

- **Another instance is running.** The new one prints who holds the lock and
  exits with code 2.
- **Ctrl+C, network failure, any error.** The script exits cleanly: the lock
  disappears, the job state stays. The next run directly offers to resume.
- **Reboot, power cut, killed process.** The lock remains, but no process holds
  it any more. The script shows who left it and asks `Remove this stale lock and
  continue? [y/N]`. `y` removes the lock and the run goes on. Any other answer,
  an empty line or a closed input keep the lock and exit with code 3.

Do not run the two scripts from one directory shared between Windows and Unix
machines: they use the same lock and state file names, and would take each other
for interrupted runs.

### The state file

The state file is written atomically (temporary file, flush, rename): a crash in
the middle leaves either the old or the new state, never a mix.

- On Windows it is a JSON document: `Format`, `ScriptVersion`, `Action`
  (`Download` or `Verify`), `Set`, `Root`, `Started`, and for a verification a
  `Verify` object with the source of the checksums and the map of the files
  already validated (name to size).
- On Linux and macOS it is a `key=value` file with the same fields
  (`Format=1`, `Action=`, `Set=`, `Root=`, `Started=`, `VerifySource=`),
  followed by one `ok <size> <name>` line per file already validated.

A state file with an unknown format, set or action is reported and ignored.

### Unfinished job

| Answer | Download job | Verify job |
| --- | --- | --- |
| **R** Resume | Continues. What is left is recomputed from the disk, so files deleted meanwhile are simply downloaded again. Files that were partial when the run started are MD5-checked once complete. | Continues from the checkpoint. |
| **P** Purge | Deletes the files of the set (tables, `.part`, checksum file) after you type `PURGE`, then downloads everything again. Tables with more pieces than the set, and any other file, are not touched. | Restarts the verification from the first file. Nothing is deleted. |
| **A** Abandon | Forgets the job and keeps the files. Leftover `.part` files are reported and can be deleted. Then the menu is shown. | Forgets the job. |
| **Q** Quit | Exits and keeps the job for later. | Same. |

## Windows and Unix: what differs

| Topic | `get-tablebases.ps1` | `get-tablebases.sh` |
| --- | --- | --- |
| Flush before rename | `FlushFileBuffers` on the file | `sync FILE` (coreutils), `sync` otherwise |
| Lock | file kept open | directory + PID, checked with `ps` |
| State file | JSON | `key=value` + `ok` lines |
| Free space | `GetDiskFreeSpaceEx`, per-user quotas included | `df -Pk` |
| File system name | `GetVolumeInformation` | `stat -f -c %T` (GNU) or `mount` (BSD, macOS) |
| MD5 | .NET `MD5` | `md5sum`, else `md5 -q`, else `openssl dgst -md5`, detected at start |
| File sizes | .NET | `stat -c %s` (GNU) or `stat -f %z` (BSD), else `ls -ln` |
| Verification progress | live inside each file | per completed file; large files hashed in the background |
| Legacy layout migration | yes | no (that layout only ever existed on Windows) |
| Interrupted by | Ctrl+C | Ctrl+C, `SIGTERM`, `SIGHUP` (same cleanup) |

Everything the user sees, the menu, the questions, the messages, the progress
line, the exit codes, is the same.

## Portability rules and linting

`get-tablebases.sh` has to run unchanged with dash (Debian's `/bin/sh`), bash
(the 3.2 of macOS included) and busybox sh, with either a GNU or a BSD userland.
Hence the rules it follows:

- POSIX sh only: no arrays, no `[[ ]]`, no `${var//}`, no `$'...'`. The one
  deliberate exception is `local`, which POSIX does not define but which dash,
  bash and busybox all provide. That is what the directive on the second line
  of the script, `# shellcheck disable=SC3043`, is about: without it shellcheck
  reports every `local`.
- awk programs stay within what the BSD awk of macOS accepts: no gawk
  extensions, no regex intervals such as `{32}` (lengths are tested with
  `length()`), `LC_ALL=C` everywhere so that `sort` and `join` agree.
- Tools are detected by behaviour, not by `uname`: GNU `stat -c` or BSD
  `stat -f`, `md5sum` or `md5 -q` or `openssl`, whether `sleep` accepts a
  fraction of a second. A GNU userland installed on macOS therefore works too.
- `md5sum -c` is never used: the script compares hashes itself. The `md5sum`
  of recent macOS is a BSD `md5` in disguise, and its `-c` exits 0 on malformed
  input.
- Sums and sizes above 2^31 go through awk (doubles are exact up to 2^53);
  shell arithmetic is only used where 64-bit `$(( ))` is a given.
- Everything the user types is read from standard input, every file loop reads
  from file descriptor 3, so that a prompt never eats a line of data.

Checks to run before committing:

```sh
shellcheck -s sh get-tablebases.sh      # also worth a pass with -s dash and -s bash
dash -n get-tablebases.sh
bash -n get-tablebases.sh
busybox sh -n get-tablebases.sh
```

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path .\get-tablebases.ps1 -Severity Information,Warning,Error
```

The PowerShell script carries a `SuppressMessageAttribute` for
`PSAvoidUsingWriteHost`: it is an interactive tool whose output is meant for the
console, not for a pipeline. Both scripts are expected to come out of these
checks with no finding at all.

## How it was tested

- `get-tablebases.ps1`: PowerShell parser and PSScriptAnalyzer (standard rules
  plus the compatibility rules for Windows PowerShell 5.1 and PowerShell 7),
  then the functions run against the real mirror: file counts and sizes,
  `3-4-5-6-7.md5` rebuilt byte for byte, argument quoting, download, resume of a
  truncated `.part`, verification of a corrupt file, lock (live, stale),
  Ctrl+C in a real console.
- `get-tablebases.sh`: shellcheck in sh, dash and bash modes, then the same
  scenarios under dash, bash and busybox sh, plus Ctrl+C during a transfer and
  during the hashing of a large file (checkpoint saved, no process left behind).
- Both: full runs on Windows 11, Debian and macOS.
