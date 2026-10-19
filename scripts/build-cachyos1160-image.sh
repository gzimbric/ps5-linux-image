#!/usr/bin/env bash
# Build the public CachyOS image for PS5 firmware 11.60.
#
# Starts from the official ps5-cachyos.img.xz (ps5-linux/ps5-linux-image
# release built 2026-08-29 from upstream commit 52db0a4), rebuilds the 11.60
# initramfs from the image's own packages, writes the tested FAT boot files,
# and applies the distros/cachyos1160 profile to the root filesystem. Every
# step is checked against pinned sizes and hashes, and the build stops at the
# first mismatch. See distros/cachyos1160/README.md.
#
# Run as root on Linux x86_64 (a GitHub ubuntu-24.04 runner, or a privileged
# linux/amd64 container). Host tools: curl (only when downloading), xz,
# util-linux, e2fsprogs, dosfstools, gcc with static glibc (libc6-dev on
# Debian/Ubuntu) and binutils.
set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C
umask 022

BASE_URL=https://pub-561df4012f1a46fbbdf618d5cc5941f6.r2.dev/ps5-cachyos.img.xz
BASE_XZ_SHA256=9a29ca88c408cd290c19f4693f764251aab5698bb55c9f38fbf06c2764f21db1
BASE_SIZE=12582912000

# GPT layout of the base image, in 512-byte sectors.
P1_START=1024000 P1_SECTORS=23549952  # ext4, LABEL=cachyos
P2_START=2048 P2_SECTORS=1021952      # FAT32, LABEL=boot
P1_SHA256=10ecc168fc9450c5c87f447391b75215973bb2e124c7e6ba96398027274b774e
P2_SHA256=afde7e45f97308fb2ae63ece674a65821b34e8f8eafbc202b076069c29c3d949

# Root files the initramfs build depends on or must leave alone.
MKINITCPIO_CONF_SHA256=6329d81d796228ef0a2c3ee3b16be551f4403dcb129defbab91aa4279f40bc77
ROOT_VMLINUZ_SHA256=11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
ROOT_INITRD_SHA256=ba6dd1d0e69149e6be60bfd655b4bfc8cac0eee546e1ba478f3bdd1240965a56

# The five files the 11.60 loader reads from the FAT partition. It refuses
# a bzImage or initrd.img whose size differs from these.
FAT_FILES=(bzImage initrd.img cmdline.txt vram.txt kexec.sh)
declare -A FAT_SIZE=(
  [bzImage]=12702720
  [initrd.img]=54376639
  [cmdline.txt]=118
  [vram.txt]=11
  [kexec.sh]=136
)
declare -A FAT_SHA256=(
  [bzImage]=11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
  [initrd.img]=c37b88569ef8f05b0b4ae432a8ec0fd323b7a3537a6441f8c45baaad45ff061f
  [cmdline.txt]=aec7a85e9ebcf36e4bdaeb89242b898e17817acd40c16db57a3bb9c3117b1da8
  [vram.txt]=bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0
  [kexec.sh]=0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52
)

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=$REPO/distros/cachyos1160

usage() {
  cat <<EOF
Usage: sudo $0 [--base-xz PATH | --base-url URL] [--output PATH] [--work-dir DIR]

  --base-xz PATH  use a local copy of ps5-cachyos.img.xz instead of
                  downloading $BASE_URL
  --base-url URL  download the base from URL instead (for example a mirror);
                  it must still match the pinned SHA-256
  --output PATH   image to write (default: output/ps5-cachyos1160.img);
                  the root change list goes next to it as
                  cachyos1160-root-changes.txt
  --work-dir DIR  scratch space for the download, mounts and manifests
                  (default: work/cachyos1160)
EOF
}

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
sha() { local h; h=$(sha256sum -- "$1"); printf '%s\n' "${h%% *}"; }

