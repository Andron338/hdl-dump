# PS2 HDD Manager for macOS

A native SwiftUI front-end for installing PlayStation 2 games onto an internal PS2 HDD
(connected to the Mac with a USB/SATA adapter). It plays the role HDL Batch Installer / WinHIIP
play on Windows.

- **Format** a drive for PS2 (APA partition table, optional `+OPL` partition)
- **Install** games from ISO, CUE/BIN, NRG, GI, IML or ZSO — drag & drop, editable names, CD/DVD auto-detect, live progress, stop
- **List, rename and delete** installed games, with used/free space
- **HD Loader compatible**: games are named `PP.HDL.<name>` (unique `~2` suffixes when names collide), with a one-click fix for games installed with other naming
- **Duplicate detection by game ID**: discs already on the drive or in the queue are skipped unless you choose Install Anyway

It drives two bundled engines:

| Engine | Used for |
|---|---|
| `hdl_dump` (this repo) | listing (`hdl_toc --tsv`), installing (`inject_cd/inject_dvd`), renaming (`modify`), reading image info (`cdvd_info2`) |
| [`pfsshell`](https://github.com/ps2homebrew/pfsshell) (`vendor/pfsshell` submodule) | formatting (`initialize`, `mkpart +OPL`) and removing partitions (`rmpart`, which actually frees space, unlike `hdl_dump delete`) |

## Build

```bash
brew install meson ninja
git submodule update --init --recursive
./macos/build_app.sh
open "macos/build/PS2 HDD Manager.app"
```

## Permissions

Raw disks (`/dev/rdiskN`) are root-only. The app asks for an administrator password once per launch
(standard macOS prompt), then runs its disk commands through a root shell that only the app can talk to;
it exits when the app quits. If reading fails with
"Operation not permitted", enable the app under **System Settings › Privacy & Security › Full Disk Access**.

Only external, physical disks are listed; the Mac's internal/boot disk is never shown.
Volumes on a drive are unmounted only right before a write (format/install/rename/delete).

## Developer mode

Test without a real drive by pointing the app at a disk-image file. In this mode no admin rights are used:

```bash
mkfile -n 8g /tmp/ps2.img
open -n --env PS2HDD_TEST_IMAGE=/tmp/ps2.img "macos/build/PS2 HDD Manager.app"
```

`PS2HDD_TEST_QUEUE=/a.iso:/b.iso` also pre-fills the install queue.
