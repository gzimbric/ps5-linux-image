#!/usr/bin/env bash
# Check a finished CachyOS 7.3 image for PS5 firmware 11.60 read-only.
#
# Run after scripts/build-cachyos1160-k73-image.sh, and again after anything
# that rewrites the image (CI zeroes the free blocks of the root filesystem
# first). It checks what has to be true on the console: the FAT boot files
# and the bounded loader's limits, the kernel and its modules, the Wi-Fi
# driver and the absence of its firmware, the guarded frequency-driver
# startup, the enabled services, the kernel hold and
# the boot-file hook, and the account and SSH hygiene.
#
# Usage: sudo scripts/verify-cachyos1160-k73-image.sh --image IMG [--kernel-dir DIR]
#
# Run as root on Linux x86_64 (the root filesystem's lsinitcpio runs in a
# read-only chroot).
set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C

KVER=7.3.0
NEW_PACKAGE="linux-ps5 7.3.0-3"
IMAGE_SIZE=12582912000
P1_START=1024000 P1_SECTORS=23549952
P2_START=2048 P2_SECTORS=1021952
IW620_ALIAS='pci:v00001B4Bd00002B56sv*sd*bc*sc*i*'

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=$REPO/distros/cachyos1160-k73
CHECK=$PROFILE/files/ps5-1160-check-boot-files

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok  %s\n' "$*"; }
sha() { local h; h=$(sha256sum -- "$1"); printf '%s\n' "${h%% *}"; }
same() { # file reference label
  cmp -s -- "$1" "$2" || die "$3 differs from $2"
  ok "$3"
}

