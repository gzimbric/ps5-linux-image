# PS5 Linux Image Builder

Builds bootable Linux USB images for PlayStation 5 using Docker containers. This fork's default `main` branch includes a public Ubuntu 24.04 profile that enforces the boot-critical envelope of the Run 16 control image that booted successfully on PS5 firmware 11.60, while retaining the upstream Ubuntu 26.04, Arch, CachyOS, and Fedora profiles.

## Ubuntu 24.04 firmware 11.60 tested envelope

Use the two-stage reproduction workflow:

```bash
./build_image.sh --clean --kernel-only --distro ubuntu2404
./build_image.sh --distro ubuntu2404
```

The first command starts from clean caches and builds and validates the pinned kernel package. The second intentionally reuses that verified package while assembling a fresh Ubuntu root filesystem and raw image. Image assembly audits the temporary raw image before publishing `output/ps5-ubuntu2404.img`.

The source-clean kernel/package build and fresh image assembly from this public profile passed their software validation gates. That does not constitute a PS5 hardware boot of a fresh rebuild. The hardware result remains the separate Run 16 control image, which booted on firmware 11.60. A single `./build_image.sh --clean --distro ubuntu2404` run from an empty cache has not been validated and is not claimed here.

The successful control image was 16,777,216,000 bytes (16,000 MiB), which is the default for this profile. The matching firmware 11.60 USB and boot procedure is documented in the [porting guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/ubuntu2404-run16-usb.md).

