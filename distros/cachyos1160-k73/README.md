# CachyOS on Linux 7.3.0 for PS5 firmware 11.60

This profile takes the same official `ps5-cachyos` image as
[`cachyos1160`](../cachyos1160/README.md) and replaces its 7.1.7 kernel with
Linux 7.3.0. On top of the cachyos1160 changes it adds the IW620 Wi-Fi driver
built for the new kernel, keeps the PS5 CPU and GPU frequency drivers
available without loading them, and lets pacman keep the boot files up to
date.

A local pre-release image from this profile booted on hardware in Run 21.
Display, Ethernet, loader-supplied IW620 Wi-Fi and the frequency drivers all
worked in that run. Run 21 did not boot either tagged CI image. The current
image-2 candidate supersedes image 1 but is still unbooted; its Bluetooth and
Wi-Fi load-order fixes need a fresh hardware run.

> **Tester warning:** [image 2 is a public prerelease](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-2),
> but the exact CI image has not booted on a console. It is only for retail PS5
> firmware 11.60 and requires the
> [bounded 11.60 loader prerelease](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-dma-e820-bounded-run21).
> Use the bounded Wi-Fi ELF for the first run and follow the
> [image-2 tester guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-2-tester-guide.md).
> Flashing overwrites the entire target drive. Keep the default-password system
> on a trusted LAN, change the password immediately, fully power off instead of
> using Rest Mode, never redistribute the console-dumped
> `pcieuartiw620_combo_v1.bin`, and redact reports before posting them.

The base is `ps5-cachyos.img.xz` from the ps5-linux/ps5-linux-image release
built on 2026-08-29 from upstream commit `52db0a4`
(sha256 `9a29ca88c408cd290c19f4693f764251aab5698bb55c9f38fbf06c2764f21db1`).

## Image 2 tester prerelease

