# CachyOS on Linux 7.3.0 for PS5 firmware 11.60

This profile takes the same official `ps5-cachyos` image as
[`cachyos1160`](../cachyos1160/README.md) and replaces its 7.1.7 kernel with
Linux 7.3.0. On top of the cachyos1160 changes it adds the IW620 Wi-Fi driver
built for the new kernel, guarded CPU and GPU frequency-driver startup,
automatic `tty1` session handoff, and safe pacman boot-file updates.

A local pre-release image from this profile booted on hardware in Run 21.
Display, Ethernet, loader-supplied IW620 Wi-Fi and the frequency drivers all
worked in that run. Later live tests on the same system passed Plasma Wi-Fi
joining, internal-Bluetooth DualSense pairing, and the complete Gaming Mode →
Desktop → Gaming Mode handoff. The public Image 3 prerelease contains those
changes. Its exact hosted image has now completed one identity-verified cold
boot on the same CFI-1115B running firmware 11.60. HDMI, wired SSH, Plasma
Wi-Fi, internal-Bluetooth DualSense input and both directions of the session
handoff passed. Keep that result separate from the earlier local image when
reporting tests.

> **Tester warning:** The current download is the public
> [Image 3 prerelease](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-3).
> Its hosted build and structural checks passed, followed by one successful
> exact-image boot on a CFI-1115B. This remains a prerelease with repeated-boot,
> cold-reconnect, coexistence-soak and longer thermal/stability testing still
> open. A 20-second bounded CPU load passed, but it did not establish thermal
> equilibrium. This
> profile is only for retail PS5 firmware 11.60 and requires the
> [bounded 11.60 loader prerelease](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-dma-e820-bounded-run21).
> Use the bounded Wi-Fi ELF and follow the
> [Image 3 tester guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-3-tester-guide.md).
> Flashing overwrites the entire target drive. Keep the default-password system
> on a trusted LAN, change the password immediately, never redistribute the
> console-dumped
> `pcieuartiw620_combo_v1.bin`, and redact reports before posting them.

> **Fan-policy identity:** the published Image 3 archive below still contains
> the legacy servo-pattern `3` helper. Current `main` replaces it with a
> read-back-verified 65 C autoservo target for the next image. The source-tree
> correction is not present in the published Image 3 hash.

> **Wait-online identity:** the published archive also leaves
> `systemd-networkd-wait-online.service` enabled even though NetworkManager owns
> networking. Its two-minute timeout was the only failed unit and did not
> interrupt networking or SSH. Use the tester guide's published-image cleanup;
> the current next-image source removes the stale enablement.

The base is `ps5-cachyos.img.xz` from the ps5-linux/ps5-linux-image release
built on 2026-08-29 from upstream commit `52db0a4`
(sha256 `9a29ca88c408cd290c19f4693f764251aab5698bb55c9f38fbf06c2764f21db1`).

## Current Image 3 prerelease

