# CachyOS for PS5 firmware 11.60

This profile applies the changes the official `ps5-cachyos` image needs to
boot on firmware 11.60. It does not rebuild the kernel or the root filesystem. The
build script downloads the official image, rebuilds the initramfs from the
image's own packages, writes the 11.60 boot files to the FAT partition, and
makes a short list of changes to the root filesystem.

The base is `ps5-cachyos.img.xz` from the ps5-linux/ps5-linux-image release
built on 2026-08-29 from upstream commit `52db0a4`
(sha256 `9a29ca88c408cd290c19f4693f764251aab5698bb55c9f38fbf06c2764f21db1`).

A private build of the same profile (Run 18) booted to Steam Gaming Mode and
KDE Plasma on an 11.60 console on 2026-10-19. This public profile uses the
same boot files and the same root changes, minus the private items listed
under [Not included](#not-included). An image built from it has not been
booted on hardware yet.

## Build

On Linux x86_64, as root:

```bash
sudo ./scripts/build-cachyos1160-image.sh
```

That downloads the base image into `work/cachyos1160/` and writes
`output/ps5-cachyos1160.img` (12,582,912,000 bytes) and
`output/cachyos1160-root-changes.txt`. Use `--base-xz PATH` to start from a
local copy of `ps5-cachyos.img.xz`, `--output PATH` to write somewhere else,
and `--work-dir DIR` to move the scratch space.

The host needs curl, xz, util-linux, e2fsprogs, dosfstools, binutils, and gcc
with static glibc (`libc6-dev` on Ubuntu). A privileged `linux/amd64` Docker
container works too. The base image is never modified; the script works on a
copy and only renames it to the output path once every check has passed.

The build stops if any of these do not match:

- the base download, its raw size, the partition table, and both partition
  hashes before anything changes;
- the rebuilt initramfs, by exact size and hash;
- every root filesystem change, against [`root-changes.expected`](root-changes.expected)
  (the script compares full before/after manifests of the root partition);
- `e2fsck -fn` and `fsck.fat -n`, which must be clean;
- the five FAT boot files, by size and hash, and nothing else on the FAT;
- no SSH host keys and no `authorized_keys` anywhere in the image, and the
  first-boot marker present.

## Boot files

These are the files the 11.60 loader reads from the FAT partition. The loader
refuses a `bzImage` or `initrd.img` of any other size.

| File | Size | SHA-256 | Source |
|------|-----:|---------|--------|
| `bzImage` | 12,702,720 | `11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde` | official image, unchanged |
| `initrd.img` | 54,376,639 | `c37b88569ef8f05b0b4ae432a8ec0fd323b7a3537a6441f8c45baaad45ff061f` | rebuilt, see below |
| `cmdline.txt` | 118 | `aec7a85e9ebcf36e4bdaeb89242b898e17817acd40c16db57a3bb9c3117b1da8` | [`cmdline.txt`](cmdline.txt) |
| `vram.txt` | 11 | `bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0` | official image, unchanged |
| `kexec.sh` | 136 | `0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52` | official image, unchanged |

The command line drops the official image's forced `video=DP-1:1920x1080@60`
mode and adds `consoleblank=0`.

The initramfs is built inside the image's root with
[`tools/build_1160_initrd.sh`](tools/build_1160_initrd.sh), a copy of the
porting repository's
[initramfs recipe](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/initrd-recipe.md)
with one fix to its `zstd` call. It unpacks the Cyan Skillfish 2 GPU firmware
from the image's `linux-firmware-amdgpu` package, adds
`/etc/modprobe.d/ps5-amdgpu.conf` (`dpm=0 gpu_recovery=0 force_1080p=1`), and
runs the image's `mkinitcpio`. mkinitcpio packs `/etc/modprobe.d` into the
initramfs, so this runs before any other change to the root. The result is
byte-identical to the initramfs used on hardware. The root's own
`/boot/initrd.img-7.1.7` is left as shipped.

## Root filesystem changes

The full list with sizes and hashes is in
[`root-changes.expected`](root-changes.expected). In short:

- **First boot.** Hostname `ps5`, `127.0.1.1 ps5` in `/etc/hosts`, timezone
  UTC, and `/etc/ps5-first-boot-done`. These are the first-boot wizard's
  defaults, so the wizard is skipped and tty1 goes straight to Gaming Mode.
- **Display.** The raw GPU firmware files and `ps5-amdgpu.conf` left by the
  initramfs build, plus `ps5-amdgpu-reprobe.service`, which re-detects the
  display connector after amdgpu starts. The helper and its unit come from
  the Ubuntu 24.04 profile.
- **Wi-Fi off.** `moal` and `mlan` are blacklisted, and
  `ps5-stage-firmware.service` is no longer started at boot (the unit file
  stays). No Wi-Fi firmware or modules are added. The official image's own
  prebuilt modules stay on disk and do not load.
- **Ethernet.** `mts` is loaded at boot.
- **Kernel pin.** `IgnorePkg = linux-ps5` in `/etc/pacman.conf` and a pacman
  hook that aborts any transaction that installs, upgrades or removes
  `linux-ps5`. The package's install script rebuilds the initramfs and copies
  it and the kernel to the FAT partition, and the loader would refuse the
  next boot.
- **Fan.** `/usr/local/sbin/ps5_fan_max`, compiled from
  [`files/ps5_fan_max.c`](files/ps5_fan_max.c) as a static binary on the build
  host, and `ps5fan.service`, which runs it once at boot to request fan servo
  pattern 3 (maximum). Both come from the Ubuntu 24.04 profile unchanged; the
  unit's `Before=gdm3.service` has no effect on CachyOS. Run 18 sent the same
  `/dev/icc` request with a private tool. This helper has not run on CachyOS
  hardware yet.
- **Boot report.** `ps5-boot-report.timer` runs `/usr/local/sbin/ps5-boot-report`
  35 seconds after boot. It writes `/var/log/ps5-boot-report.txt` and
  `ps5-boot-report.txt` on the FAT partition, which helps on consoles without
  UART. It is the Ubuntu profile's report with CachyOS service names and two
  extra sections (boot file hashes and Wi-Fi state). The report can contain
  network addresses, MAC addresses, connection names and journal entries, so
  review it before posting it anywhere.

## Login

The account comes from the official image: user `steam`, password `steam`,
passwordless `sudo`. SSH keeps the official image's settings, so password
login works and root login does not. Change the password after the first
boot:

```bash
passwd
```

SSH host keys are generated on the console at first boot.

## Not included

Compared with the private Run 18 image, this profile leaves out:

- SSH host keys and the `authorized_keys` file;
- the SSH drop-in that allowed key login only;
- `regulatory.db`, which is only needed with Wi-Fi on;
- the private fan tool, replaced by `ps5_fan_max` above;
- a personal timezone (this image uses UTC).

It also contains no IW620 Wi-Fi firmware, no Wi-Fi modules beyond those in the
official image, and no packages installed or upgraded during the build. The
11.60 loader is not part of the image.

For Wi-Fi, see the porting repository's
[Wi-Fi guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/ubuntu2404-wifi.md).
It was written for the Ubuntu image.
