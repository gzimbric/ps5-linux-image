#!/usr/bin/env bash
# Check a finished Ubuntu 24.04 7.3 image (distros/ubuntu2404-k73) read-only.
#
# Run after scripts/build-ubuntu2404-k73-image.sh, and again after anything
# that rewrites the image (CI zeroes the free blocks of the root filesystem
# first). It checks what has to be true on the console: the FAT boot files
# and the loader limits, the kernel package, its hold and the boot-file
# hook, the initramfs, both Wi-Fi paths and the absence of IW620 firmware,
# the MediaTek and IW620 Bluetooth pieces, the NetworkManager settings, the
# frequency drivers, the enabled and masked units, and the account and SSH
# hygiene. Some checks run the image's own tools in a read-only chroot.
#
# Usage: sudo scripts/verify-ubuntu2404-k73-image.sh --image IMG
#          [--kernel-dir DIR] [--deb DEB] [--packages FILE]
#
# --packages FILE  also write the image's package list (name, version) there
#
# Run as root on Linux x86_64.
set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C

KVER=7.3.0
DEB_VERSION=7.3.0-7
ROOT_LABEL=ubuntu2404-k73
P2_START=2048 P2_SECTORS=1021952 P1_START=1024000
IW620_ALIAS='pci:v00001B4Bd00002B56sv*sd*bc*sc*i*'
IW620_DUMP_SIZES='492304 493000 493532 494536 497636 498108 500296'
MT7921E_MODULE=kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko
MT7921E_ALIASES=(
  'pci:v000014C3d00007961sv*sd*bc*sc*i*'
  'pci:v000014C3d00007922sv*sd*bc*sc*i*'
  'pci:v00000B48d00007922sv*sd*bc*sc*i*'
  'pci:v000014C3d00000608sv*sd*bc*sc*i*'
  'pci:v000014C3d00000616sv*sd*bc*sc*i*'
  'pci:v000014C3d00007920sv*sd*bc*sc*i*'
  'pci:v000014C3d00007902sv*sd*bc*sc*i*'
)
MT7925E_MODULE=kernel/drivers/net/wireless/mediatek/mt76/mt7925/mt7925e.ko
MT7925E_ALIASES=(
  'pci:v000014C3d00007925sv*sd*bc*sc*i*'
  'pci:v000014C3d00000717sv*sd*bc*sc*i*'
  'pci:v000014C3d00007927sv*sd*bc*sc*i*'
  'pci:v000014C3d00006639sv*sd*bc*sc*i*'
  'pci:v000014C3d00000738sv*sd*bc*sc*i*'
  'pci:v000014C3d00007928sv*sd*bc*sc*i*'
  'pci:v000014C3d00007935sv*sd*bc*sc*i*'
)
MT7925E_DECLARED_FIRMWARE=(
  mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin
  mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin
  mediatek/mt7927/WIFI_RAM_CODE_MT6639_2_1.bin
  mediatek/mt7927/WIFI_MT6639_PATCH_MCU_2_1_hdr.bin
  mediatek/mt7928/WIFI_RAM_CODE_MT7935_1_1.bin
  mediatek/mt7928/WIFI_MT7935_PATCH_MCU_1_1_hdr.bin
  mediatek/mt7928/CBMCU_CODE_MT7935_1_1.bin
  mediatek/mt7928/WIFI_MT7935_PHY_RAM_CODE_1_1.bin
)
# The regular PS5's MT7921 (PCI 14c3:7961), the Pro's MT7925, and Bluetooth.
MEDIATEK_FIRMWARE=(
  mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin
  mediatek/WIFI_RAM_CODE_MT7961_1.bin
  mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin
)
MT7925_FIRMWARE=(
  'mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin 19c34a936a87f5ee0ea5c7b059c9f440d73cef6891ca8211f080356c1c058ea6'
  'mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin f480faff1abe4bbccfd6fa91343338db148e7763cef257a9b8ca66ba367d3457'
  'mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin 0d79a71c305eec82fdbf1fe1dc15110ef53aec43eee52a6ec3c28bb2b5b0d2f9'
)
GPU_FIRMWARE=(
  'ce 5946efbf7e46ccfe7e9f965da56c35b1187469d1c1a49c8a9eff433eb3ab4723'
  'me d4ed4d968de0d7720f7c8215d42fdae727bf99cdf43cee6f8f864dc2584b17e2'
  'mec b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4'
  'mec2 b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4'
  'pfp 50e56dc1913571ff589425d2b059bddfc5e8a2b4bc22d3eb78cac75d1e0479a1'
  'rlc 20acefdb6128a36275f4382425a109a7c9927f6053eab685bb51164ff1d18cfb'
  'sdma 15d0d3626da7f2513f03b13bb7e02eeeeccab276276ae27d0b6067b5f25e9e95'
  'sdma1 bd1c0b0f6a6a4f17ede034f2c844b6553fc444e08915c7bb500c09fde59d6255'
)
VRAM_SHA256=bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0
KEXEC_SHA256=0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52
# At least this much free space in the root filesystem before grow-rootfs.
MIN_ROOT_FREE=$((1024 * 1024 * 1024))

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=$REPO/distros/ubuntu2404-k73
F=$PROFILE/files
CHECK=$F/ps5-check-boot-files

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { printf 'ok  %s\n' "$*"; }
sha() { local h; h=$(sha256sum -- "$1"); printf '%s\n' "${h%% *}"; }
same() { # file reference label
  cmp -s -- "$1" "$2" || die "$3 differs from $2"
  ok "$3"
}
mode_is() { # file mode label
  [[ $(stat -c '%a %u %g' -- "$1") == "$2 0 0" ]] || die "$3 is not mode $2 root:root"
}