| Item | Value |
|------|-------|
| Release | [`cachyos1160-k73-image-3`](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-3), public prerelease |
| Source commit | `16795eb85830dc32f712e44e9e0da28f7874b317` |
| Kernel package | `linux-ps5 7.3.0-3` |
| CI | [workflow `39521098451`](https://github.com/gzimbric/ps5-linux-image/actions/runs/39521098451): success |
| Release archive | one `ps5-cachyos1160-k73.img.xz`; 1,943,937,164 bytes; never split |
| Compressed SHA-256 | `9e224aeb607ba050dd520ce32d50989d27013f7da2889ce7ed1ce247fea71e3c` |
| Raw image | 12,582,912,000 bytes; SHA-256 `25a0ef68a85dbe6d976b5a97faaa323b64c4efbe1b220003772f25a264eb34a8` |
| `bzImage` | 11,613,184 bytes; SHA-256 `945a4f2a03c4771313e466dccfb8272e0345cf7d143516a36a0bc75b2b219d0a` |
| `initrd.img` | 51,899,412 bytes; SHA-256 `912600c22a203a744d4d44fcd4b5caacd86ea8b0c3ef8202ed9c0ff2ba146dd0` |
| `cmdline.txt` | 118 bytes; SHA-256 `aec7a85e9ebcf36e4bdaeb89242b898e17817acd40c16db57a3bb9c3117b1da8` |
| `vram.txt` | 11 bytes; SHA-256 `bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0` |
| `kexec.sh` | 136 bytes; SHA-256 `0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52` |
| Hardware status | One identity-verified cold boot on a CFI-1115B running 11.60; HDMI, wired SSH, Plasma Wi-Fi, internal-Bluetooth DualSense input, both session directions and a short bounded CPU load passed |

The downloaded archive, GitHub digest, checksum manifest and XZ round trip
were checked. The flashed device readback matched raw image SHA-256
`25a0ef68…`, and the running console matched all five published boot-file
identities. That closes the first exact-artifact boot gate. The local Run 21
image and its later live changes remain separate supporting evidence.

For comparison, the local hardware-test image was built from
`f7d6fbd9d630cddaceb83f3b861869d4453af8ca`; its 12,582,912,000-byte raw
image has SHA-256
`5a904e02f6a2908be91054b7b73ebf6f891fece0edc1a88f2f9d60264d7556d4`.
The final live-tested session files were the 1,866-byte
`gamescope-session-ps5` (`d68c1f3a9014dd2db00681b5434f6e951bc6d4ebdebc48ec77fc154dbf2fc687`)
and the 3,736-byte `steamos-session-select`
(`1d099eeacc19bbf575e5a636fc81087a46f72af64390172e437372b493bde1c1`).
The public image contains those session-file identities and the same boot-file
identities listed above. Its separate exact-image cold-boot result is recorded
in the tester guide linked below.

## Previous Image 2 reference

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
raw image hash were checked after the run. The current release workflow stops
before creating or refreshing a draft if the compressed image is 2 GiB or
larger. A completed build or verifier pass, and publication of a prerelease,
provide only software and release validation; none of them is a console boot.

Compared with the local image that booted in Run 21, image 2:

- applies the earlier hash-pinned IW620 Bluetooth quirk-ordering follow-up
  (SHA-256 `54d7addbb4cd95c943f9a4485229ac5516ad08ebe0f4aa02fd72cf33298fa0a2`)
  and records the package revision as `7.3.0-2`;
- blacklists `moal`'s automatic PCI-alias load, copies the console-supplied
  firmware first, and then loads the driver explicitly; and
- keeps the already-tested rmux kernel patch set, bounded-loader contract,
  VCN setup, and manual frequency-driver policy unchanged.

Neither image-2 fix has been tested on the console. Steam's **Switch to
Desktop** action and joining Wi-Fi from the KDE network menu also remain
unresolved in image 2; Run 21 used a manual session switch and `sudo nmcli`.

If image 2 hangs after **Switch to Desktop**, connect over SSH or open another
TTY with `Ctrl+Alt+F2`, then run:

```bash
sudo steamos-session-select plasma
sudo systemctl restart getty@tty1.service
```

Try `Ctrl+Alt+F1` if HDMI does not switch back to the first TTY. This is the
same handoff that worked manually in Run 21. Do not use Linux suspend or Rest
Mode as a recovery step; fully power off before another loader run.

## What Image 3 changes

Image 3 opens Plasma on the first boot so Wi-Fi can be configured before
Steam's one-time bootstrap, then uses Gaming Mode as the normal default. The
first Gaming Mode launch needs internet access. It also integrates the parts
that were manual in Run 21:

- **Wi-Fi:** pins `ps5-linux/ps5-linux-mwifiex` commit
  `4bce848dd098bf74fbafd0078463da3d9f0d7f80`, including its current HE
  capability and transmit-path fixes, while retaining this profile's Linux
  7.3 compatibility patch. The driver keeps `auto_fw_reload=0`, and
  NetworkManager disables scan MAC randomization, keeps the permanent address
  and sets `wifi.powersave=2`. That configuration passed a Plasma GUI join,
  DHCP and traffic explicitly bound to Wi-Fi on the exact hosted Image 3. The
  `sudo nmcli --ask device wifi connect <wifi-name>` remains the fallback if
  the KDE network menu does not join. After Gaming Mode returned to Plasma,
  Polkit evaluated KDE's returned helpers outside the active seat and showed
  **System policy prevents control of network connections**. The tester guide's
  targeted action allowlist restored unprivileged Wi-Fi rescans; it is a live
  hotfix, not a file in the published Image 3 hash. The base image also leaves
  `systemd-networkd-wait-online.service` enabled even though NetworkManager owns
  the network. Its two-minute timeout is a stale service, not an IW620 or
  Ethernet failure; the tester guide includes the published-image cleanup.
- **Bluetooth:** replaces the image-2 follow-up with the exact
  `ps5-btusb-quirks-fix.patch` asset from Bazzite Deck v1.0.3, pinned at
  SHA-256 `c01bdcc134f25a86825f2824d12a82da02db18e7b1940db722223b0c4611eed8`.
  It is rebuilt into this kernel rather than copying Bazzite's prebuilt
  `btusb.ko`. The image also selects the working Bazzite BlueZ path:
  `AlwaysPairable=true`, `JustWorksRepairing=always`, `UserspaceHID=true`,
  and explicit pairing timeout, controller mode, privacy and auto-enable
  values. On the exact hosted image a DualSense was discovered through the
  internal adapter, paired, bonded, trusted, automatically reconnected and
  exposed controller, motion and touchpad input through `hid-playstation`,
  with no USB controller present. A cold-boot reconnect and long
  Wi-Fi/Bluetooth coexistence test remain open.
- **Fan:** published Image 3 requests legacy servo pattern `3`; on the tested
  console that left the autoservo target at 86 C and did not prove maximum
  speed. The next-build source on `main` instead sets 65 C before the
  performance policy and fails the service if readback does not match. Apply
  the hotfix below when testing the published archive.
- **Performance:** after the fan service succeeds,
  `ps5-performance.service` verifies `amdgpu dpm=0`, loads `ps5_gpufreq`
  before `ps5_cpufreq`, checks GPU `simple_ondemand` and CPU `schedutil`, and
  keeps CPU boost off. Never unload either module because unloading does not
  restore the clocks. To opt out, create an empty
  `/boot/efi/disable-ps5-performance` file and fully power off before the next
  boot.
- **Desktop handoff:** launches Gaming Mode as
  `steam -steamos -gamepadui`. On the 11.60 test console Steam then used its
  built-in legacy path and invoked `steamos-session-select plasma`; two
  consecutive attempts reached Plasma. No custom SteamOS Manager service is
  installed. Return to Gaming Mode stops `graphical-session.target`, the
  systemd owner of KWin and plasmashell on this image, before the tty launcher
  resumes into Gamescope. **Switch to Desktop can take a few seconds.** The
  clean local pass took about 2.4 seconds, while an earlier cleanup-heavy pass
  took about 27 seconds. Wait before clicking it again or power-cycling.
- **Sleep:** Linux sleep, suspend, hibernate, hybrid sleep and
  suspend-then-hibernate targets are masked. GameOS Rest Mode and wake remain
  only the carrier used to launch the loader. Once Linux is running, shut down
  fully between test boots.

Image 3 remains a prerelease. Its exact hosted-CI archive has completed one of
the requested three to five cold boots, plus Plasma Wi-Fi joining, DualSense
pairing/input, startup frequency policy and both directions of the automatic
session handoff. With the per-boot 65 C fan-target hotfix active, a 20-second,
16-worker CPU load held the CPU near 3.19 GHz, peaked at 47 C and returned to
37 C three seconds after the load ended. Cold-boot reconnect, a 60-minute
concurrent Wi-Fi and Bluetooth run, a longer thermal/stability run,
performance opt-out, VCN video decode, storage integrity and broader hardware
coverage remain open. The
[Image 3 tester guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-3-tester-guide.md)
contains the exact release hashes, boot steps and result checklist.

## Published Image 3 fan hotfix

After each boot of the published Image 3 archive, set and verify a 65 C
autoservo target:

```bash
echo 65 | sudo tee /sys/bus/platform/devices/ps5-fan/target_temp
cat /sys/bus/platform/devices/ps5-fan/target_temp
```

The kernel's automatic controller remains active. Use 40-80 C; lower values
cool more aggressively. On the tested CFI-1115B, a separate fan-response check
made the fan clearly audible and reduced Tctl from 35.75 C to about 33 C in 28
seconds. A later 20-second, 16-worker CPU load with the 65 C target and
`schedutil` active held the CPU near 3.19 GHz, peaked at 47 C and returned to
37 C three seconds after the load ended. That short check passed, but it does
not establish thermal equilibrium or long-duration stability. Linux exposes no
chassis-fan RPM/tachometer value.

Current `main` makes the 65 C policy persistent for the next image through
`/etc/default/ps5-fan`, verifies immediate readback, removes the misleading
`ps5_fan_max` helper and records the active target in `ps5-boot-report.txt`.
Those files are not present in the published Image 3 identity above.

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

The Image 3 profile also applies one separate, byte-for-byte and hash-checked
kernel follow-up,
[`ps5-btusb-iw620-quirks.patch`](kernel/ps5-btusb-iw620-quirks.patch). It
makes the IW620-specific `quirks_table` match take precedence over the generic
Bluetooth class match and performs the IW620 interface restriction after that
lookup. The file is the exact `ps5-btusb-quirks-fix.patch` release asset from
[VivaLaVent's Bazzite Deck v1.0.3](https://github.com/VivaLaVent/ps5-bazzite-deck/releases/tag/v1.0.3),
SHA-256 `c01bdcc134f25a86825f2824d12a82da02db18e7b1940db722223b0c4611eed8`.
It is not part of rmux's pinned patch, so the builder applies it afterward and
compiles a matching `btusb.ko`; modules from another image must not be copied
over it.

Bazzite reports a paired DualSense on a CFI-10xx PS5 running firmware 13.60
with Linux 7.3 after this correction. The exact Bazzite base used by that
release is OCI digest
`sha256:96301a1520b5bb63db95640896300c10ae3b1fcf8bf10681af154514395e1634`,
built from Bazzite revision
[`2fab72c`](https://github.com/ublue-os/bazzite/tree/2fab72cbc9a3257d80c607e173f22527aea3b39b).
It sets `AlwaysPairable=true`, `JustWorksRepairing=always` and
`UserspaceHID=true`; Image 3 carries those active values and makes the other
effective BlueZ defaults explicit. That is useful source-level evidence, but
it is not an 11.60 result for the exact hosted artifact. The current Image 3
prerelease contains this correction; Image 2 contains the earlier,
non-identical follow-up.

The out-of-tree Wi-Fi modules are a separate driver build. Image 3 pins
`ps5-linux/ps5-linux-mwifiex` at
`4bce848dd098bf74fbafd0078463da3d9f0d7f80`, applies its relevant patch series
and then this profile's hash-pinned Linux 7.3 compatibility patch. The Linux
7.2-only compatibility patch is deliberately excluded because this profile's
patch handles the changed 7.3 interfaces. None of these patches alters rmux's
kernel patch set.

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
to one `.img.xz` and creates or safely refreshes the draft for the requested
tag. It never creates numbered parts. Full image builds start only by manual
workflow dispatch. Publishing the draft creates the tag and does not start a
second build; an already published release is never overwritten. A `main`
push that changes a kernel input only primes the exact kernel-bundle cache.
If the compressed file is 2 GiB or larger, the workflow fails before the
release step. Compilation, assembly, compression and uploading all stay on
the hosted runners; a Mac is not used to build or relay the artifact.

### Kernel

[`scripts/build-linux-ps5-k73.sh`](../../scripts/build-linux-ps5-k73.sh)
fetches each source at a pinned commit:

| Source | Commit |
|--------|--------|
| Linux, tag `v7.3` | `c03c1a14507dfaf8b856c2608f9ac216021fc222` |
| rmuxnet/ps5-linux-patches-1 | `36f173f39e5e76c00c4e366a7b909f33bc665ad5` |
| ps5-linux/ps5-linux-mwifiex | `4bce848dd098bf74fbafd0078463da3d9f0d7f80` |
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
  (`c01bdcc…`);
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
objtool on. It applies seven hash-checked patches from the pinned
ps5-linux/ps5-linux-mwifiex commit: the original driver changes, bounded
command recovery, Linux 7.1 compatibility, bounded RTNL waiting, corrected HE
capabilities, a 128-byte transmit minimum and transmit-priority normalization.
It deliberately skips that repository's Linux 7.2-only compatibility patch,
then applies
[`kernel/ps5-iw620-kernel73-compat.patch`](kernel/ps5-iw620-kernel73-compat.patch)
for the Linux 7.3 interfaces. The build stops on any compiler, objtool or
modpost warning, and checks `.return_sites`, the vermagic and the IW620 PCI
alias. Passing those gates does not replace an exact-image hardware test.

[`scripts/package-linux-ps5-k73.sh`](../../scripts/package-linux-ps5-k73.sh)
packages the kernel as `linux-ps5 7.3.0-3` for pacman, laid out like the
upstream package (kernel, modules, build headers, UAPI headers) plus AMD's
licence for `ps5_vcn.bin` in `/usr/share/licenses/linux-ps5`. Its install
script does nothing to `/boot/efi`; the pacman hook below does that.

### Image

[`scripts/build-cachyos1160-k73-image.sh`](../../scripts/build-cachyos1160-k73-image.sh)
checks the base download, its partition table and both partition hashes,
then in a chroot without network:

1. replaces `linux-ps5 7.1.7-1` with `7.3.0-3` (`pacman -U`, install script
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

The exact published Image 3 artifact has now brought up the display once with
the VCN block enabled. Video decode was not tested. If VCN fails to start on a
later console or display, amdgpu can fail to probe.
Ethernet and SSH do not depend on it, so they should still come up: SSH in and
save
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
service ordering, display re-detect, the boot report, and `mts` for Ethernet. The
official image's `grow-rootfs`, `sshd` with password login, and `steam`
autologin on `tty1` remain in place. This profile changes the initial session token
to Plasma, replaces the session-selection helper needed for the bounded
handoff, and replaces the Gamescope launcher so Steam starts with the tested
`-steamos -gamepadui` flags. Plasma resets the one-shot token to Gaming Mode
when it exits.

What is different:

- **Kernel.** `linux-ps5 7.3.0-3` replaces 7.1.7. The 7.1.7 package also
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
  after udev. `/etc/NetworkManager/conf.d/20-ps5-iw620.conf` disables scan MAC
  randomization, keeps the adapter on its permanent address and sets
  `wifi.powersave=2`; the module options keep `auto_fw_reload=0`. On the tested
  CFI-1115B, this stopped KDE from selecting an access-point object that the
  IW620 scan cycle had already invalidated. A WPA3-SAE network then joined from
  the normal Plasma menu, obtained DHCP and completed an HTTPS request over
  Wi-Fi.
- **Bluetooth.** The kernel applies the exact, hash-pinned Bazzite Deck v1.0.3
  source patch after rmux's patch set. It makes the IW620 quirks win over
  btusb's earlier generic class match and applies the IW620 interface
  restriction after the quirk lookup. The image rebuilds the module for this
  kernel; it never copies Bazzite's binary. `/etc/bluetooth/main.conf` keeps
  the adapter pairable, permits the DualSense Just-Works repair and pins the
  same controller, privacy and auto-enable behavior used by the working
  Bazzite image. `/etc/bluetooth/input.conf` explicitly keeps
  `UserspaceHID=true`; `uhid` and `hid-playstation` are built for this kernel.
  This path passed with a DualSense on the local 11.60 system. The exact
  hosted image then independently passed discovery, BlueZ pairing through
  `bluetoothctl`, bonding, trust, automatic reconnect, `hid-playstation`
  registration and raw
  input capture. Cold-boot reconnect and a long coexistence run remain open.
- **Fan.** `ps5fan.service` is enabled and runs before the performance service.
  It leaves the ICC's automatic thermal controller active, sets its target to
  65 C and checks the value by reading the kernel interface back. To choose a
  different balance, edit `PS5_FAN_TARGET_C` in `/etc/default/ps5-fan` (40-80
  C) and restart `ps5fan.service`; lower values cool more aggressively. The
  tested CFI-1115B accepted target changes and audibly ramped during a separate
  fan-response check. Linux exposes temperature and target data here, but no
  chassis-fan RPM/tachometer reading.
- **Frequency drivers.** `ps5-cpufreq.ko` and `ps5-gpufreq.ko` are part of
  the kernel package but remain absent from the initramfs and generic
  modules-load files. This profile enables `ps5-performance.service` after the fan
  service succeeds. It requires `amdgpu dpm=0`, loads the GPU module before
  the CPU module, verifies GPU governor `simple_ondemand` and CPU governor
  `schedutil`, and disables CPU boost. Both were exercised manually in Run
  21, but the 84 C peak occurred before thermal equilibrium. On the exact
  public Image 3 artifact, automatic startup passed a 20-second, 16-worker CPU
  load after the fan target was corrected to 65 C: the CPU stayed near 3.19 GHz
  and peaked at 47 C. That is a bounded diagnostic, not a thermal-equilibrium or
  long-duration stability result. Do not use `rmmod` as a rollback because
  unloading does not restore the clocks. Create an empty
  `/boot/efi/disable-ps5-performance` file and fully power off to skip the
  startup policy on the next boot.
- **Desktop handoff.** First boot opens Plasma so the tester can configure a
  network; Steam's first Gaming Mode bootstrap needs that connection. After
  that one-shot desktop session, Gaming Mode is the default. The Gamescope
  launcher starts `steam -steamos -gamepadui`; it deliberately does not use
  `-steamos3`, which would enable atomic-OS update behavior that CachyOS cannot
  provide. On the 11.60 test console, Steam logged that no supported SteamOS
  Manager was present, selected its built-in legacy path, ran
  `steamos-session-select plasma`, and reached Plasma twice. The image does not
  install a partial SteamOS Manager replacement. On return to Gaming Mode the
  selector stops `graphical-session.target`, the systemd owner of KWin and
  plasmashell on this image, then the existing tty launcher resumes into
  Gamescope without a later process kill that could hit the new session.
  **Switch to Desktop may take a few seconds:** one clean pass took about 2.4
  seconds and an earlier cleanup-heavy pass took about 27 seconds. Wait before
  clicking it again. The exact hosted Image 3 artifact passed both directions
  of the round trip: the first Gaming Mode launch installed Steam's client
  update before showing the SteamOS interface, then **Switch to Desktop**
  returned to KWin and Plasma without compositor overlap. The handoff passed,
  but the returned desktop needs the published-image Polkit hotfix described in
  the tester guide before KDE can control NetworkManager normally.
- **Sleep.** `sleep.target`, `suspend.target`, `hibernate.target`,
  `hybrid-sleep.target` and `suspend-then-hibernate.target` are masked because
  Linux suspend is unsupported. GameOS Rest Mode and wake remain the loader's
  launch carrier only; fully power off after Linux testing.
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

## DualSense pairing

Open KDE's Bluetooth settings and keep the pairing window open while the pad
is blinking (hold **Create + PS**). For a terminal-only test, register an agent
and keep the adapter pairable before starting the pair:

```text
bluetoothctl
power on
agent on
default-agent
pairable on
scan on
pair <controller-mac>
trust <controller-mac>
connect <controller-mac>
```

Do not install `disable_ertm=1`, replace `btusb.ko`, or switch this image to
the kernel-HID workaround before the exact Bazzite-compatible path is tested.
The boot report records the active BlueZ policy and relevant modules.

## Not included

- The 11.60 loader.
- Any Wi-Fi firmware. Each console supplies its own through the Wi-Fi loader
  build.
- `regulatory.db` for Wi-Fi.
- BTF: the published 7.3 config turns `DEBUG_INFO_BTF` off, so `sched_ext`
  schedulers do not work on this kernel. The official image ships none.
