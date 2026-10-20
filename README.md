# PS5 Linux Image Builder

Builds bootable Linux USB images for PlayStation 5 using Docker containers. This branch adds a public Ubuntu 24.04 profile that enforces the boot-critical envelope of the Run 16 control image that booted successfully on PS5 firmware 11.60, while retaining the upstream Ubuntu 26.04, Arch, CachyOS, and Fedora profiles.

## Ubuntu 24.04 firmware 11.60 tested envelope

Use the two-stage reproduction workflow:

```bash
./build_image.sh --clean --kernel-only --distro ubuntu2404
./build_image.sh --distro ubuntu2404
```

The first command starts from clean caches and builds and validates the pinned kernel package. The second intentionally reuses that verified package while assembling a fresh Ubuntu root filesystem and raw image. Image assembly audits the temporary raw image before publishing `output/ps5-ubuntu2404.img`.

The source-clean kernel/package build and fresh image assembly from this public branch passed their software validation gates. That does not constitute a PS5 hardware boot of the public branch. The hardware result remains the separate Run 16 control image, which booted on firmware 11.60. A single `./build_image.sh --clean --distro ubuntu2404` run from an empty cache has not been validated and is not claimed here.

The successful control image was 16,777,216,000 bytes (16,000 MiB), which is the default for this profile. The matching firmware 11.60 USB and boot procedure is documented in the [porting guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/ubuntu2404-run16-usb.md).

The branch itself holds only source and build instructions. Test images built by CI are covered in [Prebuilt test image](#prebuilt-test-image). Review the licenses of the inherited builder and installed distribution packages before redistributing a built image.

### Prebuilt test image

The [`Ubuntu 24.04 11.60 image`](.github/workflows/ubuntu2404-1160-image.yml) workflow runs the two commands above on a GitHub-hosted x86_64 runner. It then runs both verifiers, checks the five FAT boot files against the [tested boot envelope](#tested-boot-envelope), and attaches the compressed image to a draft release. Testers can only see it after the draft has been reviewed and published. The workflow is started by hand from the Actions tab, or by pushing a tag that matches `ubuntu2404-1160-image-*`.

A CI image is a rebuild, so its raw-image hash will not match the Run 16 control or any other build. The parts that must match are `bzImage`, `cmdline.txt`, `vram.txt` and `kexec.sh`, byte for byte, and `initrd.img` at exactly 54,376,639 bytes. The build fails if any of them, or either verifier, fails. Every release lists the hashes for its own build in `SHA256SUMS` and `build-info.txt`.

Download `ps5-ubuntu2404.img.xz` and `SHA256SUMS` from the release into one folder, then:

```bash
sha256sum -c --ignore-missing SHA256SUMS
xz -dc ps5-ubuntu2404.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

On macOS, check with `shasum -a 256 -c --ignore-missing SHA256SUMS` and flash to `/dev/rdiskN`. balenaEtcher and Raspberry Pi Imager can flash the `.img.xz` without unpacking it first. To check the decompressed image itself, compare `xz -dc ps5-ubuntu2404.img.xz | sha256sum` with the `ps5-ubuntu2404.img` line in `SHA256SUMS`.

GitHub caps release files at 2 GiB. If a build's `.img.xz` is larger than 1,900 MiB, the release has numbered parts (`ps5-ubuntu2404.img.xz.001`, `.002`, ...) instead of one file. Download every part, then check and join them before flashing:

```bash
sha256sum -c --ignore-missing SHA256SUMS
cat ps5-ubuntu2404.img.xz.[0-9][0-9][0-9] > ps5-ubuntu2404.img.xz
sha256sum -c --ignore-missing SHA256SUMS
```

On Windows, join the parts with `copy /b ps5-ubuntu2404.img.xz.001 + ps5-ubuntu2404.img.xz.002 ps5-ubuntu2404.img.xz`, adding a `+` for each further part.

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
- Run 17 later brought up the onboard Wi-Fi on an installed copy of this image by adding NXP `mlan`/`moal` modules built for this exact kernel and the console's own firmware. This branch was not changed for that test, and images built from it still omit and blacklist the driver. The build, firmware location, and load scripts are in the porting repository's [Wi-Fi guide](https://github.com/gzimbric/ps5-linux-porting/blob/main/docs/ubuntu2404-wifi.md).
- `ps5fan.service` automatically requests the Run 16 control's fan servo pattern (`3`) during boot. That request was accepted on the tested console, but fan RPM and cooling performance were not measured; this is not a calibrated fan curve.
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

The `cachyos1160-k73` profile is the same official CachyOS image on Linux 7.3.0. The kernel is mainline v7.3 with the 7.3 port of the PS5 patches by rmux (Armandas Kvietkus), [rmuxnet/ps5-linux-patches-1](https://github.com/rmuxnet/ps5-linux-patches-1) at `36f173f`, which also brings rmux's PS5 CPU and GPU frequency drivers. The image builds them as modules and does not load them at boot. It also ships the IW620 Wi-Fi driver built for this kernel (but no Wi-Fi firmware), holds the kernel package in pacman, and updates the boot files from a pacman hook. Its boot files are not the exact sizes the earlier 11.60 loaders require, so it needs a bounded 11.60 loader build from [gzimbric/ps5-linux-loader](https://github.com/gzimbric/ps5-linux-loader) `main`: `make linux-1160-dma-e820-bounded-wifi` for Wi-Fi, or `make linux-1160-dma-e820-bounded`. The bounded Wi-Fi artifact built at `98925a2` booted in Run 21; the bounded build without the Wi-Fi dump remains unbooted. There is not yet a published prebuilt release, and the similarly named `linux-1160-dma-e820-wifi` is not the bounded build. On Linux x86_64:

```bash
./scripts/build-linux-ps5-k73.sh
sudo ./scripts/package-linux-ps5-k73.sh
sudo ./scripts/build-cachyos1160-k73-image.sh
sudo ./scripts/verify-cachyos1160-k73-image.sh --image output/ps5-cachyos1160-k73.img
```

The [profile README](distros/cachyos1160-k73/README.md) lists the pins, the checks and every change. The [`CachyOS 7.3 11.60 image`](.github/workflows/cachyos1160-k73-image.yml) workflow runs these steps on GitHub-hosted runners and attaches one `ps5-cachyos1160-k73.img.xz` to a draft release. It runs when a tag matching `cachyos1160-k73-image-*` is pushed. A local pre-release image from this profile booted in Run 21; the CI build and the Bluetooth and Wi-Fi ordering fixes in this revision still need a hardware boot.

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