| Item | Value |
|------|-------|
| Source tag | `cachyos1160-k73-image-2` |
| Source commit | `346088a48f66eb956dafdec9de5085e73b2d44a5` |
| Kernel package | `linux-ps5 7.3.0-2` |
| CI | [workflow 39481460775](https://github.com/gzimbric/ps5-linux-image/actions/runs/39481460775): success |
| Release state | [public tester prerelease](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-2) |
| Release image | one `ps5-cachyos1160-k73.img.xz`; 1,943,471,712 bytes; never split |
| Compressed SHA-256 | `8b785243f79a32a4155cc1e39bed01d580e25ca514e88abbfed1a8a8157a281a` |
| Raw image | 12,582,912,000 bytes; SHA-256 `3798c7dba96412c5301eb201d8bf8aa4edd1b2f80a743dfd7b90b2a79222c62d` |
| Hardware status | unbooted |

The downloaded prerelease assets, GitHub digests, `SHA256SUMS`, XZ stream and
raw image hash were checked after the run. The release workflow aborts before
creating a draft if the compressed image is 2 GiB or larger. A completed
build or verifier pass, and publication of a prerelease, provide only software
and release validation; none of them is a console boot.

Compared with the local image that booted in Run 21, image 2:

- applies the hash-pinned IW620 Bluetooth quirk-ordering follow-up described
  below and records the package revision as `7.3.0-2`;
- blacklists `moal`'s automatic PCI-alias load, copies the console-supplied
  firmware first, and then loads the driver explicitly; and
- keeps the already-tested rmux kernel patch set, bounded-loader contract,
  VCN setup, and manual frequency-driver policy unchanged.

Neither image-2 fix has been tested on the console. Steam's **Switch to
Desktop** action and joining Wi-Fi from the KDE network menu also remain
unresolved; Run 21 used a manual session switch and `sudo nmcli`. Bluetooth
must be retested with the internal controller, Wi-Fi must be tested from a
cold boot, and the frequency drivers stay manual until a bounded thermal and
stability run establishes a safe policy. VCN video decode, an independent
storage read-back or integrity check, repeat boots, suspend, and broader
hardware coverage are also outside the current evidence.

## Patch provenance and credit

The PS5 kernel baseline is the exact 7.3 patch set published by rmux
(Armandas Kvietkus):
[rmuxnet/ps5-linux-patches-1](https://github.com/rmuxnet/ps5-linux-patches-1),
used as published at commit
`36f173f39e5e76c00c4e366a7b909f33bc665ad5`. It is rmux's port of the
ps5-linux PS5 patches to Linux 7.3, plus rmux's CPU frequency
(`ps5_cpufreq`) and GPU frequency (`ps5_gpufreq`) drivers. The build fetches
`linux.patch`, the kernel config and the VCN firmware from that commit and
checks each by SHA-256; the pinned `linux.patch` hash is
`b8a238b9973febbcf851053d99195bd7320bb0827c8ee5e4c54eba6b6f7cde3f`.
It does not rewrite or replace rmux's patch set, and the authorship carried
in the patch and drivers is unchanged.

Image 2 then applies one separate kernel follow-up,
[`ps5-btusb-iw620-quirks.patch`](kernel/ps5-btusb-iw620-quirks.patch), with
SHA-256
`54d7addbb4cd95c943f9a4485229ac5516ad08ebe0f4aa02fd72cf33298fa0a2`.
It restores the IW620 `quirks_table` entry and post-lookup interface-check
ordering present in merged [ps5-linux patch-set PR #35](https://github.com/ps5-linux/ps5-linux-patches/pull/35)
but absent from the pinned rmux 7.3 patch, while retaining rmux's 7.3 IW620
quirk flags. This is not part of rmux's pinned patch and has not yet been
proven by a console boot.

[VivaLaVent's Bazzite Deck v1.0.3](https://github.com/VivaLaVent/ps5-bazzite-deck/releases/tag/v1.0.3)
independently reports a paired DualSense on a CFI-10xx PS5 running firmware
13.60 after the same core `btusb` correction. Its patch is not byte-identical
to this one. That result supports the diagnosis, but it is not an 11.60
hardware test of image 2, which remains unbooted.

The out-of-tree Wi-Fi modules are a separate driver build: it uses the four pinned
ps5-linux/ps5-linux-mwifiex patches plus this profile's hash-pinned Linux 7.3
compatibility patch (SHA-256
`899b4b1cd83bf6b85074d3aff311bbc104723e118a327aa65f7326546c789304`).
Those do not alter rmux's kernel patch set.

## Loader

The boot files are not the exact sizes the earlier 11.60 loader builds
require, so every one of them refuses this image. That includes the
published DMA E820 loader (`firmware-11.60-dma-e820-run18`) and the
`linux-1160-dma-e820-wifi` target, whose name is close to the Wi-Fi one
below. This image needs the
[public bounded-loader tester prerelease](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-dma-e820-bounded-run21).
The exact Run 21 artifacts were built at commit `98925a2`; current loader
`main` reproduces their hashes and adds direct-target and CI safeguards:

| Target | ELF sha256 |
|--------|------------|
| `make linux-1160-dma-e820-bounded-wifi` (also writes this console's Wi-Fi firmware, see below) | `e9fe6469943e97a635eccd3f674e55876b56cd1bbd69023eee3af4acea3a1b5f` |
| `make linux-1160-dma-e820-bounded` | `1c80b040c5a808b3f09418728424a875d5598fe6b2a5d68adeb4db5979a7541a` |

The bounded Wi-Fi build, with the `e9fe6469…` hash above, booted Run 21 and
supplied the console's Wi-Fi firmware. The non-Wi-Fi bounded build has not
been booted on hardware yet. Neither image 1 nor image 2 was the image used
in Run 21, and image 2 is still unbooted. The ELF does not contain the Wi-Fi
firmware: it copies this console's own firmware to the USB at runtime. Do not
upload or redistribute `lib/nxp/pcieuartiw620_combo_v1.bin` from the boot
partition or `/lib/firmware/nxp/pcieuartiw620_combo_v1.bin` from Linux.

The bounded loader checks the files instead of their sizes:
[`files/ps5-1160-check-boot-files`](files/ps5-1160-check-boot-files) runs
the same checks as that commit, and the build runs it on every boot file it
writes. In short, the compressed kernel copied to 0x100000 has to end below
16 MiB, the decompression window has to end by 0x3fffc000, the kernel has to
be built with KASLR, `bzImage` and `initrd.img` together can take at most
160 MiB, and `cmdline.txt` must not contain `nokaslr`, `mem=`, `memmap=` or
any non-ASCII byte. Under the DMA reservation, KASLR is what moves the kernel
out of 16 MiB to 1 GiB, so the kernel config keeps `CONFIG_RANDOMIZE_BASE=y`.

## Build

The kernel is built first, then packaged, then the image. On Linux x86_64:

```bash
./scripts/build-linux-ps5-k73.sh
sudo ./scripts/package-linux-ps5-k73.sh
sudo ./scripts/build-cachyos1160-k73-image.sh
sudo ./scripts/verify-cachyos1160-k73-image.sh --image output/ps5-cachyos1160-k73.img
```

The [`CachyOS 7.3 11.60 image`](../../.github/workflows/cachyos1160-k73-image.yml)
workflow runs the same steps on GitHub-hosted runners, zeroes the free
blocks of the root filesystem, runs the verifier again, compresses the image
to one `.img.xz` and attaches it to a draft release. It never creates
numbered parts. If the compressed file is 2 GiB or larger, the workflow fails
before the release step.

### Kernel

[`scripts/build-linux-ps5-k73.sh`](../../scripts/build-linux-ps5-k73.sh)
fetches each source at a pinned commit:

| Source | Commit |
|--------|--------|
| Linux, tag `v7.3` | `c03c1a14507dfaf8b856c2608f9ac216021fc222` |
| rmuxnet/ps5-linux-patches-1 | `36f173f39e5e76c00c4e366a7b909f33bc665ad5` |
| ps5-linux/ps5-linux-mwifiex | `4aff9085530a3cdf7d5fbb124c006cc299ac3605` |
| nxp-imx/mwifiex | `a5fe4e194bf99315e349d81d77d6dfacec70757a` |

`--patches-repo URL` fetches the patch set from a mirror instead; it still
has to have commit `36f173f`, and the files are still checked by SHA-256.
The CI workflow takes the same URL as its `patches_repo` input.

It builds in the same Debian kernel-builder image and package snapshot as
the Ubuntu 24.04 kernel (`x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0`),
with a fixed build user, host and timestamp. The kernel step
([`docker/kernel-builder/build-k73.sh`](../../docker/kernel-builder/build-k73.sh)):

- checks `linux.patch` (`b8a238b9…`), the `.config` (`2294e750…`) and
  `firmware/amdgpu/ps5_vcn.bin` (404,544 bytes, `bbd15ab6…`) by SHA-256 and
  applies the patch to v7.3, then checks and applies the local
  [`ps5-btusb-iw620-quirks.patch`](kernel/ps5-btusb-iw620-quirks.patch)
  (`54d7addb…`);
- sets `X86_PS5_CPUFREQ=m` and `PS5_GPUFREQ=m` (the published config has them
  built in) and runs `make olddefconfig`. Every other difference from the
  published config is a toolchain line; the build log shows the diff;
- builds `bzImage` and the modules, checks that `ps5_vcn.bin` is built into
  the kernel, and checks `bzImage` against the bounded loader;
- records the `bzImage` size and SHA-256 in `kernel/kernel-build-info.txt`.

`amdgpu` keeps `dpm=0 gpu_recovery=0 force_1080p=1`
([`config/ps5-amdgpu.conf`](config/ps5-amdgpu.conf)).

The Wi-Fi step
([`docker/kernel-builder/build-iw620-k73.sh`](../../docker/kernel-builder/build-iw620-k73.sh))
runs with no network in `/build/nxp`, against the kernel tree in `/src`, with
objtool on. It applies the four ps5-linux/ps5-linux-mwifiex `4aff908`
patches the 7.1.7 Ubuntu Wi-Fi build also used (each checked by SHA-256) and
[`kernel/ps5-iw620-kernel73-compat.patch`](kernel/ps5-iw620-kernel73-compat.patch),
which adapts the driver to three changes in Linux 7.3 (SHA-256
`899b4b1cd83bf6b85074d3aff311bbc104723e118a327aa65f7326546c789304`);
its header explains them. The build stops on any compiler, objtool or modpost
warning, and checks `.return_sites`, the vermagic and the IW620 PCI alias.

[`scripts/package-linux-ps5-k73.sh`](../../scripts/package-linux-ps5-k73.sh)
packages the kernel as `linux-ps5 7.3.0-2` for pacman, laid out like the
upstream package (kernel, modules, build headers, UAPI headers) plus AMD's
licence for `ps5_vcn.bin` in `/usr/share/licenses/linux-ps5`. Its install
script does nothing to `/boot/efi`; the pacman hook below does that.

### Image

[`scripts/build-cachyos1160-k73-image.sh`](../../scripts/build-cachyos1160-k73-image.sh)
checks the base download, its partition table and both partition hashes,
then in a chroot without network:

1. replaces `linux-ps5 7.1.7-1` with `7.3.0-2` (`pacman -U`, install script
   skipped) and removes the old `/boot/initrd.img-7.1.7`;
2. installs `mlan.ko` and `moal.ko` in `/usr/lib/modules/7.3.0/updates/ps5-iw620`
   and runs `depmod`;
3. applies the profile below;
4. builds `/boot/initrd.img-7.3.0` with
   [`tools/build_1160_initrd.sh`](tools/build_1160_initrd.sh), the
   cachyos1160 recipe pinned to 7.3.0;
5. mounts the FAT partition at `/boot/efi` and runs the image's own
   `ps5-update-boot-files`, which writes `bzImage` and `initrd.img` the way
   the pacman hook will on the console.

The build stops unless:

- `pacman -Qkk linux-ps5` shows no changed package files apart from the
  module indexes `depmod` rewrote;
- no file of the 7.1.7 package is left behind, other than the Bluetooth
  helper that is put back on purpose;
- every other root filesystem change matches
  [`root-changes.expected`](root-changes.expected) exactly;
- the initramfs holds `amdgpu.ko` for 7.3.0, the eight Cyan Skillfish 2
  firmware files and `ps5-amdgpu.conf`, and none of `mlan`, `moal`,
  `ps5-cpufreq`, `ps5-gpufreq` or IW620 firmware;
- the FAT partition holds exactly `bzImage`, `initrd.img`, `cmdline.txt`,
  `vram.txt` and `kexec.sh`, and they pass the bounded loader check;
- there are no SSH host keys, no `authorized_keys` and no IW620 firmware
  anywhere in the image.

It writes `output/ps5-cachyos1160-k73.img` (12,582,912,000 bytes),
`cachyos1160-k73-root-changes.txt` (the profile changes),
`cachyos1160-k73-kernel-swap.txt` (every path the kernel swap added,
changed or removed) and `cachyos1160-k73-boot-files.txt`.
[`scripts/verify-cachyos1160-k73-image.sh`](../../scripts/verify-cachyos1160-k73-image.sh)
checks a finished image again, read-only.

## Boot files

| File | Source |
|------|--------|
| `bzImage` | `/boot/vmlinuz-7.3.0` from the package; size and hash in the build info |
| `initrd.img` | `/boot/initrd.img-7.3.0`, built by the image build |
| `cmdline.txt` | [`cmdline.txt`](cmdline.txt), the same 118 bytes as cachyos1160 (`aec7a85e…`) |
| `vram.txt` | official image, unchanged (`bc4642fe…`) |
| `kexec.sh` | official image, unchanged (`0f26e099…`) |

The fork's last commit turns the Salina xHCI PHY setup back on for Bluetooth
and notes that this breaks kexec. That does not matter for a cold boot from
the loader, but `kexec.sh` is not expected to work with this kernel.

## If the display does not come up

The local Run 21 image brought up the display with the VCN block enabled, but
video decode was not tested and image 2 has not been booted. If VCN fails to
start, amdgpu can fail to probe. Ethernet and SSH do not depend on it, so they
should still come up: SSH in and save
`sudo dmesg` and the boot report. To boot without VCN, find
`detected ip block number N <vcn_v2_0_0>` in either one and add
`amdgpu.ip_block_mask=` to the end of the line in `cmdline.txt`, set to
0xffffffff with bit N cleared (for N = 6, `amdgpu.ip_block_mask=0xffffffbf`).
amdgpu then skips that block. Do not add `nokaslr`.

## Root filesystem changes

The full list is in [`root-changes.expected`](root-changes.expected). The
cachyos1160 changes carry over: hostname `ps5` (the base image has no
`/etc/hostname`, so no build host name can leak in), `127.0.1.1 ps5`, UTC,
the first-boot marker, the GPU firmware and `ps5-amdgpu.conf`, the fan
helper, display re-detect, the boot report, and `mts` for Ethernet. The
official image's own helpers stay as they are: `grow-rootfs`, `sshd` with
password login, and the `steam` account with autologin into Gaming Mode.

What is different:

- **Kernel.** `linux-ps5 7.3.0-2` replaces 7.1.7. The 7.1.7 package also
  carried a modules-load entry and options for its own Wi-Fi build, the
  `ps5-stage-firmware` helper and `ps5-bt-quiet`; they go with it. The
  profile puts `ps5-bt-quiet` and its unit back unchanged, enabled as before.
- **Wi-Fi.** `mlan.ko` and `moal.ko` in `updates/ps5-iw620`, and the module
  options already used with the 7.1.7 Ubuntu Wi-Fi build in
  `/etc/modprobe.d/ps5-iw620.conf`. That file also has `blacklist moal`, so
  udev does not load `moal` through its PCI alias: it would do that before
  `/boot/efi` is mounted, and without the firmware the probe fails.
  [`ps5-iw620-firmware.service`](files/ps5-iw620-firmware.service) copies
  `/boot/efi/lib/nxp/pcieuartiw620_combo_v1.bin` to
  `/lib/firmware/nxp/` when it is there and exactly 498,108 bytes, then
  loads `moal` by name, which the blacklist does not stop. Only the Wi-Fi
  loader build writes that file, from the console's own firmware; the image
  ships no Wi-Fi firmware. The copy in `/lib/firmware/nxp/` stays, so after
  one boot with the Wi-Fi loader, Wi-Fi also comes up with the other bounded
  build. With no firmware in either place, or on a console without the
  IW620 (PCI `1b4b:2b56`), the service does nothing, `moal` is never loaded
  and Ethernet is unaffected. The firmware helper started as the Ubuntu
  24.04 profile's; here it loads the driver itself instead of reloading it
  after udev.
- **Bluetooth.** The kernel applies a local, hash-pinned follow-up after
  rmux's patch set. It makes the IW620 quirks win over btusb's earlier generic
  class match and defers both interface-number checks until after the quirk
  lookup. This fixes the source-level cause found in Run 21, but the resulting
  CI kernel has not yet been tested on the console.
- **Fan.** `ps5fan.service` is enabled and runs at boot. It asks the ICC for
  the tested maximum fan servo pattern (`3`) as a fixed bring-up setting. It
  is not a temperature-controlled or calibrated fan curve. This is separate
  from the CPU and GPU frequency drivers; neither frequency module loads at
  boot.
- **Frequency drivers.** `ps5-cpufreq.ko` and `ps5-gpufreq.ko` are part of
  the kernel package but have no module alias and are in no modules-load
  file, so nothing loads them at boot. Follow the
  [tester's opt-in procedure](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-2-tester-guide.md)
  only after the baseline test. Load one driver per boot, not both; these are
  alternative commands. For a GPU-driver test:

  ```bash
  sudo modprobe ps5_gpufreq
  ```

  For a CPU-driver test, fully power off first and make a separate baseline
  boot, then run:

  ```bash
  sudo modprobe ps5_cpufreq
  ```

  They talk to the SMU directly. Keep `amdgpu dpm=0` while they are in use,
  since amdgpu's own power management would use the same mailbox. Both were
  loaded manually in Run 21 and the GPU driver lowered the observed idle
  temperature from about 50 C to about 36 C. During a brief game load the
  reported temperature peaked at 84 C; the run ended before thermal
  equilibrium, so that is not enough evidence to load either driver at boot.
  They remain manual and experimental. Unloading one does not put the clocks
  back (`ps5_cpufreq` only unregisters itself), so fully power off rather than
  using rest mode before the next baseline test.
- **Boot report.** [`ps5-boot-report`](files/ps5-boot-report) also records
  every hwmon sensor (k10temp and any GPU sensor), the cpufreq and devfreq
  state, the amdgpu clock files when they exist, whether the frequency drivers
  are loaded, the Wi-Fi state, and the 7.3 kernel messages worth checking
  (frequency drivers, VCN, Salina). With Wi-Fi on, it keeps the tester's
  network out of the copy on the boot partition: the Wi-Fi network names the
  console knows are replaced with `<wifi-name>`, wpa_supplicant's log lines
  are left out and MAC addresses are masked. The console's IP addresses stay
  in, so read the report before posting it.
- **Kernel hold and boot-file updates.** `IgnorePkg = linux-ps5` keeps
  `pacman -Syu` from replacing the kernel. The pacman hook
  [`95-ps5-boot-files.hook`](files/95-ps5-boot-files.hook) runs
  [`ps5-update-boot-files`](files/ps5-update-boot-files) after a transaction
  that installs `linux-ps5`, `mkinitcpio` or `mkinitcpio-busybox`, or changes
  firmware, initcpio hooks, DKMS modules or systemd (the triggers mkinitcpio
  uses for its own images), so an ordinary `pacman -Syu` can run it too. It
  builds a new initramfs and checks it the way the image build does
  (`amdgpu.ko` for the kernel, the eight Cyan Skillfish 2 firmware files and
  `ps5-amdgpu.conf`, and none of `mlan`, `moal`, the frequency drivers or
  IW620 firmware), runs the bounded loader check on it and the kernel, and
  only then replaces `bzImage` and `initrd.img` on `/boot/efi` and
  `/boot/initrd.img-<version>`. If a check fails, nothing is replaced. The
  pair that was on `/boot/efi` is kept as `bzImage.prev` and
  `initrd.img.prev`. Run `sudo ps5-update-boot-files` by hand after editing
  `/etc/mkinitcpio.conf` or `/etc/modprobe.d`.

  A second hook,
  [`05-ps5-boot-files-precheck.hook`](files/05-ps5-boot-files-precheck.hook),
  runs before any transaction that installs or upgrades `linux-ps5` and
  makes pacman refuse it unless `/boot/efi` is mounted read-write with
  `cmdline.txt` on it. Otherwise pacman would replace the modules in
  `/usr/lib/modules` while the boot partition kept the old kernel, and the
  console could come up without Ethernet or SSH. These replace cachyos1160's
  guard hook, which refused any kernel change because its loader needed exact
  sizes.

  If the console stops booting after an update, put the USB drive in another
  computer, open the FAT partition (label `boot`), and rename
  `bzImage.prev` and `initrd.img.prev` to `bzImage` and `initrd.img`. That
  fully undoes an initramfs update (systemd, firmware, mkinitcpio). After a
  `linux-ps5` change it brings back the old kernel, but the root filesystem
  only has the new kernel's modules, so reinstall the old package with
  `pacman -U` as soon as the console is up.

## Login

The account comes from the official image: user `steam`, password `steam`,
passwordless `sudo`. SSH keeps the official image's settings, so password
login works and root login does not. Keep the console on a trusted LAN and
change the password after the first boot with `passwd`. SSH host keys are
generated on the console at first boot.

## Not included

- The 11.60 loader.
- Any Wi-Fi firmware. Each console supplies its own through the Wi-Fi loader
  build.
- `regulatory.db` for Wi-Fi.
- BTF: the published 7.3 config turns `DEBUG_INFO_BTF` off, so `sched_ext`
  schedulers do not work on this kernel. The official image ships none.
