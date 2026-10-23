# Ubuntu 24.04 on Linux 7.3.0

Ubuntu 24.04 LTS desktop for regular PS5 consoles (fat and slim), plus an
experimental PS5 Pro path, on firmware 11.xx and 13.xx. It uses shared
Linux 7.3.0 kernel build #6 and is built by
`.github/workflows/ubuntu2404-k73-image.yml` as a draft prerelease named
`ubuntu2404-k73-image-N`.

**Status:** tester build. The regular-console path inherits the drivers and
services tested in CachyOS Image 4 on 11.60. The PS5 Pro loader/HV path and
kernel-text access were proved separately, but Linux boot, display, Wi-Fi and
Bluetooth on Pro still need hardware testing. This is one image for both:
the kernel includes only the Pro-specific GPU delta from rmux commit
`55161c0`, Linux 7.3's `mt7925e`, and the exact MT7925 Wi-Fi/Bluetooth
firmware. The regular-only CPU/GPU frequency modules are skipped on Pro.

## Loader

Use a loader build that supports your firmware and does not need exact
boot-file sizes, for example Sonic's 11.xx/13.xx release or a current
[ps5-linux-loader](https://github.com/ps5-linux/ps5-linux-loader) build. On
an IW620 console, use a build that passes the Wi-Fi firmware to Linux.
PS5 Pro additionally needs a loader with the validated Pro HV path; a
regular-console ELF is not a substitute.

Loader builds that need exact boot-file sizes, such as the 11.60 builds used
with the Ubuntu 24.04 7.1.7 image (`firmware-11.60-dma-e820-run18`, the
`linux-1160-dma-e820-wifi` target), refuse these files. On 11.60 the bounded
builds from
[`firmware-11.60-dma-e820-bounded-run21`](https://github.com/gzimbric/ps5-linux-loader/releases/tag/firmware-11.60-dma-e820-bounded-run21)
also work: the Wi-Fi ELF on IW620 consoles, the non-Wi-Fi ELF on MediaTek
consoles.

The boot partition has `bzImage`, `initrd.img`, `cmdline.txt`, `vram.txt`
and `kexec.sh` at its root. No exact file sizes are needed. The build checks
that `bzImage` is a relocatable boot protocol 2.15 kernel built with KASLR,
that `bzImage` and `initrd.img` together stay under 160 MiB, and that
`cmdline.txt` has no `nokaslr`, `mem=` or `memmap=`. Keep it that way when
you edit `cmdline.txt`.

`kexec.sh` is the official image's file, unchanged, but it is not expected
to work with this kernel. The last commit of rmux's fork turns the Salina
xHCI PHY setup back on for Bluetooth and notes that this breaks kexec. A
cold boot from the loader is not affected.

## Login

`ps5` / `ubuntu`, with passwordless sudo. GDM logs in automatically and SSH
accepts the password. Run `passwd` after the first boot and keep the console
on a trusted network until you do.

For key-only SSH, add your key to `~/.ssh/authorized_keys`, check it works
in a second session, then set `PasswordAuthentication no` in
`/etc/ssh/sshd_config.d/10-ps5-control.conf` and restart `ssh.service`. Each
console makes its own SSH host keys on first boot.

The image ships without apt package lists; run `sudo apt update` before
installing anything. If an upgrade asks about `/etc/bluetooth/main.conf` or
`/etc/bluetooth/input.conf`, keep the installed version. Those files hold
the PS5 Bluetooth settings.

## Flashing

Flashing erases the whole target drive. Check the device path first.

```
sha256sum -c --ignore-missing SHA256SUMS
xz -dc ps5-ubuntu2404-k73.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

The image is 12,582,912,000 bytes and fits a 16 GB drive. The root
partition grows to fill the drive on the first boot. balenaEtcher and
Raspberry Pi Imager can flash the `.img.xz` directly.

## What is in the image

| Piece | Where it comes from |
| --- | --- |
| Kernel | `linux-ps5 7.3.0-6`, kernel build #6: Linux v7.3 with rmux's 7.3 patch set ([rmuxnet/ps5-linux-patches-1](https://github.com/rmuxnet/ps5-linux-patches-1) at `36f173f`) plus only the Pro GPU delta from `55161c0`, without repinning. CPU/GPU frequency drivers are modules, VCN firmware is built in, and `MT7921E=m` plus `MT7925E=m`. Made into a `.deb` from the shared k73 kernel bundle by `scripts/package-linux-ps5-k73-deb.sh`. |
| Bluetooth patches | VivaLaVent's IW620 btusb quirks fix from ps5-bazzite-deck v1.0.3, and from v1.0.4 WizGery's bulk OUT endpoint fix for the MediaTek controller (USB `0e8d:3603`) plus an L2CAP change that answers "pending" when a connection request beats the encryption change event. The patches are in `distros/cachyos1160-k73/kernel`, shared with the CachyOS image. |
| IW620 Wi-Fi | mlan/moal from ps5-linux-mwifiex `4bce848` with the 7.3 compatibility patch, built against the same kernel tree and shipped in the `linux-ps5` package under `/usr/lib/modules/7.3.0/updates/ps5-iw620`. `ps5-iw620-firmware.service` copies the loader's firmware dump from `/boot/efi/lib/nxp/` and loads the driver. |
| MediaTek Wi-Fi | Linux 7.3's `mt7921e` for regular consoles and `mt7925e` for Pro, loaded only by their PCI IDs. The regular firmware comes from Ubuntu's `linux-firmware`; the three Pro Wi-Fi/Bluetooth files are installed and SHA-256 checked from the same pinned linux-firmware revision used by the image build. |
| MediaTek Bluetooth | `99-ps5-bt-phantom.rules` turns off interfaces 3 and 4 of `0e8d:3603` (a phantom second controller) and keeps the device out of autosuspend. The rule is in the initramfs too, so those interfaces are off before btusb can load. `btusb-ps5.conf` sets `enable_autosuspend=0` for every btusb controller, the IW620 included (as in Bazzite Deck v1.0.4). |
| NetworkManager | `zz-ps5-iw620.conf`: no scan MAC randomization, the permanent MAC, power saving off. It is named to sort after Ubuntu's `default-wifi-powersave-on.conf`. |
| BlueZ | Pairable, Just Works repairing and the userspace HID path, as in Image 4. |
| Fan and clocks | `ps5fan.service` sets a 65 C target for the ICC's automatic fan control (`/etc/default/ps5-fan`); `ps5-performance.service` then loads the GPU and CPU frequency drivers on regular consoles. It detects either Pro GPU ID and leaves those unvalidated frequency modules unloaded on Pro. |
| Display | amdgpu `dpm=0 gpu_recovery=0 force_1080p=1` and the eight Cyan Skillfish 2 firmware files in the initramfs, `consoleblank=0`, no `video=`. On Pro, the kernel also supplies the 13DC ID, 16-CU geometry, nine golden registers, DCN 2.01 classification and the Pro CLK4 offset. |
| Kernel updates | apt holds `linux-ps5`. See below. |
| Boot report | `ps5-boot-report.txt` on the boot partition, 35 seconds after boot. |

`systemd-networkd-wait-online` and the Linux sleep targets are masked.

### Changes from the Ubuntu 24.04 7.1.7 image

- Linux 7.3.0 instead of 7.1.7, no exact-size boot files and no padded
  initramfs.
- Wi-Fi, Bluetooth, the fan target and the frequency drivers from Image 4.
- The hostname is `ps5`. The 7.1.7 image had the build container's ID.
- `ps5-ssh-host-keys.service` no longer has an ordering cycle with
  `ssh.socket`.
- 12,000 MiB instead of 16,000 MiB, so a 16 GB drive is enough.
- No apt package lists in the image (see Login).

## Firmware 11.xx and 13.xx

Nothing in the image is firmware-specific, but the regular-console base has
only been booted on 11.60 (as kernel #4 in CachyOS Image 4, before the
MediaTek Bluetooth patches), while the Pro Linux path and 13.xx are untested.
The one place the firmware showed was
the IW620 firmware the loader dumps: 498108 bytes on 11.xx and 500296 bytes
on 13.xx. `ps5-iw620-firmware` accepts both (and the older loader sizes),
and logs the size and SHA-256 of what it found. A dump of any other size is
ignored; the log then says so and names the copy from an earlier boot it
uses instead, if there is one. Never share that file; it is the console's
own firmware.

## MediaTek consoles

The Bluetooth fixes are new and have not been tried on this image. If the
console freezes about 20 seconds after boot, add `module_blacklist=btusb` to
the end of the line in `cmdline.txt`. That turns Bluetooth off and leaves
Wi-Fi working. `btusb.ps5_tx_ep=0` keeps btusb but goes back to the stock
endpoint. Please report either case with `ps5-boot-report.txt`.

On PS5 Pro, `mt7925e` and its required firmware are present, but that path is
still a first-boot test. The boot report records the detected MediaTek PCI
ID, module binding, firmware messages and Bluetooth USB IDs.

## If the display does not come up

The VCN video block is built into this kernel, as in Image 4, where the
display came up with it. Video decode has not been tested. If VCN fails to
start on some console or display, amdgpu can fail to probe. Ethernet and SSH
do not depend on it: SSH in and save `sudo dmesg` and `ps5-boot-report.txt`.
To boot without VCN, find `detected ip block number N <vcn_v2_0_0>` in either
one and add `amdgpu.ip_block_mask=` to the end of the line in `cmdline.txt`,
set to 0xffffffff with bit N cleared (for N = 6,
`amdgpu.ip_block_mask=0xffffffbf`). amdgpu then skips that block. Do not add
`nokaslr`.

## Kernel and initramfs updates

`linux-ps5` is held, and generic Ubuntu kernels are pinned out. When the
initramfs is rebuilt (a `linux-firmware` or `initramfs-tools` update, or
`sudo update-initramfs -u -k 7.3.0` after you change
`/etc/initramfs-tools` or `/etc/modprobe.d`), the hook
`/etc/initramfs/post-update.d/zz-ps5-boot-files` runs
`ps5-update-boot-files`. It checks that the new initramfs has amdgpu, the
GPU firmware, `ps5-amdgpu.conf` and the MediaTek Bluetooth udev rule and no
Wi-Fi, btusb or frequency drivers, runs `ps5-check-boot-files` on the kernel
and initramfs, and only then copies them to `/boot/efi`. If the check fails,
the update fails and `/boot/efi` is left alone.

When the kernel on `/boot/efi` changes, the pair that was there is kept as
`bzImage.prev` and `initrd.img.prev`. Later initramfs rebuilds for the same
kernel leave them alone, so they stay the last pair from before the kernel
change.

Install a newer kernel package with `sudo dpkg -i linux-ps5_<version>_amd64.deb`.
It refuses to start while `/boot/efi` is not mounted read-write. The IW620
modules are part of the package, so they are replaced together with the
kernel. If copying the boot files fails after dpkg has unpacked the
package, the new modules are installed but `/boot/efi` still has the old
kernel: do not reboot. Fix the error and run `sudo dpkg --configure -a`, or
reinstall the previous package. To go back to the previous files, rename the
`.prev` files over `bzImage` and `initrd.img` on the boot partition from
another computer.

The package also has the module build tree in `/usr/lib/modules/7.3.0/build`.
The kernel was built with gcc 14 on Debian, so out-of-tree modules need
`gcc-14` and are not set up for DKMS.

## Opting out

- Frequency drivers: create an empty `disable-ps5-performance` on the boot
  partition and fully power off. They are skipped automatically on PS5 Pro.
- Fan target: edit `PS5_FAN_TARGET_C` in `/etc/default/ps5-fan` (40 to 80)
  and run `sudo systemctl restart ps5fan`.

## Building it yourself

On an x86_64 Linux machine with Docker:

```
./scripts/build-linux-ps5-k73.sh
sudo ./scripts/package-linux-ps5-k73.sh
./scripts/package-linux-ps5-k73-deb.sh
sudo ./scripts/build-ubuntu2404-k73-image.sh --deb linux-bin/ubuntu2404-k73/linux-ps5_7.3.0-6_amd64.deb
sudo ./scripts/verify-ubuntu2404-k73-image.sh --image output/ps5-ubuntu2404-k73.img \
  --deb linux-bin/ubuntu2404-k73/linux-ps5_7.3.0-6_amd64.deb
```

The first command needs a case-sensitive filesystem for its output.
`distros/ubuntu2404-k73/setup-rootfs.sh` does the PS5 setup inside the new
root filesystem; `image.yaml` holds the package list.

## Credits

- rmux for the Linux 7.3 PS5 patch set, the frequency drivers and the Pro GPU
  delta ported onto the pinned 7.3 base.
- VivaLaVent for the btusb fixes, the 7.3 port of the MediaTek Bluetooth
  fix, the L2CAP change and the udev and modprobe settings
  (ps5-bazzite-deck).
- WizGery for the MediaTek Bluetooth bulk OUT fix (ps5-mediatek-fixes).
- j4lenj for the MediaTek Wi-Fi `disable_aspm` reference.
- Sonic for the loader that runs this on 11.xx and 13.xx.
- The ps5-linux project for the image builder, the IW620 driver work and the
  original PS5 patches.