image=
kernel_dir=$REPO/linux-bin/cachyos1160-k73
while (($#)); do
  case $1 in
    --image) (($# >= 2)) || die "--image needs a path"; image=$2; shift 2 ;;
    --kernel-dir) (($# >= 2)) || die "--kernel-dir needs a path"; kernel_dir=$2; shift 2 ;;
    -h|--help) echo "Usage: sudo $0 --image IMG [--kernel-dir DIR]"; exit 0 ;;
    *) echo "Usage: sudo $0 --image IMG [--kernel-dir DIR]" >&2; exit 2 ;;
  esac
done
[[ -n $image ]] || die "--image is required"
((EUID == 0)) || die "run as root"
image=$(realpath -e -- "$image")
kernel_dir=$(realpath -e -- "$kernel_dir")

[[ $(stat -c %s -- "$image") == "$IMAGE_SIZE" ]] || die "image is not $IMAGE_SIZE bytes"
layout=$(partx -g -o NR,START,SECTORS -- "$image" | awk '{ print $1, $2, $3 }')
[[ $layout == "1 $P1_START $P1_SECTORS"$'\n'"2 $P2_START $P2_SECTORS" ]] ||
  die "unexpected partition table: $layout"
ok "$IMAGE_SIZE bytes, partition table"

tmp=$(mktemp -d)
MOUNTS=()
LOOPS=()
cleanup() {
  local rc=$? i
  trap - EXIT
  set +e
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    umount -- "${MOUNTS[i]}" || umount -l -- "${MOUNTS[i]}"
  done
  for i in "${LOOPS[@]}"; do losetup -d "$i"; done
  rm -rf -- "$tmp"
  ((rc == 0)) || echo "Image check failed." >&2
  exit "$rc"
}
trap cleanup EXIT

attach() { # variable start-sector sector-count
  local dev
  dev=$(losetup --find --show --read-only --offset $(($2 * 512)) \
    --sizelimit $(($3 * 512)) -- "$image")
  LOOPS+=("$dev")
  printf -v "$1" '%s' "$dev"
}
root_dev='' boot_dev=''
attach root_dev "$P1_START" "$P1_SECTORS"
attach boot_dev "$P2_START" "$P2_SECTORS"
[[ $(blkid -p -o value -s LABEL "$root_dev") == cachyos ]] || die "p1 is not LABEL=cachyos"
[[ $(blkid -p -o value -s LABEL "$boot_dev") == boot ]] || die "p2 is not LABEL=boot"
e2fsck -fn "$root_dev" >/dev/null || die "e2fsck found problems in the root filesystem"
fsck.fat -n "$boot_dev" >/dev/null || die "fsck.fat found problems in the boot partition"
ok "e2fsck and fsck.fat clean"

R=$tmp/root B=$tmp/boot
mkdir -p "$R" "$B"
mount -t ext4 -o ro,noload "$root_dev" "$R"; MOUNTS+=("$R")
mount -t vfat -o ro "$boot_dev" "$B"; MOUNTS+=("$B")

# -------------------------------------------------------------- boot files

listing=$(cd -- "$B" && find . -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ')
[[ $listing == "bzImage cmdline.txt initrd.img kexec.sh vram.txt " ]] ||
  die "unexpected files on the FAT partition: $listing"
same "$B/cmdline.txt" "$PROFILE/cmdline.txt" "FAT cmdline.txt"
! grep -q nokaslr "$B/cmdline.txt" || die "cmdline.txt has nokaslr"
grep -q 'root=LABEL=cachyos ' "$B/cmdline.txt" || die "cmdline.txt does not boot LABEL=cachyos"
[[ $(sha "$B/vram.txt") == bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0 ]] ||
  die "vram.txt changed"
[[ $(sha "$B/kexec.sh") == 0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52 ]] ||
  die "kexec.sh changed"
ok "FAT vram.txt and kexec.sh are the official image's"
same "$B/bzImage" "$R/boot/vmlinuz-$KVER" "FAT bzImage = /boot/vmlinuz-$KVER"
same "$B/initrd.img" "$R/boot/initrd.img-$KVER" "FAT initrd.img = /boot/initrd.img-$KVER"
[[ ! -f $kernel_dir/kernel/bzImage ]] ||
  same "$B/bzImage" "$kernel_dir/kernel/bzImage" "FAT bzImage = the built kernel"
"$CHECK" "$B/bzImage" "$B/initrd.img" "$B/cmdline.txt"
# The kernel this image needs is 7.3.0, not the base image's 7.1.7.
version=$(strings "$B/bzImage" | awk -v k="$KVER (" 'index($0, k) == 1 && !n { print; n = 1 }')
[[ -n $version ]] || die "FAT bzImage is not a $KVER kernel"
ok "bzImage: $version"

# ------------------------------------------------------------------ kernel

db=$(cd -- "$R/var/lib/pacman/local" && find . -mindepth 1 -maxdepth 1 -name 'linux-ps5-*' -printf '%P\n')
[[ $db == linux-ps5-7.3.0-3 ]] || die "installed linux-ps5: ${db//$'\n'/ }"
[[ $(sed -n '/^%VERSION%$/{n;p}' "$R/var/lib/pacman/local/$db/desc") == 7.3.0-3 ]] ||
  die "pacman database does not say $NEW_PACKAGE"
modules=$(cd -- "$R/usr/lib/modules" && find . -mindepth 1 -maxdepth 1 -printf '%P\n')
[[ $modules == "$KVER" ]] || die "kernel module trees: ${modules//$'\n'/ }"
[[ ! -e $R/boot/vmlinuz-7.1.7 && ! -e $R/boot/initrd.img-7.1.7 ]] || die "7.1.7 boot files left in /boot"
[[ -f $R/usr/share/licenses/linux-ps5/LICENSE.amdgpu ]] || die "the VCN firmware licence is missing"
ok "$NEW_PACKAGE installed, only /usr/lib/modules/$KVER, VCN licence present"

# ------------------------------------------------------------------- Wi-Fi

m=$R/usr/lib/modules/$KVER
for module in mlan moal; do
  f=$m/updates/ps5-iw620/$module.ko
  [[ -f $f ]] || die "$module.ko is not in updates/ps5-iw620"
  if [[ -f $kernel_dir/ps5-iw620/$module.ko ]]; then
    same "$f" "$kernel_dir/ps5-iw620/$module.ko" "$module.ko = the built module"
  fi
  grep -q "^updates/ps5-iw620/$module.ko:" "$m/modules.dep" || die "$module.ko is not in modules.dep"
done
grep -qxF "alias $IW620_ALIAS moal" "$m/modules.alias" || die "modules.alias has no IW620 entry"
same "$R/etc/modprobe.d/ps5-iw620.conf" "$PROFILE/files/ps5-iw620.conf" "/etc/modprobe.d/ps5-iw620.conf"
same "$R/etc/NetworkManager/conf.d/20-ps5-iw620.conf" \
  "$PROFILE/files/20-ps5-iw620.conf" "/etc/NetworkManager/conf.d/20-ps5-iw620.conf"
blocks=$(grep -rsE '^[[:space:]]*(blacklist|install)[[:space:]]+(moal|mlan)([[:space:]]|$)' \
  "$R/etc/modprobe.d" "$R/usr/lib/modprobe.d" || true)
[[ $blocks == "$R/etc/modprobe.d/ps5-iw620.conf:blacklist moal" ]] ||
  die "expected only 'blacklist moal' in ps5-iw620.conf, found: ${blocks:-nothing}"
firmware=$(find "$R" "$B" -xdev -name 'pcieuartiw620*' -print)
[[ -z $firmware ]] || die "IW620 firmware in the image: $firmware"
same "$R/usr/local/sbin/ps5-iw620-firmware" "$PROFILE/files/ps5-iw620-firmware" "ps5-iw620-firmware"
for setting in \
  'wifi.scan-rand-mac-address=no' \
  'wifi.powersave=2' \
  'wifi.cloned-mac-address=permanent'; do
  grep -qx "$setting" "$R/etc/NetworkManager/conf.d/20-ps5-iw620.conf" ||
    die "NetworkManager IW620 setting is missing: $setting"
done
ok "IW620 driver installed, udev alias load blocked, no firmware, stable MAC and power settings applied"

# --------------------------------------------------------------- Bluetooth

# Match the userspace half of the working Bazzite Deck v1.0.3 path. The
# kernel-side btusb correction is compiled into the package; these settings
# keep the controller pairable, accept the DualSense repair, and use UHID.
for value in AlwaysPairable=true PairableTimeout=0 ControllerMode=dual \
  Privacy=device JustWorksRepairing=always AutoEnable=true; do
  [[ $(grep -cxF "$value" "$R/etc/bluetooth/main.conf") == 1 ]] ||
    die "/etc/bluetooth/main.conf does not contain exactly one '$value'"
done
[[ $(grep -cxF 'UserspaceHID=true' "$R/etc/bluetooth/input.conf") == 1 ]] ||
  die "/etc/bluetooth/input.conf does not select the userspace HID path"
for module in btusb uhid hid_playstation; do
  f=$(find "$m/kernel" -name "${module//_/-}.ko" -print)
  [[ -n $f ]] || die "$module is not installed"
  grep -q "^${f#"$m/"}:" "$m/modules.dep" || die "$module is not in modules.dep"
done
if grep -RqsE '(^|[[:space:]])disable_ertm=1([[:space:]]|$)' \
  "$R/etc/modprobe.d" "$R/usr/lib/modprobe.d"; then
  die "disable_ertm=1 is installed"
fi
ok "Bazzite-compatible BlueZ pairing policy, userspace HID path and Bluetooth modules"

# ------------------------------------------------------- frequency drivers

for module in ps5-cpufreq ps5-gpufreq; do
  f=$(find "$m/kernel/drivers" -name "$module.ko" -print)
  [[ -n $f ]] || die "$module.ko is not installed"
  if grep -qw -e "${module//-/_}" -e "$module" "$m/modules.alias" ||
    grep -rqsw -e "${module//-/_}" -e "$module" "$R/etc/modules-load.d" "$R/usr/lib/modules-load.d"; then
    die "$module would be loaded at boot"
  fi
done
same "$R/usr/local/sbin/ps5-performance" "$PROFILE/files/ps5-performance" "/usr/local/sbin/ps5-performance"
same "$R/etc/systemd/system/ps5-performance.service" \
  "$PROFILE/files/ps5-performance.service" "/etc/systemd/system/ps5-performance.service"
grep -qF '/boot/efi/disable-ps5-performance' "$R/usr/local/sbin/ps5-performance" ||
  die "ps5-performance has no FAT opt-out"
grep -qF 'modprobe ps5_gpufreq' "$R/usr/local/sbin/ps5-performance" ||
  die "ps5-performance does not load the GPU driver first"
grep -qF 'modprobe ps5_cpufreq' "$R/usr/local/sbin/ps5-performance" ||
  die "ps5-performance does not load the CPU driver"
ok "ps5-cpufreq and ps5-gpufreq installed, absent from early-load paths, guarded startup installed"

# --------------------------------------------------------------- initramfs

mount -t tmpfs tmpfs "$R/tmp"; MOUNTS+=("$R/tmp")
mount -t tmpfs tmpfs "$R/run"; MOUNTS+=("$R/run")
mount -t proc proc "$R/proc"; MOUNTS+=("$R/proc")
mount --bind /dev "$R/dev"; MOUNTS+=("$R/dev")
contents=$(unshare --net chroot "$R" /usr/bin/env -i PATH=/usr/bin LC_ALL=C \
  lsinitcpio "/boot/initrd.img-$KVER")
grep -Eq "^usr/lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu\.ko(\.zst)?$" <<<"$contents" ||
  die "the initramfs has no amdgpu.ko for $KVER"
for name in ce me mec mec2 pfp rlc sdma sdma1; do
  grep -qx "usr/lib/firmware/amdgpu/cyan_skillfish2_$name.bin" <<<"$contents" ||
    die "the initramfs has no cyan_skillfish2_$name.bin"
done
grep -qx etc/modprobe.d/ps5-amdgpu.conf <<<"$contents" || die "the initramfs has no ps5-amdgpu.conf"
if grep -E '(^|/)((mlan|moal|ps5-cpufreq|ps5-gpufreq)\.ko(\.zst)?|pcieuartiw620[^/]*)$' <<<"$contents"; then
  die "the initramfs has the Wi-Fi driver, its firmware or a frequency driver"
fi
ok "initramfs: amdgpu for $KVER, 8 GPU firmware files, ps5-amdgpu.conf, no Wi-Fi driver or frequency drivers"

# ---------------------------------------------------------------- services

w=$R/etc/systemd/system
for link in multi-user.target.wants/ps5fan.service \
  multi-user.target.wants/ps5-amdgpu-reprobe.service \
  multi-user.target.wants/ps5-performance.service \
  multi-user.target.wants/ps5-iw620-firmware.service \
  multi-user.target.wants/ps5-bt-quiet.service \
  multi-user.target.wants/sshd.service \
  timers.target.wants/ps5-boot-report.timer \
  local-fs.target.wants/grow-rootfs.service; do
  [[ -L $w/$link && -e $R$(readlink "$w/$link" | sed 's#^\.\./#/etc/systemd/system/#') ]] ||
    die "$link is not enabled"
done
for target in sleep suspend hibernate hybrid-sleep suspend-then-hibernate; do
  [[ -L $w/$target.target && $(readlink "$w/$target.target") == /dev/null ]] ||
    die "$target.target is not masked"
done
[[ -z $(find "$w" "$R/usr/lib/systemd/system" -name 'ps5-stage-firmware*' -print) ]] ||
  die "the 7.1.7 package's ps5-stage-firmware is still installed"
for f in ps5-boot-report ps5-amdgpu-reprobe ps5-1160-check-boot-files ps5-update-boot-files; do
  same "$R/usr/local/sbin/$f" "$PROFILE/files/$f" "/usr/local/sbin/$f"
done
same "$R/usr/local/sbin/ps5-fan-target" "$PROFILE/files/ps5-fan-target" \
  "/usr/local/sbin/ps5-fan-target"
same "$R/etc/default/ps5-fan" "$PROFILE/files/ps5-fan.conf" "/etc/default/ps5-fan"
for f in ps5fan ps5-amdgpu-reprobe ps5-performance \
  ps5-iw620-firmware ps5-bt-quiet \
  ps5-boot-report; do
  same "$R/etc/systemd/system/$f.service" "$PROFILE/files/$f.service" \
    "/etc/systemd/system/$f.service"
done
same "$R/etc/systemd/system/ps5-boot-report.timer" \
  "$PROFILE/files/ps5-boot-report.timer" "/etc/systemd/system/ps5-boot-report.timer"
for old in \
  etc/systemd/system/ps5-session-switch-listener.service \
  etc/systemd/system/multi-user.target.wants/ps5-session-switch-listener.service \
  usr/local/sbin/ps5-session-switch-listener \
  usr/lib/systemd/user/default.target.wants/ps5-steamos-session-manager.service \
  usr/lib/systemd/user/ps5-steamos-session-manager.service \
  usr/local/sbin/ps5-steamos-session-manager \
  usr/share/dbus-1/services/com.steampowered.SteamOSManager1.service; do
  [[ ! -e $R/$old && ! -L $R/$old ]] || die "obsolete /$old is installed"
done
same "$R/usr/bin/steamos-session-select" "$REPO/distros/cachyos/files/steamos-session-select" \
  "/usr/bin/steamos-session-select"
same "$R/usr/bin/gamescope-session-ps5" "$REPO/distros/cachyos/files/gamescope-session-ps5" \
  "/usr/bin/gamescope-session-ps5"
grep -qF '/usr/bin/steam -steamos -gamepadui' "$R/usr/bin/gamescope-session-ps5" ||
  die "gamescope-session-ps5 does not enable SteamOS session integration"
! grep -qE '/usr/bin/steam .*-(steamos3|steamdeck)([[:space:]]|$)' \
  "$R/usr/bin/gamescope-session-ps5" ||
  die "gamescope-session-ps5 enables an unsupported SteamOS 3 identity flag"
grep -qF 'systemctl --user stop graphical-session.target' \
  "$R/usr/bin/steamos-session-select" ||
  die "steamos-session-select does not stop Plasma's graphical session target"
grep -qF 'next="plasmax11"' "$R/usr/bin/steamos-session-select" ||
  die "steamos-session-select cannot select the documented X11 escape hatch"
[[ -f $R/etc/ps5-use-tty-sessions ]] || die "tty-session marker missing"
[[ $(cat "$R/home/steam/.config/ps5-next-session") == desktop ]] ||
  die "the image does not open Plasma on first boot"
[[ $(stat -c '%a %u %g' -- "$R/home/steam/.config/ps5-next-session") == \
   '644 1000 1000' ]] || die "the first-session token has the wrong mode or owner"
[[ -x $R/usr/local/sbin/ps5-fan-target && -x $R/usr/local/sbin/grow-rootfs ]] ||
  die "ps5-fan-target or grow-rootfs is missing"
grep -qxF 'PS5_FAN_TARGET_C=65' "$R/etc/default/ps5-fan" ||
  die "the PS5 fan target is not 65 C"
grep -qxF 'ExecStart=/usr/local/sbin/ps5-fan-target' \
  "$R/etc/systemd/system/ps5fan.service" ||
  die "ps5fan.service does not run ps5-fan-target"
[[ ! -e $R/usr/local/sbin/ps5_fan_max ]] ||
  die "the obsolete ps5_fan_max helper is still installed"
unshare --net chroot "$R" /usr/bin/env -i PATH=/usr/bin LC_ALL=C \
  systemd-analyze verify \
    /etc/systemd/system/ps5fan.service \
    /etc/systemd/system/ps5-amdgpu-reprobe.service \
    /etc/systemd/system/ps5-performance.service \
    /etc/systemd/system/ps5-iw620-firmware.service \
    /etc/systemd/system/ps5-bt-quiet.service \
    /etc/systemd/system/ps5-boot-report.service \
    /etc/systemd/system/ps5-boot-report.timer
ok "fan, display re-detect, clocks, session selector, Wi-Fi, Bluetooth, SSH and boot report enabled; Linux sleep masked"

# ------------------------------------------------------- kernel hold, hook

grep -qx 'IgnorePkg   = linux-ps5' "$R/etc/pacman.conf" || die "linux-ps5 is not held with IgnorePkg"
same "$R/etc/pacman.d/hooks/05-ps5-boot-files-precheck.hook" \
  "$PROFILE/files/05-ps5-boot-files-precheck.hook" "pacman hook 05-ps5-boot-files-precheck.hook"
same "$R/etc/pacman.d/hooks/95-ps5-boot-files.hook" "$PROFILE/files/95-ps5-boot-files.hook" \
  "pacman hook 95-ps5-boot-files.hook"
[[ ! -e $R/etc/pacman.d/hooks/00-ps5-linux-ps5-guard.hook ]] || die "the 7.1.7 guard hook is installed"
ok "linux-ps5 held, boot-file hooks installed"

# ------------------------------------------------------- account and keys

[[ $(cat "$R/etc/hostname") == ps5 ]] || die "hostname is not ps5"
grep -qx '127.0.1.1 ps5' "$R/etc/hosts" || die "/etc/hosts has no 127.0.1.1 ps5"
[[ $(readlink "$R/etc/localtime") == /usr/share/zoneinfo/UTC ]] || die "timezone is not UTC"
[[ -f $R/etc/ps5-first-boot-done ]] || die "first-boot marker missing"
grep -q '^steam:' "$R/etc/passwd" || die "no steam account"
[[ -z $(find "$R/etc/ssh" -name 'ssh_host_*' -print) ]] || die "SSH host keys in the image"
[[ -z $(find "$R" -xdev \( -name authorized_keys -o -name authorized_keys2 \) -print) ]] ||
  die "authorized_keys in the image"
ok "hostname ps5, UTC, first-boot marker, steam account, no SSH host keys or authorized_keys"

echo
echo "All checks passed: $image"
