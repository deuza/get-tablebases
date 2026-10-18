# get-tablebases

[![License: CC0](https://img.shields.io/badge/license-CC0_1.0-lightgrey.svg?style=plastic)](https://creativecommons.org/publicdomain/zero/1.0/)
[![License: WTFPL](https://img.shields.io/badge/license-WTFPL_2.0-lightgrey.svg?style=plastic)](https://www.wtfpl.net/)
![Hack The Planet](https://img.shields.io/badge/hack-the--planet-black?style=plastic&logo=gnu&logoColor=white)
![Built With Love](https://img.shields.io/badge/built%20with-%E2%9D%A4%20by%20DeuZa-red?style=plastic)

![GitHub release](https://img.shields.io/github/v/release/deuza/get-tablebases?label=release&style=plastic)
[![GitHub last commit](https://img.shields.io/github/last-commit/deuza/get-tablebases?style=plastic)](https://github.com/deuza/get-tablebases/commits/main)
![GitHub commit activity](https://img.shields.io/github/commit-activity/t/deuza/get-tablebases?style=plastic)
![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/deuza/get-tablebases?style=plastic)

Interactive, resumable downloader and verifier for the **Gaviota** and **Syzygy**
chess endgame tablebases, as published by the Lichess mirror
<https://tablebase.lichess.ovh/tables/standard/>.

Two scripts, one behaviour:

| Script | Platform | Runs with |
| --- | --- | --- |
| `get-tablebases.ps1` | Windows 10 (version 1803 or later), Windows 11 | Windows PowerShell 5.1 (built in) or PowerShell 7 |
| `get-tablebases.sh` | Linux, macOS, any Unix with a POSIX shell | `/bin/sh`: dash, bash (including the bash 3.2 that macOS ships), busybox sh |

Same menu, same questions, same messages, same exit codes, same layout on disk.
Tested on Windows 11, Debian (dash and bash), busybox and macOS.

## The sets

| Set | Content | Files | Size (measured 2026-10-18) |
| --- | --- | ---: | ---: |
| Gaviota | 3-4-5 pieces, compressed (`.gtb.cp4`) | 145 | 6.54 GiB |
| Syzygy 3-4-5 | WDL + DTZ, up to 5 pieces | 290 | 938.38 MiB |
| Syzygy 3-4-5-6 | WDL + DTZ, up to 6 pieces | 1020 | 150.14 GiB |
| Syzygy 3-4-5-6-7 | WDL + DTZ, up to 7 pieces | 3022 | 16.87 TiB |

One run handles **one set** and **one action**: **Download** (a checksum
verification is offered at the end) or **Verify only**. The sizes above are a
snapshot: the menu shows the real remote sizes and what is still missing locally.

## Requirements

- `curl`: built into Windows 10 version 1803 and later (`curl.exe`), and into
  every Linux distribution and macOS. Another curl can be given with
  `-Curl` / `--curl`.
- Network access to `tablebase.lichess.ovh` for downloads. "Verify only" also
  works offline, from the checksum files already on disk.
- A file system that stores files of 4 GiB or more if you want the 7-piece set:
  821 of its files are that large, which FAT32 cannot hold. NTFS, exFAT, ReFS,
  ext4, XFS, APFS and friends are fine.
- Linux and macOS: a POSIX `/bin/sh`, the usual tools (`awk`, `df`, `mount`,
  `ps`, `sync`, `sed`, `sort`) and one of `md5sum`, `md5` or `openssl`.
  They all ship with Debian, every common Linux and macOS.

## Quick start

Windows:

```powershell
powershell .\get-tablebases.ps1
powershell .\get-tablebases.ps1 -Root D:\Tablebases
```

If Windows refuses to run the script (execution policy), either add
`-ExecutionPolicy Bypass` after `powershell` for that run only, or unblock the
downloaded file once with `Unblock-File .\get-tablebases.ps1`.

Linux and macOS (`chmod +x get-tablebases.sh` once, or run it with `sh`):

```sh
./get-tablebases.sh
./get-tablebases.sh --root /srv/tablebases
```

The menu, here on a Mac where Gaviota is already complete:

```text
$ ./get-tablebases.sh
get-tablebases 1.0.0 - Lichess mirror https://tablebase.lichess.ovh/tables/standard
curl 8.7.1: /usr/bin/curl
Reading the file lists, sizes and checksums from Lichess...

Destination: /Volumes/RED/Chess/get-tablebases
Free space : 3.93 TiB (hfs)
  1) Gaviota              6.54 GiB   145 files  complete
  2) Syzygy 3-4-5       938.38 MiB   290 files  to download: 938.38 MiB
  3) Syzygy 3-4-5-6     150.14 GiB  1020 files  to download: 150.14 GiB
  4) Syzygy 3-4-5-6-7    16.87 TiB  3022 files  to download: 16.87 TiB
  Q) Quit
Tables: 2
Syzygy 3-4-5: [D] Download, [V] Verify only, [B] Back: D
```

| Windows | Linux / macOS | Default | Meaning |
| --- | --- | --- | --- |
| `-Root DIR` | `--root DIR` | directory of the script | Destination. `Gaviota/` and `Syzygy/` are created below it. |
| `-Curl PATH` | `--curl PATH` | `curl.exe` / the `curl` found in `PATH` | curl executable to use. |
| | `-h`, `--help` | | Usage summary. |

In Windows PowerShell 5.1, `curl` alone is an alias of `Invoke-WebRequest`; the
script only accepts real executables, so it can never pick that alias.

## Where the files go

```text
<Root>/
  Gaviota/   *.gtb.cp4 + Gaviota.cp4.md5
  Syzygy/    *.rtbw + *.rtbz + exactly one checksum file:
             3-4-5.md5, 3-4-5-6.md5 or 3-4-5-6-7.md5
```

All Syzygy tables (WDL and DTZ, every piece count) live in one directory: their
names are unique, and most engines expect a single Syzygy path. The checksum
file describes the largest set that is complete on disk.

Point your engine to `Syzygy/` (in Stockfish, the `SyzygyPath` UCI option).
Engines and GUIs that support Gaviota tables take `Gaviota/` as path.

## What makes it safe

- A file is complete when its size matches the server; complete files are never
  downloaded again, partial ones are resumed from the last byte received, and a
  stalled transfer is restarted automatically.
- Each file lands in `<name>.part`, is flushed to disk, then renamed. An engine
  reading the directory never sees a truncated table, even after a power cut.
- Every file that was partial when a job started is MD5-checked once complete:
  after a power cut, a resumed file can hold blocks that were never written.
- Free space and the 4 GiB limit of FAT volumes are checked before anything is
  written. The 7-piece set shows what it means (about 17 days at 100 Mbit/s)
  and asks you to type `YES`.
- A lock next to the script forbids concurrent runs, and the job state survives
  Ctrl+C, network failures and reboots.

## Interrupted?

Ctrl+C is safe at any time. The next run finds the unfinished job and asks:

| Answer | Download job | Verify job |
| --- | --- | --- |
| **R** Resume | Continues. What is left is recomputed from the disk. | Continues from the checkpoint. |
| **P** Purge | Deletes the files of the set after you type `PURGE`, then downloads everything again. | Restarts the verification from the first file. Nothing is deleted. |
| **A** Abandon | Forgets the job and keeps the files; leftover `.part` files can be deleted. | Forgets the job. |
| **Q** Quit | Exits and keeps the job for later. | Same. |

After a reboot or a killed process, the lock is left behind: the script shows who
left it (PID, host, start time, job) and asks `Remove this stale lock and
continue? [y/N]`. Anything but `y` keeps it and exits with code 3.

Everything else, how a run works, the download and verification rules, the
pseudo-code, the lock and state files, the differences between the two scripts,
is in [docs/INTERNALS.md](docs/INTERNALS.md).

## Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | Success, or the user quit |
| 1 | Error, failed download or verification, or a job still pending |
| 2 | Another instance is running |
| 3 | The stale lock of an interrupted run was kept: you did not answer `y` to its removal |

## Troubleshooting

- **"curl not found".** Windows versions older than 10 1803 do not ship curl.
  Install curl and pass its path with `-Curl` (or `--curl` on Unix).
- **The script refuses to run (execution policy).** See the Windows note in
  [Quick start](#quick-start).
- **Download stuck on one file.** curl is restarted automatically when a
  transfer stalls. You can also press Ctrl+C and run the script again; nothing
  received so far is lost.
- **"No MD5 tool found" (Unix).** The shell script needs `md5sum`, `md5` or
  `openssl`. One of them exists on every Linux and macOS; on a minimal system,
  install coreutils or openssl.

## Credits

- Syzygy tablebases: Ronald de Man.
- Gaviota tablebases: Miguel A. Ballicora.
- Hosting: the Lichess tablebase mirror, `tablebase.lichess.ovh`.

## Licenses

Dual-licensed project:

- [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/): no copyright.
- [WTFPL](http://www.wtfpl.net/): Do What The Fuck You Want To Public License.

<p align="center">Maintained with ❤️ by <a href="https://github.com/deuza">DeuZa</a></p>