image='' deb='' packages=''
kernel_dir=$REPO/linux-bin/cachyos1160-k73
usage() {
  echo "Usage: sudo $0 --image IMG [--kernel-dir DIR] [--deb DEB] [--packages FILE]"
}
while (($#)); do
  case $1 in
    --image) (($# >= 2)) || die "--image needs a path"; image=$2; shift 2 ;;
    --kernel-dir) (($# >= 2)) || die "--kernel-dir needs a path"; kernel_dir=$2; shift 2 ;;
    --deb) (($# >= 2)) || die "--deb needs a path"; deb=$2; shift 2 ;;
    --packages) (($# >= 2)) || die "--packages needs a path"; packages=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n $image ]] || die "--image is required"
((EUID == 0)) || die "run as root"
image=$(realpath -e -- "$image")
kernel_dir=$(realpath -e -- "$kernel_dir")
[[ -z $deb ]] || deb=$(realpath -e -- "$deb")

# ------------------------------------------------------------ disk layout

image_size=$(stat -c %s -- "$image")
((image_size % (1024 * 1024) == 0)) || die "image is not a whole number of MiB"
sectors=$((image_size / 512))
layout=$(partx -g -o NR,START,SECTORS -- "$image" | awk '{ print $1, $2, $3 }')
p1=$(awk '$1 == 1 { print $2, $3 }' <<<"$layout")
p2=$(awk '$1 == 2 { print $2, $3 }' <<<"$layout")
[[ $(grep -c . <<<"$layout") == 2 ]] || die "expected two partitions: $layout"
[[ $p2 == "$P2_START $P2_SECTORS" ]] || die "p2 is not the 1-500 MiB boot partition: $p2"
read -r p1_start p1_sectors <<<"$p1"
((p1_start == P1_START)) || die "p1 does not start at 500 MiB: $p1"
# parted ends p1 on a MiB boundary before the backup GPT.
((p1_start + p1_sectors <= sectors - 34 && p1_start + p1_sectors > sectors - 34 - 2048)) ||
  die "p1 does not fill the image: $p1 in $sectors sectors"
ok "$image_size bytes, GPT with p2 boot 1-500 MiB and p1 root to the end"

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
attach root_dev "$p1_start" "$p1_sectors"
attach boot_dev "$P2_START" "$P2_SECTORS"
[[ $(blkid -p -o value -s TYPE "$root_dev") == ext4 ]] || die "p1 is not ext4"
[[ $(blkid -p -o value -s LABEL "$root_dev") == "$ROOT_LABEL" ]] || die "p1 is not LABEL=$ROOT_LABEL"
[[ $(blkid -p -o value -s TYPE "$boot_dev") == vfat ]] || die "p2 is not FAT"
[[ $(blkid -p -o value -s LABEL "$boot_dev") == boot ]] || die "p2 is not LABEL=boot"
e2fsck -fn "$root_dev" >/dev/null || die "e2fsck found problems in the root filesystem"
fsck.fat -n "$boot_dev" >/dev/null || die "fsck.fat found problems in the boot partition"
ok "e2fsck and fsck.fat clean"

R=$tmp/root B=$tmp/boot
mkdir -p "$R" "$B"
mount -t ext4 -o ro,noload "$root_dev" "$R"; MOUNTS+=("$R")
mount -t vfat -o ro "$boot_dev" "$B"; MOUNTS+=("$B")
root_free=$(df -B1 --output=avail "$R" | tail -n1 | tr -d ' ')
((root_free >= MIN_ROOT_FREE)) || die "only $root_free bytes free in the root filesystem"
ok "root filesystem: $(df -h --output=used "$R" | tail -n1 | tr -d ' ') used, $(df -h --output=avail "$R" | tail -n1 | tr -d ' ') free"
# The image's own tools, read-only, without network.
mount -t tmpfs tmpfs "$R/tmp"; MOUNTS+=("$R/tmp")
mount -t tmpfs tmpfs "$R/var/tmp"; MOUNTS+=("$R/var/tmp")
mount -t tmpfs tmpfs "$R/run"; MOUNTS+=("$R/run")
mount -t proc proc "$R/proc"; MOUNTS+=("$R/proc")
mount --bind /dev "$R/dev"; MOUNTS+=("$R/dev")
in_root() {
  unshare --net chroot "$R" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin HOME=/root LC_ALL=C "$@"
}

# -------------------------------------------------------------- boot files

listing=$(cd -- "$B" && find . -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ')
[[ $listing == "bzImage cmdline.txt initrd.img kexec.sh vram.txt " ]] ||
  die "unexpected files on the FAT partition: $listing"
same "$B/cmdline.txt" "$PROFILE/cmdline.txt" "FAT cmdline.txt"
grep -q "^root=LABEL=$ROOT_LABEL " "$B/cmdline.txt" || die "cmdline.txt does not boot LABEL=$ROOT_LABEL"
for option in nokaslr mem memmap video; do
  if tr ' ' '\n' < "$B/cmdline.txt" | grep -Eq "^$option(=|$)"; then
    die "cmdline.txt has $option"
  fi
done
grep -qw consoleblank=0 "$B/cmdline.txt" || die "cmdline.txt has no consoleblank=0"
grep -qw usbcore.autosuspend=-1 "$B/cmdline.txt" || die "cmdline.txt has no usbcore.autosuspend=-1"
ok "cmdline.txt has no nokaslr, mem=, memmap= or video="
[[ $(sha "$B/vram.txt") == "$VRAM_SHA256" ]] || die "vram.txt changed"
[[ $(sha "$B/kexec.sh") == "$KEXEC_SHA256" ]] || die "kexec.sh changed"
same "$B/vram.txt" "$REPO/boot/vram.txt" "FAT vram.txt"
same "$B/kexec.sh" "$REPO/boot/kexec.sh" "FAT kexec.sh"
same "$B/bzImage" "$R/boot/vmlinuz-$KVER" "FAT bzImage = /boot/vmlinuz-$KVER"
same "$B/initrd.img" "$R/boot/initrd.img-$KVER" "FAT initrd.img = /boot/initrd.img-$KVER"
[[ ! -f $kernel_dir/kernel/bzImage ]] ||
  same "$B/bzImage" "$kernel_dir/kernel/bzImage" "FAT bzImage = the built kernel"
"$CHECK" "$B/bzImage" "$B/initrd.img" "$B/cmdline.txt"
[[ $(od -An -t x2 -j $((0x206)) -N 2 -- "$B/bzImage" | tr -d ' ') == 020f ]] ||
  die "bzImage is not boot protocol 2.15"
version=$(strings "$B/bzImage" | awk -v k="$KVER (" 'index($0, k) == 1 && !n { print; n = 1 }')
[[ -n $version ]] || die "FAT bzImage is not a $KVER kernel"
ok "bzImage: protocol 2.15, $version"

# ------------------------------------------------------------------ kernel

status=$(dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${db:Status-Abbrev}${Version}' linux-ps5)
[[ $status == "hi $DEB_VERSION" ]] || die "linux-ps5 is not $DEB_VERSION, installed and held: $status"
others=$(dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${db:Status-Abbrev} ${Package}\n' \
  'linux-image-*' 'linux-modules-*' 'linux-headers-*' 2>/dev/null | awk '$1 ~ /^.i/ { print $2 }' || true)
[[ -z $others ]] || die "other kernel packages are installed: ${others//$'\n'/ }"
modules=$(cd -- "$R/usr/lib/modules" && find . -mindepth 1 -maxdepth 1 -printf '%P\n')
[[ $modules == "$KVER" ]] || die "kernel module trees: ${modules//$'\n'/ }"
[[ -f $R/usr/share/doc/linux-ps5/LICENSE.amdgpu ]] || die "the VCN firmware licence is missing"
grep -qF 'linux-generic*' "$R/etc/apt/preferences.d/99-ps5-kernel" || die "the generic kernel pin is missing"
if [[ -n $deb ]]; then
  [[ $(dpkg-deb -f "$deb" Version) == "$DEB_VERSION" ]] || die "$deb is not $DEB_VERSION"
  dpkg-deb --fsys-tarfile "$deb" | tar -t | sed -n 's|^\.\(/.*[^/]\)$|\1|p' | sort > "$tmp/deb.list"
  sed 's|^/\.$||' "$R/var/lib/dpkg/info/linux-ps5.list" | grep . | sort > "$tmp/installed.list"
  comm -23 "$tmp/deb.list" "$tmp/installed.list" > "$tmp/missing.list"
  [[ ! -s $tmp/missing.list ]] || die "files from $deb are not installed: $(head -n3 "$tmp/missing.list" | tr '\n' ' ')"
  # md5sums covers every regular file the package installed.
  (cd -- "$R" && md5sum --quiet -c "var/lib/dpkg/info/linux-ps5.md5sums") ||
    die "linux-ps5 files changed after installation"
fi
ok "linux-ps5 $DEB_VERSION installed and held, only /usr/lib/modules/$KVER, no other kernel"
m=$R/usr/lib/modules/$KVER
for f in modules.dep modules.alias modules.dep.bin; do
  [[ -s $m/$f ]] || die "$f is missing; depmod did not run"
done
mt_filename=$(in_root modinfo -k "$KVER" -F filename btusb)
in_root modinfo -k "$KVER" -F parm btusb |
  grep -qxF 'ps5_tx_ep:PS5 MediaTek BT: bulk OUT endpoint for ACL (0 = default) (int)' ||
  die "btusb ($mt_filename) does not have the MediaTek bulk OUT fix"
grep -qaF 'encryption pending, deferring psm' "$m/kernel/net/bluetooth/bluetooth.ko" ||
  die "bluetooth.ko does not have the l2cap encryption-pending change"
ok "btusb has ps5_tx_ep and bluetooth.ko has the l2cap deferral"

# ---------------------------------------------------- boot-file updates

for f in ps5-check-boot-files ps5-update-boot-files; do
  same "$R/usr/local/sbin/$f" "$F/$f" "/usr/local/sbin/$f"
  mode_is "$R/usr/local/sbin/$f" 755 "/usr/local/sbin/$f"
done
same "$R/etc/initramfs/post-update.d/zz-ps5-boot-files" "$F/zz-ps5-boot-files" \
  "/etc/initramfs/post-update.d/zz-ps5-boot-files"
mode_is "$R/etc/initramfs/post-update.d/zz-ps5-boot-files" 755 zz-ps5-boot-files
[[ ! -e $R/etc/kernel/postinst.d/zz-update-boot ]] || die "the 7.1.7 zz-update-boot hook is installed"
for script in preinst postinst prerm postrm; do
  [[ -x $R/var/lib/dpkg/info/linux-ps5.$script ]] || die "linux-ps5 has no $script"
done
grep -qF '/usr/local/sbin/ps5-update-boot-files --precheck' "$R/var/lib/dpkg/info/linux-ps5.preinst" ||
  die "the linux-ps5 preinst does not check /boot/efi"
grep -qF 'update-initramfs' "$R/var/lib/dpkg/info/linux-ps5.postinst" ||
  die "the linux-ps5 postinst does not build the initramfs"
ok "linux-ps5 checks /boot/efi first; update-initramfs updates it through zz-ps5-boot-files"

# --------------------------------------------------------------- initramfs

same "$R/etc/initramfs-tools/modules" "$F/initramfs-modules" "/etc/initramfs-tools/modules"
same "$R/etc/initramfs-tools/conf.d/ps5-control" "$F/initramfs-ps5.conf" \
  "/etc/initramfs-tools/conf.d/ps5-control"
same "$R/etc/initramfs-tools/hooks/ps5-firmware" "$F/initramfs-hook-ps5-firmware" \
  "/etc/initramfs-tools/hooks/ps5-firmware"
same "$R/etc/modprobe.d/ps5-amdgpu.conf" "$F/ps5-amdgpu.conf" "/etc/modprobe.d/ps5-amdgpu.conf"
grep -qx 'options amdgpu dpm=0 gpu_recovery=0 force_1080p=1' "$R/etc/modprobe.d/ps5-amdgpu.conf" ||
  die "ps5-amdgpu.conf does not set dpm=0 gpu_recovery=0 force_1080p=1"
grep -qx 'CONFIG_RD_ZSTD=y' "$R/boot/config-$KVER" || die "the kernel cannot unpack a zstd initramfs"
contents=$(in_root lsinitramfs "/boot/initrd.img-$KVER")
grep -Eq "(^|/)lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu\\.ko(\\.zst)?\$" <<<"$contents" ||
  die "the initramfs has no amdgpu.ko for $KVER"
if grep -E '(^|/)((mlan|moal|mt7921e|mt7925e|btusb|ps5-cpufreq|ps5-gpufreq)\.ko(\.zst)?|pcieuartiw620[^/]*)$' <<<"$contents"; then
  die "the initramfs has a Wi-Fi driver, its firmware, btusb or a frequency driver"
fi
in_root unmkinitramfs "/boot/initrd.img-$KVER" /tmp/initramfs
audit=$R/tmp/initramfs
mapfile -t policy < <(find "$audit" -type f -path '*/etc/modprobe.d/ps5-amdgpu.conf' -print)
((${#policy[@]} == 1)) || die "the initramfs has ${#policy[@]} copies of ps5-amdgpu.conf"
same "${policy[0]}" "$F/ps5-amdgpu.conf" "ps5-amdgpu.conf in the initramfs"
mapfile -t bt_rule < <(find "$audit" -type f -path '*/lib/udev/rules.d/99-ps5-bt-phantom.rules' -print)
((${#bt_rule[@]} == 1)) || die "the initramfs has ${#bt_rule[@]} copies of 99-ps5-bt-phantom.rules"
same "${bt_rule[0]}" "$F/99-ps5-bt-phantom.rules" "99-ps5-bt-phantom.rules in the initramfs"
for entry in "${GPU_FIRMWARE[@]}"; do
  read -r name expected <<<"$entry"
  mapfile -t matches < <(find "$audit" -type f -path "*/usr/lib/firmware/amdgpu/cyan_skillfish2_$name.bin" -print)
  ((${#matches[@]} == 1)) || die "the initramfs has ${#matches[@]} copies of cyan_skillfish2_$name.bin"
  [[ $(sha "${matches[0]}") == "$expected" ]] ||
    die "cyan_skillfish2_$name.bin in the initramfs is not the pinned file"
  [[ $(sha "$R/usr/lib/firmware/amdgpu/cyan_skillfish2_$name.bin") == "$expected" ]] ||
    die "/usr/lib/firmware/amdgpu/cyan_skillfish2_$name.bin is not the pinned file"
done
rm -rf -- "$audit"
ok "initramfs: amdgpu for $KVER, the 8 pinned Cyan Skillfish 2 files, ps5-amdgpu.conf, the MediaTek Bluetooth rule; no Wi-Fi, btusb or frequency drivers"

# ------------------------------------------------------------------- Wi-Fi

mt7921e=$m/$MT7921E_MODULE
[[ -f $mt7921e ]] || die "$MT7921E_MODULE is not installed"
grep -q "^$MT7921E_MODULE:" "$m/modules.dep" || die "mt7921e.ko is not in modules.dep"
mt_filename=$(in_root modinfo -k "$KVER" -F filename mt7921e)
mt_filename=/usr${mt_filename#/usr}
[[ $mt_filename == "/usr/lib/modules/$KVER/$MT7921E_MODULE" ]] ||
  die "modprobe resolves mt7921e to $mt_filename"
cfg80211_vermagic=$(in_root modinfo -k "$KVER" -F vermagic cfg80211)
[[ $cfg80211_vermagic == "$KVER "* ]] || die "cfg80211 vermagic is not for $KVER: $cfg80211_vermagic"
[[ $(in_root modinfo -k "$KVER" -F vermagic mt7921e) == "$cfg80211_vermagic" ]] ||
  die "mt7921e vermagic does not match cfg80211"
actual=$(in_root modinfo -k "$KVER" -F alias mt7921e | sort)
expected=$(printf '%s\n' "${MT7921E_ALIASES[@]}" | sort)
[[ $actual == "$expected" ]] || die "unexpected mt7921e PCI aliases"
for alias in "${MT7921E_ALIASES[@]}"; do
  grep -qxF "alias $alias mt7921e" "$m/modules.alias" ||
    die "modules.alias has no mt7921e entry for $alias"
done
same "$R/etc/modprobe.d/ps5-mt7921e.conf" "$F/ps5-mt7921e.conf" "/etc/modprobe.d/ps5-mt7921e.conf"
for firmware in "${MEDIATEK_FIRMWARE[@]}"; do
  [[ -f $R/usr/lib/firmware/$firmware || -f $R/usr/lib/firmware/$firmware.zst ]] ||
    die "MediaTek firmware is missing: /usr/lib/firmware/${firmware}[.zst]"
done
for entry in "${MT7925_FIRMWARE[@]}"; do
  read -r firmware expected <<<"$entry"
  [[ -f $R/usr/lib/firmware/$firmware ]] ||
    die "MT7925 firmware is missing: /usr/lib/firmware/$firmware"
  [[ $(sha "$R/usr/lib/firmware/$firmware") == "$expected" ]] ||
    die "MT7925 firmware does not match the pinned payload: $firmware"
done

mt7925e=$m/$MT7925E_MODULE
[[ -f $mt7925e ]] || die "$MT7925E_MODULE is not installed"
grep -q "^$MT7925E_MODULE:" "$m/modules.dep" || die "mt7925e.ko is not in modules.dep"
mt7925_filename=$(in_root modinfo -k "$KVER" -F filename mt7925e)
mt7925_filename=/usr${mt7925_filename#/usr}
[[ $mt7925_filename == "/usr/lib/modules/$KVER/$MT7925E_MODULE" ]] ||
  die "modprobe resolves mt7925e to $mt7925_filename"
[[ $(in_root modinfo -k "$KVER" -F vermagic mt7925e) == "$cfg80211_vermagic" ]] ||
  die "mt7925e vermagic does not match cfg80211"
mt7925_deps=$(in_root modinfo -k "$KVER" -F depends mt7925e | tr ',' '\n' | sort | tr '\n' ' ')
[[ $mt7925_deps == 'mt76 mt76-connac-lib mt7925-common mt792x-lib ' ]] ||
  die "unexpected mt7925e dependencies: $mt7925_deps"
actual=$(in_root modinfo -k "$KVER" -F alias mt7925e | sort)
expected=$(printf '%s\n' "${MT7925E_ALIASES[@]}" | sort)
[[ $actual == "$expected" ]] || die "unexpected mt7925e PCI aliases"
for alias in "${MT7925E_ALIASES[@]}"; do
  grep -qxF "alias $alias mt7925e" "$m/modules.alias" ||
    die "modules.alias has no mt7925e entry for $alias"
done
in_root modinfo -k "$KVER" -F parm mt7925e |
  grep -qxF 'disable_aspm:disable PCI ASPM support (bool)' ||
  die "mt7925e has no disable_aspm parameter"
actual=$(in_root modinfo -k "$KVER" -F firmware mt7925e | sort)
expected=$(printf '%s\n' "${MT7925E_DECLARED_FIRMWARE[@]}" | sort)
[[ $actual == "$expected" ]] || die "unexpected mt7925e firmware declarations"
in_root modinfo -k "$KVER" -F firmware btmtk |
  grep -qxF 'mediatek/mt7925/BT_RAM_CODE_MT7925_1_1_hdr.bin' ||
  die "btmtk does not declare the MT7925 Bluetooth firmware"

mt_blocks=$(grep -rsE '^[[:space:]]*(blacklist|install)[[:space:]]+(mt7921e|mt7925e|btusb)([[:space:]]|$)' \
  "$R/etc/modprobe.d" "$R/usr/lib/modprobe.d" || true)
[[ -z $mt_blocks ]] || die "mt7921e, mt7925e or btusb is blocked: $mt_blocks"
mt_loads=$(grep -Rslw -e mt7921e -e mt7925e "$R/etc/modules-load.d" "$R/usr/lib/modules-load.d" \
  2>/dev/null || true)
[[ -z $mt_loads ]] || die "a MediaTek Wi-Fi driver is force-loaded by: ${mt_loads//$'\n'/ }"
ok "mt7921e and mt7925e in-tree, selected only by PCI aliases; PS5 MediaTek firmware present"

for module in mlan moal; do
  f=$m/updates/ps5-iw620/$module.ko
  [[ -f $f ]] || die "$module.ko is not in updates/ps5-iw620"
  if [[ -f $kernel_dir/ps5-iw620/$module.ko ]]; then
    same "$f" "$kernel_dir/ps5-iw620/$module.ko" "$module.ko = the built module"
  fi
  grep -qxF "/usr/lib/modules/$KVER/updates/ps5-iw620/$module.ko" "$R/var/lib/dpkg/info/linux-ps5.list" ||
    die "$module.ko is not from the linux-ps5 package"
  grep -q "^updates/ps5-iw620/$module.ko:" "$m/modules.dep" || die "$module.ko is not in modules.dep"
  file=$(in_root modinfo -k "$KVER" -F filename "$module")
  [[ /usr${file#/usr} == "/usr/lib/modules/$KVER/updates/ps5-iw620/$module.ko" ]] ||
    die "modprobe resolves $module to $file"
  [[ $(in_root modinfo -k "$KVER" -F vermagic "$module") == "$cfg80211_vermagic" ]] ||
    die "$module.ko was not built for this kernel"
done
grep -qxF "alias $IW620_ALIAS moal" "$m/modules.alias" || die "modules.alias has no IW620 entry"
same "$R/usr/local/sbin/ps5-iw620-firmware" "$F/ps5-iw620-firmware" "/usr/local/sbin/ps5-iw620-firmware"
if ! grep -qF '= 0x1b4b ] || continue' "$R/usr/local/sbin/ps5-iw620-firmware" ||
   ! grep -qF '= 0x2b56 ] || continue' "$R/usr/local/sbin/ps5-iw620-firmware"; then
  die "ps5-iw620-firmware is not gated to PCI 1b4b:2b56"
fi
grep -qxF "sizes=\"$IW620_DUMP_SIZES\"" "$R/usr/local/sbin/ps5-iw620-firmware" ||
  die "ps5-iw620-firmware does not accept the 11.xx and 13.xx loader dump sizes"
same "$R/etc/modprobe.d/ps5-iw620.conf" "$F/ps5-iw620.conf" "/etc/modprobe.d/ps5-iw620.conf"
blocks=$(grep -rsE '^[[:space:]]*(blacklist|install)[[:space:]]+(moal|mlan)([[:space:]]|$)' \
  "$R/etc/modprobe.d" "$R/usr/lib/modprobe.d" || true)
[[ $blocks == "$R/etc/modprobe.d/ps5-iw620.conf:blacklist moal" ]] ||
  die "expected only 'blacklist moal' in ps5-iw620.conf, found: ${blocks:-nothing}"
firmware=$(find "$R" "$B" -xdev -name 'pcieuartiw620*' -print)
[[ -z $firmware ]] || die "IW620 firmware in the image: $firmware"
ok "IW620 driver in updates/ps5-iw620 from linux-ps5, for this kernel, exact-ID gated, takes 11.xx and 13.xx dumps, no IW620 firmware in the image"

same "$R/etc/NetworkManager/conf.d/zz-ps5-iw620.conf" "$F/zz-ps5-iw620.conf" \
  "/etc/NetworkManager/conf.d/zz-ps5-iw620.conf"
same "$R/etc/NetworkManager/conf.d/dns.conf" "$PROFILE/nm-dns.conf" "/etc/NetworkManager/conf.d/dns.conf"
nm_config=$(in_root NetworkManager --print-config)
nm_get() { # section key
  awk -v s="[$1]" -v k="$2" '
    $0 == s { in_s = 1; next }
    /^\[/ { in_s = 0 }
    in_s && (p = index($0, "=")) > 0 {
      key = substr($0, 1, p - 1)
      sub(/[[:space:]]+$/, "", key)
      if (key == k) {
        v = substr($0, p + 1)
        sub(/^[[:space:]]+/, "", v)
      }
    }
    END { print v }
  ' <<<"$nm_config"
}
[[ $(nm_get connection wifi.powersave) == 2 ]] || die "NetworkManager wifi.powersave is not 2"
[[ $(nm_get connection wifi.cloned-mac-address) == permanent ]] ||
  die "NetworkManager wifi.cloned-mac-address is not permanent"
[[ $(nm_get device wifi.scan-rand-mac-address) == no ]] ||
  die "NetworkManager wifi.scan-rand-mac-address is not no"
ok "NetworkManager in effect: powersave 2 (off), permanent MAC, no scan MAC randomization"

# --------------------------------------------------------------- Bluetooth

same "$R/etc/udev/rules.d/99-ps5-bt-phantom.rules" "$F/99-ps5-bt-phantom.rules" \
  "/etc/udev/rules.d/99-ps5-bt-phantom.rules"
for product in 3603 3605; do
  [[ $(grep -cF "ATTRS{idProduct}==\"$product\"" \
    "$R/etc/udev/rules.d/99-ps5-bt-phantom.rules") == 2 ]] ||
    die "the MediaTek rule does not deauthorize both phantom interfaces for 0e8d:$product"
  [[ $(grep -cF "ATTR{idProduct}==\"$product\"" \
    "$R/etc/udev/rules.d/99-ps5-bt-phantom.rules") == 1 ]] ||
    die "the MediaTek rule does not disable autosuspend for 0e8d:$product"
done
same "$R/etc/modprobe.d/btusb-ps5.conf" "$F/btusb-ps5.conf" "/etc/modprobe.d/btusb-ps5.conf"
for value in AlwaysPairable=true PairableTimeout=0 ControllerMode=dual \
  Privacy=device JustWorksRepairing=always AutoEnable=true; do
  [[ $(grep -cxF "$value" "$R/etc/bluetooth/main.conf") == 1 ]] ||
    die "/etc/bluetooth/main.conf does not contain exactly one '$value'"
done
[[ $(grep -cxF 'UserspaceHID=true' "$R/etc/bluetooth/input.conf") == 1 ]] ||
  die "/etc/bluetooth/input.conf does not select the userspace HID path"
for module in btusb btmtk bluetooth uhid hid_playstation; do
  in_root modinfo -k "$KVER" -F filename "$module" >/dev/null || die "$module is not installed"
done
same "$R/usr/local/sbin/ps5-bt-quiet" "$F/ps5-bt-quiet" "/usr/local/sbin/ps5-bt-quiet"
ok "MediaTek phantom-interface rule, btusb autosuspend off, BlueZ pairing policy and userspace HID"

# ------------------------------------------------------- frequency drivers

for module in ps5-cpufreq ps5-gpufreq; do
  f=$(find "$m/kernel/drivers" -name "$module.ko" -print)
  [[ -n $f ]] || die "$module.ko is not installed"
  if grep -qw -e "${module//-/_}" -e "$module" "$m/modules.alias" ||
    grep -rqsw -e "${module//-/_}" -e "$module" "$R/etc/modules-load.d" "$R/usr/lib/modules-load.d"; then
    die "$module would be loaded at boot"
  fi
done
same "$R/usr/local/sbin/ps5-performance" "$F/ps5-performance" "/usr/local/sbin/ps5-performance"
grep -qF '0x13da|0x13dc)' "$R/usr/local/sbin/ps5-performance" ||
  die "ps5-performance does not skip both PS5 Pro GPU IDs"
pro_guard_line=$(grep -nF '0x13da|0x13dc)' "$R/usr/local/sbin/ps5-performance" | cut -d: -f1)
first_freq_load=$(grep -nE 'modprobe ps5_(gpu|cpu)freq' "$R/usr/local/sbin/ps5-performance" | head -1 | cut -d: -f1)
((pro_guard_line < first_freq_load)) || die "ps5-performance checks for PS5 Pro after loading a frequency driver"
ok "ps5-cpufreq and ps5-gpufreq installed, loaded only by ps5-performance"

# ---------------------------------------------------------------- services

for f in ps5fan ps5-amdgpu-reprobe ps5-performance ps5-iw620-firmware ps5-bt-quiet \
  ps5-boot-report ps5-ssh-host-keys; do
  same "$R/etc/systemd/system/$f.service" "$F/$f.service" "/etc/systemd/system/$f.service"
done
same "$R/etc/systemd/system/ps5-boot-report.timer" "$F/ps5-boot-report.timer" \
  "/etc/systemd/system/ps5-boot-report.timer"
grep -qxF 'TimeoutStartSec=120' "$R/etc/systemd/system/ps5-boot-report.service" ||
  die "ps5-boot-report.service does not allow the bounded probes to finish"
grep -qF "timeout 30 sh <<'PS5_SYSFS'" "$R/usr/local/sbin/ps5-boot-report" ||
  die "ps5-boot-report does not bound aggregate sysfs telemetry"
for f in ps5-boot-report ps5-amdgpu-reprobe ps5-fan-target; do
  same "$R/usr/local/sbin/$f" "$F/$f" "/usr/local/sbin/$f"
done
same "$R/etc/default/ps5-fan" "$F/ps5-fan.conf" "/etc/default/ps5-fan"
same "$R/etc/modules-load.d/ps5-ethernet.conf" "$F/ps5-ethernet.conf" "/etc/modules-load.d/ps5-ethernet.conf"
for unit in ssh.service ssh.socket; do
  same "$R/etc/systemd/system/$unit.d/10-ps5-host-keys.conf" "$F/ps5-ssh-keys.conf" \
    "/etc/systemd/system/$unit.d/10-ps5-host-keys.conf"
done
[[ ! -e $R/usr/local/sbin/ps5_fan_max ]] || die "the 7.1.7 image's ps5_fan_max is installed"
for unit in NetworkManager.service ssh.service bluetooth.service grow-rootfs.service \
  systemd-resolved.service ps5-ssh-host-keys.service ps5fan.service \
  ps5-amdgpu-reprobe.service ps5-performance.service ps5-iw620-firmware.service \
  ps5-bt-quiet.service ps5-boot-report.timer; do
  state=$(systemctl --root="$R" is-enabled "$unit" 2>/dev/null || true)
  [[ $state == enabled ]] || die "$unit is $state, not enabled"
done
for unit in systemd-networkd-wait-online.service sleep.target suspend.target \
  hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
  [[ -L $R/etc/systemd/system/$unit && $(readlink "$R/etc/systemd/system/$unit") == /dev/null ]] ||
    die "$unit is not masked"
done
[[ ! -e $R/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service ]] ||
  die "systemd-networkd-wait-online still has an enable link"
[[ $(readlink "$R/etc/systemd/system/display-manager.service") == /usr/lib/systemd/system/gdm.service &&
   -f $R/usr/lib/systemd/system/gdm.service ]] || die "the display manager is not GDM"
[[ $(readlink "$R/etc/systemd/system/default.target") == */graphical.target ]] ||
  die "the default target is not graphical.target"
grep -qxF 'After=NetworkManager.service ssh.service ps5fan.service ps5-amdgpu-reprobe.service ps5-performance.service' \
  "$R/etc/systemd/system/gdm.service.d/10-ps5-bringup.conf" || die "the GDM ordering drop-in is missing"
[[ -z $(find "$R/etc/systemd/system" "$R/usr/lib/systemd/system" -name 'ps5-stage-firmware*' -print) ]] ||
  die "the 7.1.7 package's ps5-stage-firmware is installed"
in_root systemd-analyze verify \
  /etc/systemd/system/ps5fan.service \
  /etc/systemd/system/ps5-amdgpu-reprobe.service \
  /etc/systemd/system/ps5-performance.service \
  /etc/systemd/system/ps5-iw620-firmware.service \
  /etc/systemd/system/ps5-bt-quiet.service \
  /etc/systemd/system/ps5-ssh-host-keys.service \
  /etc/systemd/system/ps5-boot-report.service \
  /etc/systemd/system/ps5-boot-report.timer
ok "PS5 services enabled, GDM after them, networkd wait-online and Linux sleep masked"

# ------------------------------------------------------- account and keys

[[ $(cat "$R/etc/hostname") == ps5 ]] || die "hostname is not ps5"
grep -qx '127.0.1.1 ps5' "$R/etc/hosts" || die "/etc/hosts has no 127.0.1.1 ps5"
fstab=$(grep -Ev '^[[:space:]]*(#|$)' "$R/etc/fstab")
[[ $fstab == "LABEL=$ROOT_LABEL / ext4 defaults 0 1"$'\n''LABEL=boot /boot/efi vfat defaults 0 1' ]] ||
  die "unexpected /etc/fstab: $fstab"
[[ $(awk -F: '$1 == "ps5" { print $3 ":" $4 ":" $7 }' "$R/etc/passwd") == 1000:1000:/bin/bash ]] ||
  die "no ps5 account with uid 1000"
for group in sudo video input render; do
  awk -F: -v g="$group" '$1 == g && ("," $4 ",") ~ /,ps5,/ { found = 1 } END { exit !found }' \
    "$R/etc/group" || die "ps5 is not in $group"
done
ps5_shadow=$(awk -F: '$1 == "ps5" { print $2 }' "$R/etc/shadow")
case $ps5_shadow in
  ''|'!'*|'*'*) die "the ps5 account is locked or has no password" ;;
esac
case $(awk -F: '$1 == "root" { print $2 }' "$R/etc/shadow") in
  '!'*|'*'*) ;;
  *) die "the root account is not locked" ;;
esac
grep -qxF 'ps5 ALL=(ALL:ALL) NOPASSWD: ALL' "$R/etc/sudoers.d/90-ps5-control" || die "no sudo rule for ps5"
mode_is "$R/etc/sudoers.d/90-ps5-control" 440 /etc/sudoers.d/90-ps5-control
grep -qxF 'AutomaticLogin=ps5' "$R/etc/gdm3/custom.conf" || die "GDM does not log in ps5"
grep -qxF 'AllowUsers ps5' "$R/etc/ssh/sshd_config.d/10-ps5-control.conf" || die "sshd does not allow ps5"
grep -qxF 'PermitRootLogin no' "$R/etc/ssh/sshd_config.d/10-ps5-control.conf" || die "sshd allows root"
[[ -z $(find "$R/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -print) ]] || die "SSH host keys in the image"
[[ -z $(find "$R" -xdev \( -name authorized_keys -o -name authorized_keys2 \) -print) ]] ||
  die "authorized_keys in the image"
[[ -f $R/etc/machine-id && ! -L $R/etc/machine-id && ! -s $R/etc/machine-id ]] ||
  die "/etc/machine-id is not an empty file"
[[ $(readlink "$R/var/lib/dbus/machine-id") == /etc/machine-id ]] || die "/var/lib/dbus/machine-id is not a link"
ok "hostname ps5, fstab, ps5 account with sudo and GDM autologin, root locked, no SSH host keys, authorized_keys or machine ID"

# ------------------------------------------------------- module build tree

# Out-of-tree modules for this kernel are built with build/ (gcc 14). Note
# which glibc its host tools need, since they were built on Debian trixie.
glibc_need=
while IFS= read -r -d '' tool; do
  [[ $(head -c 4 -- "$tool" | od -An -t x1 | tr -d ' \n') == 7f454c46 ]] || continue
  glibc_need+=$(objdump -p -- "$tool" 2>/dev/null |
    sed -n 's/.*GLIBC_\([0-9][0-9.]*\).*/\1/p' || true)$'\n'
done < <(find "$m/build/scripts" -type f -perm -u+x -print0)
glibc_need=$(grep . <<<"$glibc_need" | sort -V | tail -n1 || true)
glibc_have=$(in_root ldd --version | sed -n '1s/.* \([0-9][0-9.]*\)$/\1/p' || true)
if [[ -n $glibc_need && -n $glibc_have ]] &&
  [[ $(printf '%s\n%s\n' "$glibc_need" "$glibc_have" | sort -V | tail -n1) != "$glibc_have" ]]; then
  echo "note: build/scripts tools need glibc $glibc_need, the image has $glibc_have"
else
  ok "build/scripts tools need glibc ${glibc_need:-?}, the image has ${glibc_have:-?}"
fi

if [[ -n $packages ]]; then
  dpkg-query --admindir="$R/var/lib/dpkg" -W -f='${db:Status-Abbrev} ${Package} ${Version}\n' |
    awk '$1 ~ /^.i/ { print $2, $3 }' > "$packages"
  ok "package list: $packages ($(wc -l < "$packages") packages)"
fi

echo
echo "All checks passed: $image"