expect_sha() { # file sha256 label
  local got
  got=$(sha "$1")
  [[ $got == "$2" ]] || die "$3: sha256 $got, expected $2"
  printf 'ok  %s  %s\n' "$2" "$3"
}

expect_file() { # file size sha256 label
  local size
  [[ -f $1 && ! -L $1 ]] || die "$4: missing or not a regular file"
  size=$(stat -c %s -- "$1")
  [[ $size == "$2" ]] || die "$4: $size bytes, expected $2"
  expect_sha "$1" "$3" "$4 ($2 bytes)"
}

region_sha() { # start-sector sector-count
  local h
  h=$(dd if="$PARTIAL" bs=4M iflag=skip_bytes,count_bytes \
        skip=$(($1 * 512)) count=$(($2 * 512)) status=none | sha256sum)
  printf '%s\n' "${h%% *}"
}

# ---------------------------------------------------------------- arguments

base_xz=
output=$REPO/output/ps5-cachyos1160.img
work=$REPO/work/cachyos1160
while (($#)); do
  case $1 in
    --base-xz) (($# >= 2)) || die "--base-xz needs a path"; base_xz=$2; shift 2 ;;
    --base-url) (($# >= 2)) || die "--base-url needs a URL"; BASE_URL=$2; shift 2 ;;
    --output) (($# >= 2)) || die "--output needs a path"; output=$2; shift 2 ;;
    --work-dir) (($# >= 2)) || die "--work-dir needs a path"; work=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

((EUID == 0)) || die "run as root"
[[ $(uname -s) == Linux ]] || die "run on Linux"
[[ $(uname -m) == x86_64 ]] || die "run on x86_64 (or in a linux/amd64 container)"

required=(awk blkid chroot dd diff e2fsck find fsck.fat gcc install join unshare
  losetup mount mountpoint nproc od partx readelf realpath sed sha256sum sort
  stat umount xargs xz)
[[ -n $base_xz ]] || required+=(curl)
for cmd in "${required[@]}"; do
  command -v "$cmd" >/dev/null || die "missing host command: $cmd"
done

output=$(realpath -m -- "$output")
work=$(realpath -m -- "$work")
[[ -z $base_xz ]] || base_xz=$(realpath -e -- "$base_xz")
changes_out=$(dirname -- "$output")/cachyos1160-root-changes.txt
PARTIAL=$output.partial
[[ ! -e $output ]] || die "$output already exists; move or delete it first"

for f in cmdline.txt root-changes.expected config/ps5-amdgpu.conf \
  tools/build_1160_initrd.sh files/hostname files/ps5-iw620-noautoload.conf \
  files/ps5-ethernet.conf files/00-ps5-linux-ps5-guard.hook \
  files/ps5-amdgpu-reprobe files/ps5-amdgpu-reprobe.service \
  files/ps5-boot-report files/ps5-boot-report.service \
  files/ps5-boot-report.timer files/ps5_fan_max.c files/ps5fan.service; do
  [[ -f $PROFILE/$f ]] || die "profile file missing: distros/cachyos1160/$f"
done
expect_file "$PROFILE/cmdline.txt" "${FAT_SIZE[cmdline.txt]}" \
  "${FAT_SHA256[cmdline.txt]}" "profile cmdline.txt"

mkdir -p -- "$work" "$(dirname -- "$output")"
R=$work/root   # root filesystem, mounted read-write for the chroot
M=$work/mnt    # read-only and FAT mounts
mkdir -p -- "$R" "$M"
mountpoint -q "$R" && die "$R is already a mount point"
mountpoint -q "$M" && die "$M is already a mount point"

# ------------------------------------------------------- mounts and cleanup

MOUNTS=()
LOOPS=()

mount_at() { # mount-point, then mount(8) arguments
  local target=$1
  shift
  mount "$@" "$target"
  MOUNTS+=("$target")
}

umount_all() {
  local i
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    umount -- "${MOUNTS[i]}"
  done
  MOUNTS=()
}

attach() { # variable start-sector sector-count
  local dev
  dev=$(losetup --find --show --offset $(($2 * 512)) \
    --sizelimit $(($3 * 512)) -- "$PARTIAL")
  LOOPS+=("$dev")
  printf -v "$1" '%s' "$dev"
  echo "attached $dev (sectors $2 + $3)"
}

cleanup() {
  local rc=$? i
  trap - EXIT
  set +e
  for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
    if mountpoint -q -- "${MOUNTS[i]}"; then
      umount -- "${MOUNTS[i]}" || umount -l -- "${MOUNTS[i]}"
    fi
  done
  for i in "${LOOPS[@]}"; do
    losetup -d "$i"
  done
  if ((rc != 0)); then
    rm -f -- "$PARTIAL"
    printf 'Build failed (exit %s). Nothing was written to %s.\n' "$rc" "$output" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# The chroot runs the image's own binaries as root; give it no network.
in_root() {
  unshare --net chroot "$R" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/bin HOME=/root LC_ALL=C "$@"
}

# --------------------------------------------------------------- manifests

# One line per path under a mounted root, sorted, tab separated:
#   path type mode uid gid size sha256|link-target
# size and sha256 are "-" except for regular files; link-target is "-"
# except for symlinks.
root_manifest() { # mounted-root output
  local root=$1 out=$2 tmp n_meta n_paths n_files n_hashed bad
  tmp=$(mktemp -d "$work/manifest.XXXXXX")
  (cd -- "$root" && find . -xdev -printf '%P\t%y\t%#m\t%U\t%G\t%s\t%l\n') |
    awk -F'\t' -v OFS='\t' '$1 == "" { $1 = "." }
      { if ($2 != "f") $6 = "-"; if ($2 != "l") $7 = "-"; print }' |
    sort -t $'\t' -k1,1 > "$tmp/meta"
  mkdir "$tmp/h"
  # Each batch writes its own file so parallel output cannot interleave.
  # shellcheck disable=SC2016 # expanded by the inner sh, not here
  (cd -- "$root" && find . -xdev -type f -print0 |
    xargs -0 -r -P "$(nproc)" -n 512 sh -c \
      'sha256sum -z "$@" > "$(mktemp -p "$0" b.XXXXXXXX)"' "$tmp/h")
  find "$tmp/h" -type f -name 'b.*' -exec cat {} + | tr '\0' '\n' |
    sed -E 's#^([0-9a-f]{64})  \./#\1\t#' |
    awk -F'\t' -v OFS='\t' '{ h = $1; print substr($0, length(h) + 2), h }' |
    sort -t $'\t' -k1,1 > "$tmp/hash"
  n_meta=$(wc -l < "$tmp/meta")
  n_paths=$(cd -- "$root" && find . -xdev -print0 | tr -cd '\0' | wc -c)
  n_files=$(awk -F'\t' '$2 == "f"' "$tmp/meta" | wc -l)
  n_hashed=$(wc -l < "$tmp/hash")
  [[ $n_meta == "$n_paths" && $n_files == "$n_hashed" ]] ||
    die "manifest count mismatch for $root (paths $n_meta/$n_paths, files $n_hashed/$n_files)"
  join -t $'\t' -a1 -o '1.1,1.2,1.3,1.4,1.5,1.6,1.7,2.2' "$tmp/meta" "$tmp/hash" |
    awk -F'\t' -v OFS='\t' '{ if ($2 == "f") $7 = $8; NF = 7; print }' > "$out"
  bad=$(awk -F'\t' '$2 == "f" && $7 !~ /^[0-9a-f]{64}$/' "$out" | wc -l)
  ((bad == 0)) || die "$bad files in $root have no hash"
  rm -rf -- "$tmp"
  echo "manifest: $(wc -l < "$out") paths, $n_files files"
}

# ------------------------------------------------------------ base image

log "Base image"
if [[ -z $base_xz ]]; then
  base_xz=$work/ps5-cachyos.img.xz
  if [[ -f $base_xz && $(sha "$base_xz") == "$BASE_XZ_SHA256" ]]; then
    echo "using the cached download $base_xz"
  else
    rm -f -- "$base_xz" "$base_xz.part"
    curl -fL --retry 5 --retry-delay 10 --connect-timeout 30 \
      -o "$base_xz.part" -- "$BASE_URL"
    mv -- "$base_xz.part" "$base_xz"
  fi
fi
expect_sha "$base_xz" "$BASE_XZ_SHA256" "base ps5-cachyos.img.xz"

rm -f -- "$PARTIAL"
xz -dc -- "$base_xz" |
  dd of="$PARTIAL" bs=4M iflag=fullblock conv=sparse status=none
size=$(stat -c %s -- "$PARTIAL")
[[ $size == "$BASE_SIZE" ]] || die "base image is $size bytes, expected $BASE_SIZE"
echo "ok  $BASE_SIZE bytes  raw image"

layout=$(partx -g -o NR,START,SECTORS -- "$PARTIAL" | awk '{ print $1, $2, $3 }')
[[ $layout == "1 $P1_START $P1_SECTORS"$'\n'"2 $P2_START $P2_SECTORS" ]] ||
  die "unexpected partition table: $layout"
echo "ok  p1 $P1_START+$P1_SECTORS, p2 $P2_START+$P2_SECTORS  partition table"

[[ $(region_sha "$P2_START" "$P2_SECTORS") == "$P2_SHA256" ]] ||
  die "p2 (FAT) region does not match the official image"
echo "ok  $P2_SHA256  p2 region before changes"
[[ $(region_sha "$P1_START" "$P1_SECTORS") == "$P1_SHA256" ]] ||
  die "p1 (root) region does not match the official image"
echo "ok  $P1_SHA256  p1 region before changes"

# ------------------------------------------------------------- fan helper

log "Fan helper"
fan_bin=$work/ps5_fan_max
rm -f -- "$fan_bin"
gcc -O2 -static -o "$fan_bin" "$PROFILE/files/ps5_fan_max.c"
elf_header=$(readelf -h "$fan_bin")
[[ $elf_header =~ Machine:[[:space:]]+Advanced\ Micro\ Devices\ X86-64 ]] ||
  die "ps5_fan_max is not an x86_64 binary"
elf_segments=$(readelf -l "$fan_bin")
[[ $elf_segments != *'program interpreter'* ]] || die "ps5_fan_max is not statically linked"
fan_size=$(stat -c %s -- "$fan_bin")
fan_sha=$(sha "$fan_bin")
gcc_version=$(gcc --version)
echo "${gcc_version%%$'\n'*}"
echo "ps5_fan_max: static x86_64, $fan_size bytes, sha256 $fan_sha"

# ----------------------------------------------------- partitions, before

log "Partitions before changes"
attach P1_DEV "$P1_START" "$P1_SECTORS"
attach P2_DEV "$P2_START" "$P2_SECTORS"
[[ $(blkid -p -o value -s TYPE "$P1_DEV") == ext4 &&
   $(blkid -p -o value -s LABEL "$P1_DEV") == cachyos ]] || die "p1 is not ext4 LABEL=cachyos"
[[ $(blkid -p -o value -s TYPE "$P2_DEV") == vfat &&
   $(blkid -p -o value -s LABEL "$P2_DEV") == boot ]] || die "p2 is not vfat LABEL=boot"
e2fsck -fn "$P1_DEV"
fsck.fat -n "$P2_DEV"

mount_at "$M" -t ext4 -o ro,noload "$P1_DEV"
root_manifest "$M" "$work/root-before.tsv"
umount_all

# ------------------------------------------------------------- root changes

log "Mounting the root filesystem"
mount_at "$R" -t ext4 -o rw,noatime "$P1_DEV"
mount_at "$R/proc" -t proc proc
mount_at "$R/sys" --bind /sys
mount_at "$R/dev" --bind /dev
mount_at "$R/tmp" -t tmpfs -o mode=1777 tmpfs
mount_at "$R/run" -t tmpfs -o mode=0755 tmpfs
in_root /usr/bin/uname -m

expect_sha "$R/etc/mkinitcpio.conf" "$MKINITCPIO_CONF_SHA256" "/etc/mkinitcpio.conf"
expect_sha "$R/boot/vmlinuz-7.1.7" "$ROOT_VMLINUZ_SHA256" "/boot/vmlinuz-7.1.7"
expect_sha "$R/boot/initrd.img-7.1.7" "$ROOT_INITRD_SHA256" "/boot/initrd.img-7.1.7"

# The initramfs has to be built before anything else changes in the root:
# the modconf hook packs every file in /etc/modprobe.d into it.
log "Building the 11.60 initramfs in the root"
install -d -m 0755 "$R/tmp/ps5-initrd/tools" "$R/tmp/ps5-initrd/config"
install -m 0755 "$PROFILE/tools/build_1160_initrd.sh" "$R/tmp/ps5-initrd/tools/"
install -m 0644 "$PROFILE/config/ps5-amdgpu.conf" "$R/tmp/ps5-initrd/config/"
in_root /usr/bin/bash /tmp/ps5-initrd/tools/build_1160_initrd.sh \
  7.1.7 /tmp/ps5-initrd-1160.img
initrd=$work/initrd.img
cp -- "$R/tmp/ps5-initrd-1160.img" "$initrd"
expect_file "$initrd" "${FAT_SIZE[initrd.img]}" "${FAT_SHA256[initrd.img]}" "rebuilt initrd.img"

add_file() { # mode source path-in-root
  [[ ! -e $R/$3 && ! -L $R/$3 ]] || die "/$3 already exists in the base image"
  install -o 0 -g 0 -m "$1" -- "$2" "$R/$3"
}
add_link() { # target path-in-root
  [[ ! -e $R/$2 && ! -L $R/$2 ]] || die "/$2 already exists in the base image"
  ln -s -- "$1" "$R/$2"
}
add_dir() { # path-in-root
  [[ ! -e $R/$1 && ! -L $R/$1 ]] || die "/$1 already exists in the base image"
  install -d -o 0 -g 0 -m 0755 -- "$R/$1"
}

log "First-boot defaults (hostname ps5, UTC)"
add_file 0644 "$PROFILE/files/hostname" etc/hostname
! grep -q '^127\.0\.1\.1' "$R/etc/hosts" || die "/etc/hosts already has 127.0.1.1"
[[ -z $(tail -c1 -- "$R/etc/hosts") ]] || die "/etc/hosts does not end in a newline"
printf '127.0.1.1 ps5\n' >> "$R/etc/hosts"
[[ -f $R/usr/share/zoneinfo/UTC ]] || die "/usr/share/zoneinfo/UTC missing"
add_link /usr/share/zoneinfo/UTC etc/localtime
[[ ! -e $R/etc/ps5-first-boot-done ]] || die "first-boot marker already present"
install -o 0 -g 0 -m 0644 /dev/null "$R/etc/ps5-first-boot-done"

log "Wi-Fi off by default"
add_file 0644 "$PROFILE/files/ps5-iw620-noautoload.conf" etc/modprobe.d/ps5-iw620-noautoload.conf
stage_link=$R/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service
[[ -L $stage_link && $(readlink -- "$stage_link") == ../ps5-stage-firmware.service ]] ||
  die "unexpected ps5-stage-firmware.service link"
rm -- "$stage_link"
pullins=$(find "$R/etc/systemd/system" "$R/usr/lib/systemd/system" \
  \( -path '*.wants/*' -o -path '*.requires/*' \) -name ps5-stage-firmware.service -print)
[[ -z $pullins ]] || die "ps5-stage-firmware.service is still pulled in: $pullins"

log "Fan"
add_file 0755 "$fan_bin" usr/local/sbin/ps5_fan_max
add_file 0644 "$PROFILE/files/ps5fan.service" etc/systemd/system/ps5fan.service
add_link /etc/systemd/system/ps5fan.service \
  etc/systemd/system/multi-user.target.wants/ps5fan.service

log "Display re-detect"
add_file 0755 "$PROFILE/files/ps5-amdgpu-reprobe" usr/local/sbin/ps5-amdgpu-reprobe
add_file 0644 "$PROFILE/files/ps5-amdgpu-reprobe.service" \
  etc/systemd/system/ps5-amdgpu-reprobe.service
add_link /etc/systemd/system/ps5-amdgpu-reprobe.service \
  etc/systemd/system/multi-user.target.wants/ps5-amdgpu-reprobe.service

log "Boot report"
add_file 0755 "$PROFILE/files/ps5-boot-report" usr/local/sbin/ps5-boot-report
add_file 0644 "$PROFILE/files/ps5-boot-report.service" etc/systemd/system/ps5-boot-report.service
add_file 0644 "$PROFILE/files/ps5-boot-report.timer" etc/systemd/system/ps5-boot-report.timer
add_dir etc/systemd/system/timers.target.wants
add_link /etc/systemd/system/ps5-boot-report.timer \
  etc/systemd/system/timers.target.wants/ps5-boot-report.timer

log "Pin linux-ps5"
[[ $(grep -c '^#IgnorePkg   =$' "$R/etc/pacman.conf") == 1 ]] ||
  die "IgnorePkg anchor not found once in /etc/pacman.conf"
! grep -q '^IgnorePkg' "$R/etc/pacman.conf" || die "IgnorePkg is already set"
sed -i 's/^#IgnorePkg   =$/&\nIgnorePkg   = linux-ps5/' "$R/etc/pacman.conf"
grep -n '^IgnorePkg' "$R/etc/pacman.conf"
add_dir etc/pacman.d/hooks
add_file 0644 "$PROFILE/files/00-ps5-linux-ps5-guard.hook" \
  etc/pacman.d/hooks/00-ps5-linux-ps5-guard.hook

log "Ethernet"
add_file 0644 "$PROFILE/files/ps5-ethernet.conf" etc/modules-load.d/ps5-ethernet.conf

expect_sha "$R/etc/mkinitcpio.conf" "$MKINITCPIO_CONF_SHA256" "/etc/mkinitcpio.conf (unchanged)"
expect_sha "$R/boot/vmlinuz-7.1.7" "$ROOT_VMLINUZ_SHA256" "/boot/vmlinuz-7.1.7 (unchanged)"
expect_sha "$R/boot/initrd.img-7.1.7" "$ROOT_INITRD_SHA256" "/boot/initrd.img-7.1.7 (unchanged)"
umount_all

# ----------------------------------------------------- root checks, after

log "Root filesystem checks"
e2fsck -fn "$P1_DEV"
mount_at "$M" -t ext4 -o ro,noload "$P1_DEV"
keys=$(find "$M/etc/ssh" -name 'ssh_host_*' -print)
[[ -z $keys ]] || die "SSH host keys in the image: $keys"
authkeys=$(find "$M" -xdev \( -name authorized_keys -o -name authorized_keys2 \) -print)
[[ -z $authkeys ]] || die "authorized_keys in the image: $authkeys"
iw620=$(find "$M" -xdev -name 'pcieuartiw620*' -print)
[[ -z $iw620 ]] || die "IW620 firmware in the image: $iw620"
[[ -f $M/etc/ps5-first-boot-done ]] || die "first-boot marker missing"
echo "ok  no SSH host keys, no authorized_keys, no IW620 firmware, first-boot marker present"
root_manifest "$M" "$work/root-after.tsv"
umount_all

# Every path that differs between the two manifests.
awk -F'\t' -v OFS='\t' '
  NR == FNR { before[$1] = $0; next }
  { after[$1] = $0 }
  END {
    for (p in after) {
      if (!(p in before)) print "A", after[p]
      else if (before[p] != after[p]) print "M", after[p]
    }
    for (p in before) if (!(p in after)) print "R", before[p]
  }' "$work/root-before.tsv" "$work/root-after.tsv" |
  tr '\t' ' ' | sort -k2,2 > "$work/root-changes"

sed -e '/^#/d' -e '/^$/d' \
  -e "s/@PS5_FAN_MAX_SIZE@/$fan_size/" -e "s/@PS5_FAN_MAX_SHA256@/$fan_sha/" \
  "$PROFILE/root-changes.expected" | sort -k2,2 > "$work/root-changes.expected"
if ! diff -u "$work/root-changes.expected" "$work/root-changes"; then
  die "root changes differ from distros/cachyos1160/root-changes.expected"
fi
echo "ok  $(wc -l < "$work/root-changes") root changes, all expected"

# ------------------------------------------------------------- FAT changes

log "FAT boot partition"
mount_at "$M" -t vfat -o rw "$P2_DEV"
for name in initrd.img cmdline.txt; do
  case $name in
    initrd.img) src=$initrd ;;
    cmdline.txt) src=$PROFILE/cmdline.txt ;;
  esac
  cp -- "$src" "$M/$name.new"
  mv -f -- "$M/$name.new" "$M/$name"
done
sync
umount_all

dirty=$(od -An -tx1 -j 65 -N 1 "$P2_DEV" | tr -d ' ')
if [[ $dirty != 00 ]]; then
  echo "FAT dirty flag is $dirty; running fsck.fat -a"
  rc=0
  fsck.fat -a "$P2_DEV" || rc=$?
  ((rc <= 1)) || die "fsck.fat -a failed ($rc)"
fi
fsck.fat -n "$P2_DEV"

mount_at "$M" -t vfat -o ro "$P2_DEV"
listing=$(cd -- "$M" && find . -mindepth 1 -printf '%P\n' | sort)
[[ $listing == "$(printf '%s\n' "${FAT_FILES[@]}" | sort)" ]] ||
  die "unexpected FAT contents: ${listing//$'\n'/ }"
for name in "${FAT_FILES[@]}"; do
  expect_file "$M/$name" "${FAT_SIZE[$name]}" "${FAT_SHA256[$name]}" "FAT $name"
done
umount_all

# ------------------------------------------------------------------ finish

for dev in "${LOOPS[@]}"; do
  losetup -d "$dev"
done
LOOPS=()
size=$(stat -c %s -- "$PARTIAL")
[[ $size == "$BASE_SIZE" ]] || die "image is $size bytes, expected $BASE_SIZE"
sync

{
  echo "# Root filesystem changes in $(basename -- "$output") (p1, LABEL=cachyos),"
  echo "# against the official ps5-cachyos.img.xz (sha256 $BASE_XZ_SHA256)."
  echo "# Columns: status path type mode uid gid size sha256-or-link-target"
  echo "# Status: A added, M modified (new values), R removed (old values)."
  cat "$work/root-changes"
  echo "# Old values of modified paths:"
  awk '$1 == "M" { print $2 }' "$work/root-changes" | while read -r path; do
    awk -F'\t' -v p="$path" '$1 == p { $1 = $1; print "# was " $0 }' "$work/root-before.tsv"
  done
} > "$changes_out.new"
mv -f -- "$changes_out.new" "$changes_out"
mv -- "$PARTIAL" "$output"

log "Done"
cat "$changes_out"
echo
echo "Image:        $output ($BASE_SIZE bytes)"
echo "Root changes: $changes_out"