The repository holds only source and build instructions. Test images built by CI are covered in [Prebuilt test image](#prebuilt-test-image). Review the licenses of the inherited builder and installed distribution packages before redistributing a built image.

### Prebuilt test image

The [`Ubuntu 24.04 11.60 image`](.github/workflows/ubuntu2404-1160-image.yml) workflow runs the two commands above on a GitHub-hosted x86_64 runner. It then runs both verifiers, checks the five FAT boot files against the [tested boot envelope](#tested-boot-envelope), and attaches the compressed image to a draft release. Testers can only see it after the draft has been reviewed and published. The workflow is started by hand from the Actions tab, or by pushing a tag that matches `ubuntu2404-1160-image-*`.

A CI image is a rebuild, so its raw-image hash will not match the Run 16 control or any other build. The parts that must match are `bzImage`, `cmdline.txt`, `vram.txt` and `kexec.sh`, byte for byte, and `initrd.img` at exactly 54,376,639 bytes. The build fails if any of them, or either verifier, fails. Every release lists the hashes for its own build in `SHA256SUMS` and `build-info.txt`.

Download `ps5-ubuntu2404.img.xz` and `SHA256SUMS` from the release into one folder, then:

```bash
sha256sum -c --ignore-missing SHA256SUMS
xz -dc ps5-ubuntu2404.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

On macOS, check with `shasum -a 256 -c --ignore-missing SHA256SUMS` and flash to `/dev/rdiskN`. balenaEtcher and Raspberry Pi Imager can flash the `.img.xz` without unpacking it first. To check the decompressed image itself, compare `xz -dc ps5-ubuntu2404.img.xz | sha256sum` with the `ps5-ubuntu2404.img` line in `SHA256SUMS`.

Every release uses one `ps5-ubuntu2404.img.xz`. The workflow compresses at
XZ level 9 and stops before creating a release if the result reaches GitHub's
2 GiB per-file limit; it never publishes numbered parts.

The image is 16,777,216,000 bytes, which is more than many 16 GB USB drives hold. Use a 32 GB or larger drive. The root partition grows to fill the drive on first boot. The firmware 11.60 loader is not part of the image or the release.

### First login and SSH policy

The sanitized public profile intentionally contains no preinstalled SSH key.
Its initial account is:

- Username: `ps5`
- Password: `ubuntu`
- GNOME desktop: automatic login enabled
- SSH: password login enabled only for `ps5`; root login, empty passwords, and keyboard-interactive authentication are disabled
- `sudo`: passwordless for the `ps5` account

**Change the public default password immediately after the first local or SSH login:**

```bash
passwd
```

Until that is done, use the image only on a trusted network. For key-only SSH, add your public key to `~/.ssh/authorized_keys`, confirm that key login works in a second session, then set `PasswordAuthentication no` in `/etc/ssh/sshd_config.d/10-ps5-control.conf` and restart `ssh.service`.

The hardware-tested control image used key-only SSH. Password access is the documented, sanitized public-profile difference; no private control key, public key, or key hash is included here. This account change does not alter the kernel, command line, VRAM setting, firmware payloads, or loader-sized initramfs envelope.

Each installation generates its own SSH host keys on first boot. No SSH host private key is baked into the image.

### Hardware notes

- Use Ethernet for the current profile. The PS5's onboard IW620 Wi-Fi modules are deliberately omitted and blacklisted because the successful control package did not contain a working IW620 driver and firmware combination.
- Run 17 later brought up the onboard Wi-Fi on an installed copy of this image by adding NXP `mlan`/`moal` modules built for this exact kernel and the console's own firmware. The Ubuntu profile was not changed for that test, and images built from it still omit and blacklist the driver. The build, firmware location, and load scripts are in the porting repository's [Wi-Fi guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/ubuntu2404-wifi.md).
- The Ubuntu profile still uses the earlier servo-pattern `3` helper. Its ICC request was accepted, but it has no RPM readback and must not be described as proven maximum speed. CachyOS 7.3 Image 4, documented below, replaces that helper with a read-back-verified autoservo target; the Ubuntu migration still needs its own image test.
- The boot-report service writes `ps5-boot-report.txt` to the FAT boot partition for systems without UART. That report can contain network addresses, MAC addresses, connection names, and journal identifiers. Review and redact it before posting it publicly.

### Tested boot envelope

The Ubuntu package archive, filesystem metadata, password salt, and build timestamps can change, so rebuilding does **not** produce a bit-identical root filesystem or disk image. The builder instead stops unless these boot-critical invariants match the firmware 11.60 test:

| EFI file | Enforced size | Enforced SHA-256 |
|----------|--------------:|-----------------|
| `bzImage` | 12,702,720 bytes | `11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde` |
| `cmdline.txt` | 121 bytes | `6b3c09112fe049d3cbeada65fb3c82bb0f5fcaddce6c0709051df3d9f5a79f6d` |
| `vram.txt` | 11 bytes | `bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0` |
| `kexec.sh` | 136 bytes | `0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52` |
| `initrd.img` | 54,376,639 bytes | content-dependent; see below |

The rootfs initramfs is verified as a valid archive no larger than 54,376,639 bytes. Its exact bytes are copied to the EFI partition and the EFI copy is zero-padded to that tested loader size. The build also pins and checks the eight Cyan Skillfish 2 firmware payloads embedded in the initramfs.

For the successful test, the unpadded initramfs was 50,803,483 bytes with SHA-256 `996bc02a64404bc84d06c8df0c4143b66932d8af8549f39c82c71677fdec58c9`; the padded EFI copy had SHA-256 `2eef0352879e091083450b799c75514a450f4110cbc747f640962fdde2dc06c8`. Those two hashes are reference values, not rebuild requirements, because initramfs generation is not bit-reproducible.

The firmware 11.60 validation used a 169,872-byte loader ELF with SHA-256 `422b87ec39ca0edfce8dddd609c2eff1cc7adcb2732b7909b76fafbd60dd2336`. This repository builds the USB image, not the firmware-specific loader.

### Exact kernel-build controls

For `ubuntu2404`, the build forces `linux/amd64`, uses the Debian Trixie image manifest `sha256:bcf83fd8af414eda0c0a99d25a4e61dedd88e7aac7f7bc519d04555ff0c40ec5`, and installs build dependencies from the Debian and Debian Security snapshots dated `20261017T000000Z`. Other profiles retain their existing host-native builder behavior. The exact path also enforces:

- patch-set commit `56922cf9af91142cdcf7d54cbcfb3d46bdfb397a` (tag `kernel-7.1.7-56922cf`)
- `x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0`
- `GNU ld (GNU Binutils for Debian) 2.44`
- `pahole v1.30`
- the complete installed-package manifest hash `7fe661a35d6f87ce22beacbd162880155be4b848e8668d8c66ef2e6f2923583f`
- 12 build jobs, disabled ccache, a fixed Kbuild user/host, the tested date-shim behavior with `KBUILD_BUILD_TIMESTAMP` unset for the kernel, and separate fixed timestamps for the embedded cpio and `kheaders.ko`
- exact hashes for `.config`, the embedded cpio, `bzImage`, `System.map`, the 516 runtime modules, and the stripped `mts.ko`, plus a content check of the embedded `kheaders` archive
- the Run 16 control's image-and-in-tree-modules-only Debian package shape, with no packaged headers or out-of-tree IW620 modules and without replacing Ubuntu's `linux-libc-dev`

The installed-package manifest identifies the complete builder package/version set; it does not by itself prove that an arbitrary recipe change is harmless. The output validator separately checks the semantic Debian package tree, the complete module set, and the embedded kernel-header contents. The ordinary distro builder can still add the out-of-tree IW620 driver, but the exact Ubuntu 24.04 path deliberately stops before that generalized step because the hardware-tested control package did not contain those modules. Ubuntu rootfs packages and filesystem metadata can still vary, so the package/rootfs as a whole is not bit-reproducible even though the boot-critical kernel artifacts are checked.

The control image's `kheaders.ko` retained 142 incidental source/build mtimes and had SHA-256 `bc3c9cb46360fa779c2abac7b44ce0cfa788ec848d320306ffca09ef86a528bb`. The public build normalizes all embedded archive mtimes to `2026-08-29 18:01:15 UTC` and pins the resulting module SHA-256 `84565f3ecaa2c5a05fa49d1c37034a999fbf7b672faff85f8a444d1cbac23dd3`. Both contain the same 7,069 regular header files with content manifest `6212fdada4054c4bb2bec76e45fb04602c65cf5bec372bea380e3a249b083f75`; their module code and BTF sections are also identical. The whole-file difference is archive metadata and its resulting compression/layout, not header content.

To validate an already built exact kernel package:

```bash
./scripts/verify-ubuntu2404-kernel-deb.sh \
  linux-bin/ubuntu2404/linux-ps5_7.1.7_amd64.deb
```

Ubuntu 24.04 image assembly automatically runs the complete raw-image audit against the temporary image. If the audit fails, no final image is published. To rerun the same audit manually before flashing:

```bash
./scripts/verify-ubuntu2404-boot.sh \
  --image output/ps5-ubuntu2404.img
```

This opens the image through a read-only loop device in the already-built
`ps5-image-builder` container, mounts both filesystems read-only, and checks the
GPT layout, labels, boot envelope, installed kernel tree, enabled services,
default account, SSH-key hygiene, and recipe marker. The firmware-specific
loader is delivered separately rather than stored in the image; when you have
that ELF, include `--loader /path/to/loader.elf` to check its tested size and
hash as part of the same run.

After flashing, mount the FAT32 `boot` partition and compare its files with the enforced envelope:

```bash
./scripts/verify-ubuntu2404-boot.sh /path/to/mounted/boot
```

If the ext4 root partition is also mounted, pass it as the second argument to verify that the EFI initramfs begins with the rootfs initramfs byte-for-byte:

```bash
./scripts/verify-ubuntu2404-boot.sh /path/to/mounted/boot /path/to/mounted/root
```

## CachyOS for 11.60

The `cachyos1160` profile applies the changes the official `ps5-cachyos` image (Steam Gaming Mode and KDE Plasma) needs to boot on firmware 11.60. It does not rebuild the kernel or the root filesystem. The script downloads the official image, rebuilds the initramfs from the image's own packages, writes the 11.60 boot files, and applies a short, pinned list of root changes. It must run as root on Linux x86_64:

```bash
sudo ./scripts/build-cachyos1160-image.sh
```

The output is `output/ps5-cachyos1160.img` (12,582,912,000 bytes) plus `output/cachyos1160-root-changes.txt`, which lists every root path the build added, changed or removed. The [profile README](distros/cachyos1160/README.md) explains each change, the pinned boot files, and what the public image leaves out compared with the private test image. That private image, with the same boot files, booted on an 11.60 console. An image built from this public profile has not been booted on hardware yet.

The [`CachyOS 11.60 image`](.github/workflows/cachyos1160-image.yml) workflow runs the same script on a GitHub-hosted x86_64 runner, checks the five FAT boot files again, and attaches the compressed image to a draft release. It runs when a tag matching `cachyos1160-image-*` is pushed. It can also be started by hand from the Actions tab once the workflow is on the default branch.

## CachyOS 7.3 for 11.60

> **Image 3 is a public tester prerelease for retail PS5 firmware 11.60.**
> The hosted build and structural checks passed. The exact downloadable image
> has now completed one identity-verified cold boot on a CFI-1115B running
> firmware 11.60, with visible HDMI and authenticated wired SSH. Wi-Fi,
> internal-Bluetooth DualSense input and both directions of the Plasma/Gaming
> Mode handoff also passed during that boot. A 20-second bounded CPU load also
> passed after applying the documented 65 C fan-target hotfix. Repeated boots,
> cold reconnect, coexistence soak and longer thermal/stability testing remain
> open.

### Start here

- Download the single archive from the
  [Image 3 prerelease](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-3)
  and follow the
  [Image 3 tester guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-3-tester-guide.md).
- Use `ps5-linux-loader-1160-dma-e820-bounded-wifi.elf` from the
  [matching loader prerelease](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-dma-e820-bounded-run21).
  Its SHA-256 is
  `e9fe6469943e97a635eccd3f674e55876b56cd1bbd69023eee3af4acea3a1b5f`.
- Login is `steam` / `steam`. Change the password and keep the system on a
  trusted network until you do.
- The first boot opens Plasma so networking can be configured before Steam's
  first Gaming Mode setup. Use the desktop shortcut to enter Gaming Mode.
- **Switch to Desktop is not instant.** A clean local pass took about 2.4
  seconds; an earlier cleanup-heavy pass took about 27 seconds. Wait before
  clicking again or power-cycling.
- After the exact-image return to Plasma, KDE displayed **System policy
  prevents control of network connections**. The
  [tester guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-3-tester-guide.md#network-control-after-switching-sessions)
  includes the targeted `steam`/NetworkManager Polkit hotfix. It is not part of
  the published Image 3 hash.
- Published Image 3 also leaves `systemd-networkd-wait-online` enabled even
  though NetworkManager owns the network. Its two-minute timeout was the only
  failed unit and did not interrupt networking or SSH. The tester guide removes
  the unused enablement and clears the failed state. Image 4 masks the unit
  before first boot so the vendor preset cannot enable it; that correction is
  not part of the published Image 3 hash.
- Linux sleep and hibernate are disabled. Fully shut Linux down between loader
  attempts.

Flashing erases the selected drive. Never redistribute the console-dumped
`pcieuartiw620_combo_v1.bin`, and review `ps5-boot-report.txt` and `dmesg`
before posting them because they can contain network details.

### What Image 3 includes

| Area | Included behavior |
|------|-------------------|
| Kernel | `linux-ps5 7.3.0-3`, mainline v7.3 plus rmux's pinned PS5 patch set |
| Wi-Fi | Updated IW620 driver, staged console firmware, stable NetworkManager MAC behavior and Wi-Fi power saving disabled |
| Bluetooth | The hash-pinned Bazzite Deck v1.0.3 IW620 `btusb` source correction, rebuilt for this kernel, plus the matching BlueZ policy |
| CPU/GPU clocks | Guarded GPU-then-CPU scaling at startup; GPU `simple_ondemand`, CPU `schedutil`, CPU boost off |
| Cooling | Legacy servo-pattern `3` request before the performance policy; accepted by ICC, but not proof of maximum speed or RPM |
| Sessions | Plasma on first boot, Steam with `-steamos -gamepadui`, and working legacy session-selector integration |
| Sleep | Unsupported Linux sleep, suspend and hibernate targets masked |

#### Image 3 fan hotfix and Image 4 correction

The published Image 3 hashes below contain the legacy pattern helper. On the
tested CFI-1115B it left the autoservo target at 86 C, so the helper must not
be described as forcing maximum RPM. For an immediate, non-persistent Image 3
hotfix after each boot, set and verify a 65 C target:

```bash
echo 65 | sudo tee /sys/bus/platform/devices/ps5-fan/target_temp
cat /sys/bus/platform/devices/ps5-fan/target_temp
```

The supported public range is 40-80 C; lower values cool more aggressively.
The persistent correction shipped in [Image 4](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-4): it
removes the legacy helper, applies 65 C at boot, checks the controller readback
and records the target in the boot report. That change is **not** part of the
published Image 3 archive or hashes. Image 4 has since booted on the same
console (see below).

The exact hosted image has now passed one cold boot on the 11.60 test console.
All five boot files matched the release identities, the root filesystem grew to
fill the 248 GB test drive, Plasma joined Wi-Fi and passed traffic bound to that
interface, the internal Bluetooth controller paired and automatically
reconnected a DualSense, and the full Plasma → Gaming Mode → Plasma handoff
passed without compositor overlap. The returned Plasma session then needed the
tester guide's live Polkit hotfix before KDE could control NetworkManager;
Image 4 carries that correction. The startup frequency policy
also reached GPU `simple_ondemand`, CPU `schedutil` and CPU boost off. With the 65 C fan
hotfix active, a 20-second, 16-worker CPU load held the CPU near 3.19 GHz,
peaked at 47 C and returned to 37 C three seconds after the load ended. This is
still one boot and not thermal-equilibrium or long-duration stability evidence:
cold-boot Wi-Fi and Bluetooth reconnect, a long coexistence run, a longer
thermal/stability run, performance opt-out, storage integrity and video decode
remain open. The
published fan service still left the target at 86 C; the documented per-boot
hotfix changed its readback to 65 C for this session, but RPM is not exposed and
the persistent Image 4 correction is not in the Image 3 archive. To skip the
experimental startup clock policy, create an empty
`/boot/efi/disable-ps5-performance` file and fully power off before the next
boot. Do not unload the frequency modules as a rollback; unloading does not
restore the clocks.

### Published Image 3 identity

| Item | Value |
|------|-------|
| Release | [`cachyos1160-k73-image-3`](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-3), public prerelease |
| Source | `16795eb85830dc32f712e44e9e0da28f7874b317` |
| CI | [workflow `39521098451`](https://github.com/gzimbric/ps5-linux-image/actions/runs/39521098451), successful |
| Archive | `ps5-cachyos1160-k73.img.xz`, 1,943,937,164 bytes, SHA-256 `9e224aeb607ba050dd520ce32d50989d27013f7da2889ce7ed1ce247fea71e3c` |
| Raw image | 12,582,912,000 bytes, SHA-256 `25a0ef68a85dbe6d976b5a97faaa323b64c4efbe1b220003772f25a264eb34a8` |
| `bzImage` | 11,613,184 bytes, SHA-256 `945a4f2a03c4771313e466dccfb8272e0345cf7d143516a36a0bc75b2b219d0a` |
| `initrd.img` | 51,899,412 bytes, SHA-256 `912600c22a203a744d4d44fcd4b5caacd86ea8b0c3ef8202ed9c0ff2ba146dd0` |
| Other boot files | `cmdline.txt` `aec7a85e9ebcf36e4bdaeb89242b898e17817acd40c16db57a3bb9c3117b1da8`; `vram.txt` `bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0`; `kexec.sh` `0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52` |
| Hardware status | One identity-verified cold boot on a CFI-1115B running 11.60; HDMI, wired SSH, Plasma Wi-Fi, internal-Bluetooth DualSense input, the Plasma/Gaming Mode round trip and a short bounded CPU load passed; broader prerelease gates remain open |

The archive is one file, never numbered parts. Verify `SHA256SUMS` before
flashing. The bounded Wi-Fi loader copies the console's own IW620 firmware to
the USB; neither the loader nor this image contains that firmware. Older 11.60
loaders refuse these boot-file sizes, and the similarly named
`linux-1160-dma-e820-wifi` target is not the bounded build.

### Image 4 tester prerelease

[Image 4](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-4)
is a public tester prerelease. Its exact image, flashed with a verified
readback, has booted once on a CFI-1115B running 11.60 with Sonic's all-11-13
loader release. The first wake attempt powered the console off; the second
booted. That is one boot, not a stability result. To test Image 4, follow the
[Image 4 tester guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/cachyos1160-k73-image-4-tester-guide.md).

| Item | Value |
|------|-------|
| Release | [`cachyos1160-k73-image-4`](https://github.com/gzimbric/ps5-linux-image/releases/tag/cachyos1160-k73-image-4), public prerelease |
| Source | `e82cefaac9f4c166b4b961ea64597bb5a2a1d1e3` |
| CI | [workflow `39536824124`](https://github.com/gzimbric/ps5-linux-image/actions/runs/39536824124), successful |
| Kernel | `linux-ps5 7.3.0-4` |
| Archive | `ps5-cachyos1160-k73.img.xz`, 1,942,499,200 bytes, SHA-256 `bc83fc06b78c4b1f34498fc4f9657bcf84483ee5c3268e48047ad844dd8b7380` |
| Raw image | 12,582,912,000 bytes, SHA-256 `b8346c5d8c34e643926f7c6a5d58c0017b0de8b18f944dcf7869a31759e971d5` |
| Hardware status | One boot on a CFI-1115B (IW620) running 11.60: HDMI Plasma desktop, wired SSH, every PS5 service active, IW620 firmware loaded (Wi-Fi not joined in that run), one Bluetooth controller, frequency drivers loaded. A MediaTek tester reported MediaTek Wi-Fi working with `module_blacklist=btusb`; without it, MediaTek Bluetooth froze the console about 20 s after boot |

CI passed the image verifier, the bounded-loader limits and the single-file
check. That covers the software checks, not a hardware boot. The archive is one
file; verify `SHA256SUMS` before flashing.

Image 4 is one `linux-ps5 7.3.0-4` image for both onboard Wi-Fi
variants. The proven Marvell IW620 path remains exact-ID gated at
`1b4b:2b56`. Matching MediaTek hardware can use Linux 7.3's in-tree
`mt7921e` driver; the known PS5 device ID is `14c3:7961`. The image includes
the firmware declared by that driver and installs `disable_aspm=1`, matching
the runtime setting in
[j4lenj's reference](https://github.com/j4lenj/ps5-mt7921-wifi), without
copying its older Linux 7.1.7 driver source or binaries. Neither Wi-Fi driver
is force-loaded on the other chipset.

MediaTek Wi-Fi is structurally validated by the build and source checks, and
one MediaTek tester reported it working on 11.60 with Bluetooth turned off
(`module_blacklist=btusb`). On that console MediaTek Bluetooth through btusb
froze the system about 20 s after boot. The Image 3 hardware result does not
transfer to this new kernel or image. Both loaders are in the
[bounded loader prerelease](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-dma-e820-bounded-run21).
IW620 systems still use the bounded Wi-Fi ELF,
`ps5-linux-loader-1160-dma-e820-bounded-wifi.elf`
(`e9fe6469943e97a635eccd3f674e55876b56cd1bbd69023eee3af4acea3a1b5f`), so the
loader can supply the console's firmware. MediaTek systems use the bounded
non-Wi-Fi ELF, `ps5-linux-loader-1160-dma-e820-bounded.elf`
(`1c80b040c5a808b3f09418728424a875d5598fe6b2a5d68adeb4db5979a7541a`), because
their firmware is already packaged in the image. That ELF has not been booted.

### Build it from source

On Linux x86_64:

```bash
./scripts/build-linux-ps5-k73.sh
sudo ./scripts/package-linux-ps5-k73.sh
sudo ./scripts/build-cachyos1160-k73-image.sh
sudo ./scripts/verify-cachyos1160-k73-image.sh --image output/ps5-cachyos1160-k73.img
```

The [profile README](distros/cachyos1160-k73/README.md) lists the pins, checks,
changes, exact release identity, and remaining test gaps. The
[`CachyOS 7.3 11.60 image`](.github/workflows/cachyos1160-k73-image.yml)
uses GitHub-hosted runners. A manual workflow dispatch builds the full image,
verifies it, compresses it to one `.img.xz`, and creates or safely refreshes
the draft for the requested tag. Publishing that draft creates the tag; the
tag push does not start another build. A published release is never
overwritten. A `main` push that changes a kernel input only rebuilds and
validates the exact cache bundle for the next manual image run. The workflow
stops before the release step if the archive reaches GitHub's 2 GiB per-file
limit. All compilation, assembly, compression and uploading stays on the
hosted runners; a Mac does not build or relay the artifact. Passing CI proves
the software checks, not a hardware boot.

## Ubuntu 24.04 on Linux 7.3.0 (11.xx and 13.xx)

`distros/ubuntu2404-k73` is Ubuntu 24.04 LTS on the shared Linux 7.3.0
kernel build #7 for regular PS5 consoles (fat and slim), plus an experimental
PS5 Pro path, on firmware 11.xx and 13.xx. It carries the Image 4 Wi-Fi, fan,
clock and boot-file fixes, the MediaTek Bluetooth fixes from VivaLaVent's
ps5-bazzite-deck v1.0.4, and the Pro-only GPU delta ported onto the pinned 7.3
patch set. The same image includes the in-tree MT7925 driver and pinned Pro
Wi-Fi/Bluetooth firmware; regular-only frequency modules are skipped on Pro.
The source also extends the MediaTek Bluetooth phantom-interface and bulk OUT
handling to the Pro's `0e8d:3605` controller. That extension matches captured
USB descriptors but has not passed a hardware Bluetooth test yet.
`.github/workflows/ubuntu2404-k73-image.yml` builds it and makes a
draft prerelease named `ubuntu2404-k73-image-N`. Image 3 reached the desktop
on one PS5 Pro on 11.60 with
[Pro Linux test 3](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-pro-linux-test-3).
See the [profile README](distros/ubuntu2404-k73/README.md).

## Prerequisites

- Docker with the Buildx plugin (and permission to run `--privileged` containers) — install as per your distro's instructions
- On arm64 hosts, the Ubuntu 24.04 profile requires current amd64 binfmt/QEMU support or a native/full-system amd64 environment; Rosetta cannot run its nested chroot stage
- ~30GB free disk space for Ubuntu, Arch, or CachyOS

Once Docker is installed, add your user to the docker group and apply it without logging out:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Quick Start

```bash
# Build the firmware 11.60 tested-envelope Ubuntu 24.04 profile
./build_image.sh --clean --kernel-only --distro ubuntu2404
./build_image.sh --distro ubuntu2404

# Build a single Ubuntu 26.04 image
./build_image.sh --distro ubuntu2604

# Build CachyOS (Arch-based, Gamescope + Steam Big Picture)
./build_image.sh --distro cachyos

# Build Fedora (GNOME desktop)
./build_image.sh --distro fedora

# Build a multi-distro image (ubuntu2604 + arch + cachyos)
./build_image.sh --distro all
```

The script auto-clones the kernel source, applies PS5 patches, compiles, and builds the image. Subsequent runs reuse cached artifacts automatically. Press Ctrl+C at any time to abort cleanly.

## Flash to USB

```bash
# Ubuntu 24.04 firmware 11.60 tested-envelope image
sudo dd if=output/ps5-ubuntu2404.img of=/dev/sdX bs=4M status=progress

# Ubuntu 26.04 profile
sudo dd if=output/ps5-ubuntu2604.img of=/dev/sdX bs=4M status=progress
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--distro` | `ubuntu2404`, `ubuntu2604`, `arch`, `cachyos`, `fedora`, or `all` | `ubuntu2604` |
| `--kernel` | Path to kernel source directory (not accepted by the exact `ubuntu2404` profile) | auto-clone version selected by PS5 patch set |
| `--img-size` | Disk image size in MB | `12000` (`16000` for `ubuntu2404`, `32000` for `all`) |
| `--clean` | Remove all cached build artifacts and start fresh | off |
| `--kernel-only` | Build and package the kernel only, then exit | off |
| `--patches-ref` | Branch, tag, or commit SHA for patches | `v1.2` normally; pinned to `kernel-7.1.7-56922cf` for `ubuntu2404` |

## Caching

The build automatically skips stages that have already completed and still match their validation keys:

- **Kernel source** — ordinarily reused if `work/linux/` exists; exact `ubuntu2404` instead reconstructs the pinned Git tree on a fresh case-sensitive Linux volume and rejects a custom `--kernel` tree
- **Kernel packages** — reused if package files exist; `ubuntu2404` uses its own `linux-bin/ubuntu2404/` cache and first verifies Debian metadata, the semantic package tree, boot artifacts, all modules, and embedded kernel headers
- **Root filesystem** — reused if chroot directories are populated; exact `ubuntu2404` instead rebuilds it on a disposable Linux-native Docker volume on every image run, while retaining only its download cache

Use `--clean` to wipe everything and rebuild from scratch. The build will also suggest `--clean` if a stage fails.

For the documented Ubuntu 24.04 workflow, use `--clean` on the first, kernel-only stage. The second stage deliberately reuses that just-verified package while building the userspace and image.

## Build Output

```
PS5 Linux Image Builder
=======================
  Distro:       all
                (ubuntu2604 arch cachyos)
  Image size:   32000MB
  Kernel src:   /path/to/work/linux

Stages:
  1. Kernel            cached
  2. Root filesystem   build
  3. Disk image        build

Logs: /path/to/build.log

  ✓ Kernel packages (cached)
  ✓ Build image builder image
  ⠹ Building arch rootfs
```

All verbose output goes to `build.log`. The terminal shows a spinner with live progress.

## Distributions

| Distro | Desktop | Kernel format | Init |
|--------|---------|---------------|------|
| Ubuntu 24.04 (Noble, firmware 11.60 tested-envelope profile) | GNOME | `.deb` | systemd |
| Ubuntu 26.04 (Resolute) | GNOME | `.deb` | systemd |
| Arch | Sway | `.pkg.tar.zst` | systemd |
| CachyOS | Gamescope + Steam Big Picture (Arch + `[cachyos]` repo, no v3 migration in image build) | `.pkg.tar.zst` | systemd |

## Multi-distro Image

`--distro all` builds a 32GB image with 4 partitions (one EFI boot partition plus three root filesystems):

| Partition | Type | Label | Content |
|-----------|------|-------|---------|
| p1 | FAT32 | boot | Shared kernel, per-distro initrds, kexec scripts |
| p2 | ext4 | ubuntu2604 | Ubuntu 26.04 rootfs |
| p3 | ext4 | arch | Arch rootfs |
| p4 | ext4 | cachyos | CachyOS rootfs |

The boot partition contains kexec scripts to switch between distros at runtime. Ubuntu 26.04 is the default boot target.

## Building the Kernel Standalone

Use `--kernel-only` to compile the PS5 kernel and produce installable packages without building a full disk image.

```bash
./build_image.sh --kernel-only                                # .deb (default)
./build_image.sh --kernel-only --distro all                   # .deb + .pkg.tar.zst
./build_image.sh --kernel-only --patches-ref main             # fetch from specific branch/tag
./build_image.sh --kernel-only --clean                        # wipe and rebuild from scratch
```

Output packages are written to `linux-bin/`; the exact Ubuntu 24.04 package is kept in `linux-bin/ubuntu2404/` so it cannot be reused by another profile. Install that package on a running PS5 Linux system with:

```bash
sudo dpkg -i linux-bin/ubuntu2404/linux-ps5_*.deb
```

## Directory Layout

```
build_image.sh                  # Image builder (also supports --kernel-only)
docker/
  kernel-builder/               # Kernel compilation container
  kernel-builder-arch/          # Repackages .deb kernel as .pkg.tar.zst
  image-builder/
    Dockerfile                  # Image building container (distrobuilder)
    entrypoint.sh               # Single-distro build logic
    entrypoint-multi.sh         # Multi-distro build logic
distros/
  ubuntu2404/                   # Ubuntu 24.04 firmware 11.60 tested-envelope profile
  ubuntu2604/                   # Ubuntu 26.04 (Resolute)
  arch/                         # Arch Linux
  cachyos/                      # CachyOS repos + Gamescope/Steam
  cachyos1160/                  # Changes that make the official CachyOS image boot on firmware 11.60
  shared/                       # Kernel postinst hooks (single + multi)
boot/
  cmdline.txt                   # Kernel cmdline template (__DISTRO__ placeholder)
  vram.txt                      # VRAM allocation
  kexec.sh                      # Single-image kexec helper
  kexec-{ubuntu2604,arch,cachyos}.sh
scripts/
  build-cachyos1160-image.sh    # Build the CachyOS firmware 11.60 image from the official image
  ubuntu2404-profile-id.sh     # Hash the complete Ubuntu 24.04 build recipe
  verify-ubuntu2404-kernel-deb.sh # Validate the exact semantic kernel package
  verify-ubuntu2404-boot.sh     # Check flashed boot files against the tested envelope
work/                           # Build artifacts (auto-created)
linux-bin/                      # Compiled kernel packages (ubuntu2404 has its own subdirectory)
output/                         # Final .img files
```
