#!/usr/bin/env bash
# Build the CachyOS 7.3 image for PS5 firmware 11.60.
#
# Starts from the same official ps5-cachyos.img.xz as the cachyos1160 recipe
# (ps5-linux/ps5-linux-image build 2026-10-29 from upstream commit d68a854,
# kernel 7.2.3 and patches 0e91638), replaces its kernel with the 7.3.0 package from
# scripts/build-linux-ps5-k73.sh and scripts/package-linux-ps5-k73.sh, adds
# the IW620 Wi-Fi modules built for that kernel, applies the
# distros/cachyos1160-k73 profile, builds the initramfs, and writes the new
# boot files to the FAT partition. Every step is checked, and the build stops
# at the first mismatch. See distros/cachyos1160-k73/README.md.
#
# The boot files are not the exact sizes the earlier 11.60 loaders require.
# The image needs a bounded 11.60 loader build (linux-1160-dma-e820-bounded or
# linux-1160-dma-e820-bounded-wifi, gzimbric/ps5-linux-loader 98925a2); the
# build checks the files against that loader's limits.
#
# Run as root on Linux x86_64 (a GitHub ubuntu-24.04 runner, or a privileged
# linux/amd64 container). Host tools: curl (only when downloading), xz,
# util-linux, e2fsprogs, dosfstools and binutils.
set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C
umask 022

BASE_URL=https://pub-561df4012f1a46fbbdf618d5cc5941f6.r2.dev/ps5-cachyos.img.xz
BASE_XZ_SHA256=2019d6c5c2fd14ed4849dd908481c9edafc3961f61742bfb2ba0565938784c2f
BASE_SIZE=12582912000

# GPT layout of the base image, in 512-byte sectors.
P1_START=1024000 P1_SECTORS=23549952  # ext4, LABEL=cachyos
P2_START=2048 P2_SECTORS=1021952      # FAT32, LABEL=boot
P1_SHA256=4ee48dc54a591a6760322a5d33b0565d003c183860bee13ce864c00538872321
P2_SHA256=38ca1646cd6ba3d34e4049aba5c9fde364101711e7438634bae71f30d82683ff

# The base image's kernel, and the files the build depends on.
OLD_KVER=7.2.3
OLD_PACKAGE="linux-ps5 7.2.3-1"
MKINITCPIO_CONF_SHA256=6329d81d796228ef0a2c3ee3b16be551f4403dcb129defbab91aa4279f40bc77
ROOT_OLD_VMLINUZ_SHA256=ee6062e2c1fb792023e5a70cf3ab35263f53460ab9ae17221683d03f8c209594
ROOT_OLD_INITRD_SHA256=63cc53e7cc663c83f964f9c29540cd2c275ad77fb6988e2d04127eb5bd2c1a45
BLUEZ_MAIN_CONF_SHA256=d3762eb24785530885ffa51fffc81b078f5bb362d83cf2462989dbb6b2081912
BLUEZ_INPUT_CONF_SHA256=d85aa14cab44a058d1ae13a0774961d011da735b49ae4d6546e2cc2e396c6d3d

KVER=7.3.0
NEW_PACKAGE="linux-ps5 7.3.0-4"
PACKAGE_FILE=linux-ps5-7.3.0-4-x86_64.pkg.tar.zst
IW620_ALIAS='pci:v00001B4Bd00002B56sv*sd*bc*sc*i*'

# The FAT partition holds these five files. bzImage and initrd.img come from
# this build and are checked against the bounded loader; the other three are
# pinned. cmdline.txt is the cachyos1160 one (no nokaslr: KASLR is what keeps
# the kernel out of the DMA reservation), and vram.txt and kexec.sh are the
# official image's.
FAT_FILES=(bzImage initrd.img cmdline.txt vram.txt kexec.sh)
declare -A FAT_SIZE=([cmdline.txt]=118 [vram.txt]=11 [kexec.sh]=136)
declare -A FAT_SHA256=(
  [cmdline.txt]=aec7a85e9ebcf36e4bdaeb89242b898e17817acd40c16db57a3bb9c3117b1da8
  [vram.txt]=bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0
  [kexec.sh]=0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52
)
# The base image's FAT bzImage (the 7.2.3 kernel), replaced here.
OLD_FAT_BZIMAGE_SHA256=ee6062e2c1fb792023e5a70cf3ab35263f53460ab9ae17221683d03f8c209594

# Files of the old package that the profile puts back unchanged: the
# Bluetooth helper the base image runs at boot.
BT_QUIET_SHA256=d31222ead065ee2ab6fd55edda285741814bb8a470c9c26d355963ab39b46240
BT_QUIET_SERVICE_SHA256=4cc7b16adbc3ef4d4a132d55e7e0bacd4e9bc9192096507d6e125301d821f32c
OLD_SESSION_SELECT_SHA256=f6fb96619489228225ccbc2d7f782d5791c5a2e6d9f66f5d0f843d64d35d1f74
OLD_GAMESCOPE_SESSION_SHA256=5b50d084becac615c8a27670f79d99d7aa9bbbfcd40ba50e3903005e493cb85a
OLD_NEXT_SESSION_SHA256=df84d3e62a7e09d6ec7a9f6bb3f2f2060eed95618c315ac0ea2f6d62efd91b0e

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PROFILE=$REPO/distros/cachyos1160-k73
CHECK=$PROFILE/files/ps5-1160-check-boot-files

usage() {
  cat <<EOF
Usage: sudo $0 --kernel-dir DIR [--base-xz PATH | --base-url URL]
               [--output PATH] [--work-dir DIR]

  --kernel-dir DIR  output of scripts/build-linux-ps5-k73.sh and
                    scripts/package-linux-ps5-k73.sh (default:
                    linux-bin/cachyos1160-k73)
  --base-xz PATH    use a local copy of ps5-cachyos.img.xz instead of
                    downloading $BASE_URL
  --base-url URL    download the base from URL instead (for example a
                    mirror); it must still match the pinned SHA-256
  --output PATH     image to write (default: output/ps5-cachyos1160-k73.img);
                    cachyos1160-k73-root-changes.txt and
                    cachyos1160-k73-kernel-swap.txt go next to it
  --work-dir DIR    scratch space for the download, mounts and manifests
                    (default: work/cachyos1160-k73)
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
kernel_dir=$REPO/linux-bin/cachyos1160-k73
output=$REPO/output/ps5-cachyos1160-k73.img
work=$REPO/work/cachyos1160-k73
while (($#)); do
  case $1 in
    --kernel-dir) (($# >= 2)) || die "--kernel-dir needs a path"; kernel_dir=$2; shift 2 ;;
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

required=(awk blkid chroot cmp dd diff e2fsck find fsck.fat install join
  unshare losetup mount mountpoint nproc od partx readelf realpath sed
  sha256sum sort stat umount xargs xz)
[[ -n $base_xz ]] || required+=(curl)
for cmd in "${required[@]}"; do
  command -v "$cmd" >/dev/null || die "missing host command: $cmd"
done

output=$(realpath -m -- "$output")
work=$(realpath -m -- "$work")
kernel_dir=$(realpath -e -- "$kernel_dir")
[[ -z $base_xz ]] || base_xz=$(realpath -e -- "$base_xz")
out_dir=$(dirname -- "$output")
changes_out=$out_dir/cachyos1160-k73-root-changes.txt
swap_out=$out_dir/cachyos1160-k73-kernel-swap.txt
boot_out=$out_dir/cachyos1160-k73-boot-files.txt
PARTIAL=$output.partial
[[ ! -e $output ]] || die "$output already exists; move or delete it first"

for f in README.md cmdline.txt root-changes.expected config/ps5-amdgpu.conf \
  tools/build_1160_initrd.sh files/hostname files/ps5-ethernet.conf \
  files/ps5-amdgpu-reprobe files/ps5-amdgpu-reprobe.service \
  files/ps5-boot-report files/ps5-boot-report.service \
  files/ps5-boot-report.timer files/ps5-fan.conf files/ps5-fan-target \
  files/ps5fan.service \
  files/ps5-iw620.conf files/ps5-iw620-firmware files/ps5-iw620-firmware.service \
  files/20-ps5-iw620.conf files/ps5-performance files/ps5-performance.service \
  files/ps5-stage-gpu-firmware files/ps5-stage-gpu-firmware.service \
  files/ps5-bt-quiet files/ps5-bt-quiet.service \
  files/ps5-1160-check-boot-files files/ps5-update-boot-files \
  files/05-ps5-boot-files-precheck.hook files/95-ps5-boot-files.hook; do
  [[ -f $PROFILE/$f ]] || die "profile file missing: distros/cachyos1160-k73/$f"
done
[[ -f $REPO/distros/cachyos/files/steamos-session-select ]] ||
  die "profile file missing: distros/cachyos/files/steamos-session-select"
[[ -f $REPO/distros/cachyos/files/gamescope-session-ps5 ]] ||
  die "profile file missing: distros/cachyos/files/gamescope-session-ps5"
expect_file "$PROFILE/cmdline.txt" "${FAT_SIZE[cmdline.txt]}" \
  "${FAT_SHA256[cmdline.txt]}" "profile cmdline.txt"
! grep -q nokaslr "$PROFILE/cmdline.txt" || die "cmdline.txt must not contain nokaslr"
expect_sha "$PROFILE/files/ps5-bt-quiet" "$BT_QUIET_SHA256" "profile ps5-bt-quiet"
expect_sha "$PROFILE/files/ps5-bt-quiet.service" "$BT_QUIET_SERVICE_SHA256" \
  "profile ps5-bt-quiet.service"

mkdir -p -- "$work" "$out_dir"
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

# The paths a package owns, from its pacman database entry, without the
# trailing slash on directories.
package_paths() { # files-database-entry
  awk '/^%FILES%$/ { on = 1; next } /^%/ { on = 0 } on && NF { sub("/$", ""); print }' "$1"
}

# ---------------------------------------------------------- kernel inputs

log "Kernel package and Wi-Fi modules"
pkg=$kernel_dir/$PACKAGE_FILE
[[ -f $pkg && -f $pkg.sha256 ]] ||
  die "$pkg or its .sha256 is missing; run scripts/package-linux-ps5-k73.sh first"
pkg_sha=$(awk '{ print $1 }' "$pkg.sha256")
expect_sha "$pkg" "$pkg_sha" "$PACKAGE_FILE"
[[ -f $kernel_dir/kernel/bzImage ]] || die "$kernel_dir/kernel/bzImage is missing"
"$CHECK" "$kernel_dir/kernel/bzImage"
iw620=$kernel_dir/ps5-iw620
for module in mlan moal; do
  [[ -f $iw620/$module.ko ]] || die "$iw620/$module.ko is missing"
done
(cd -- "$iw620" && sha256sum -c --strict SHA256SUMS)
readelf -S "$iw620/moal.ko" | grep -qF .return_sites ||
  die "moal.ko has no .return_sites (built without objtool)"
mlan_size=$(stat -c %s -- "$iw620/mlan.ko") mlan_sha=$(sha "$iw620/mlan.ko")
moal_size=$(stat -c %s -- "$iw620/moal.ko") moal_sha=$(sha "$iw620/moal.ko")

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

p2_sha=$(region_sha "$P2_START" "$P2_SECTORS")
p1_sha=$(region_sha "$P1_START" "$P1_SECTORS")
region_mismatch=0
if [[ $p2_sha == "$P2_SHA256" ]]; then
  echo "ok  $P2_SHA256  p2 region before changes"
else
  echo "ERROR: p2 (FAT) sha256 $p2_sha, expected $P2_SHA256" >&2
  region_mismatch=1
fi
if [[ $p1_sha == "$P1_SHA256" ]]; then
  echo "ok  $P1_SHA256  p1 region before changes"
else
  echo "ERROR: p1 (root) sha256 $p1_sha, expected $P1_SHA256" >&2
  region_mismatch=1
fi

# A mutable upstream URL can legitimately move to a newer official image.
# When that happens, inventory the untrusted candidate read-only before
# stopping so all provenance pins can be reviewed from one CI run. Nothing
# from this diagnostic mount is copied into the output image.
if ((region_mismatch)); then
  log "Read-only candidate base inventory"
  attach CANDIDATE_P1_DEV "$P1_START" "$P1_SECTORS"
  attach CANDIDATE_P2_DEV "$P2_START" "$P2_SECTORS"
  mount_at "$M" -t ext4 -o ro,noload "$CANDIDATE_P1_DEV"
  printf 'pacman: '
  chroot "$M" /usr/bin/pacman -Q linux-ps5 || true
  for path in etc/mkinitcpio.conf etc/bluetooth/main.conf \
    etc/bluetooth/input.conf boot/vmlinuz-* boot/initrd.img-*; do
    for file in "$M"/$path; do
      [[ -f $file ]] || continue
      printf 'root  %s  %s\n' "$(sha "$file")" "${file#"$M"/}"
    done
  done
  find "$M/var/lib/pacman/local" -maxdepth 1 -type d -name 'linux-ps5-*' \
    -printf 'pacman-db  %f\n' | sort
  for path in usr/local/sbin/ps5-stage-gpu-firmware \
    etc/systemd/system/ps5-stage-gpu-firmware.service \
    etc/systemd/system/multi-user.target.wants/ps5-stage-gpu-firmware.service; do
    if [[ -L $M/$path ]]; then
      printf 'root-link  %s -> %s\n' "$path" "$(readlink "$M/$path")"
    elif [[ -f $M/$path ]]; then
      printf 'root-extra  %s  %s\n' "$(sha "$M/$path")" "$path"
    else
      printf 'root-missing  %s\n' "$path"
    fi
  done
  umount_all
  mount_at "$M" -t vfat -o ro "$CANDIDATE_P2_DEV"
  while IFS= read -r -d '' file; do
    printf 'fat  %s  %s bytes  %s\n' "$(sha "$file")" \
      "$(stat -c %s -- "$file")" "${file#"$M"/}"
  done < <(find "$M" -type f -print0 | sort -z)
  umount_all
  die "candidate base partition hashes do not match the reviewed pins"
fi

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
package_paths "$M/var/lib/pacman/local/linux-ps5-7.2.3-1/files" > "$work/package-old.paths"
echo "linux-ps5 7.2.3-1 owns $(wc -l < "$work/package-old.paths") paths"
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
expect_sha "$R/boot/vmlinuz-$OLD_KVER" "$ROOT_OLD_VMLINUZ_SHA256" "/boot/vmlinuz-$OLD_KVER"
expect_sha "$R/boot/initrd.img-$OLD_KVER" "$ROOT_OLD_INITRD_SHA256" "/boot/initrd.img-$OLD_KVER"
[[ $(in_root pacman -Q linux-ps5) == "$OLD_PACKAGE" ]] || die "the base image does not have $OLD_PACKAGE"

add_file() { # mode source path-in-root
  [[ ! -e $R/$3 && ! -L $R/$3 ]] || die "/$3 already exists"
  install -o 0 -g 0 -m "$1" -- "$2" "$R/$3"
}
replace_file() { # mode source path-in-root expected-old-sha256
  [[ -f $R/$3 && ! -L $R/$3 ]] || die "/$3 is missing or not a regular file"
  expect_sha "$R/$3" "$4" "/$3 before replacement"
  install -o 0 -g 0 -m "$1" -- "$2" "$R/$3.new"
  mv -f -- "$R/$3.new" "$R/$3"
}
add_link() { # target path-in-root
  [[ ! -e $R/$2 && ! -L $R/$2 ]] || die "/$2 already exists"
  ln -s -- "$1" "$R/$2"
}
add_dir() { # path-in-root
  [[ ! -e $R/$1 && ! -L $R/$1 ]] || die "/$1 already exists"
  install -d -o 0 -g 0 -m 0755 -- "$R/$1"
}

log "Replacing $OLD_PACKAGE with $NEW_PACKAGE"
# The pacman hook and IgnorePkg are added later, so they do not get in the
# way here. The package's install script is skipped; the initramfs and the
# FAT files are made further down. pacman.log is left alone.
# pacman runs ldconfig after the transaction. The libraries do not change,
# so /etc/ld.so.cache stays the same, but ldconfig's aux-cache records file
# times; put the base image's copy back so the root diff stays exact.
aux_cache=var/cache/ldconfig/aux-cache
[[ -f $R/$aux_cache ]] || die "/$aux_cache missing"
cp -a -- "$R/$aux_cache" "$work/aux-cache"
install -m 0644 -- "$pkg" "$R/tmp/$PACKAGE_FILE"
in_root pacman -U --noconfirm --noscriptlet --logfile /dev/null "/tmp/$PACKAGE_FILE"
rm -f -- "$R/tmp/$PACKAGE_FILE"
cp -a -- "$work/aux-cache" "$R/$aux_cache"
[[ $(in_root pacman -Q linux-ps5) == "$NEW_PACKAGE" ]] || die "linux-ps5 is not $NEW_PACKAGE"
[[ ! -e $R/usr/lib/modules/$OLD_KVER ]] || die "/usr/lib/modules/$OLD_KVER is still there"
[[ ! -e $R/boot/vmlinuz-$OLD_KVER ]] || die "/boot/vmlinuz-$OLD_KVER is still there"
module_dirs=$(cd -- "$R/usr/lib/modules" && find . -mindepth 1 -maxdepth 1 -printf '%P\n')
[[ $module_dirs == "$KVER" ]] || die "unexpected kernel module trees: ${module_dirs//$'\n'/ }"
cmp -- "$R/boot/vmlinuz-$KVER" "$kernel_dir/kernel/bzImage" ||
  die "/boot/vmlinuz-$KVER is not the kernel that was built"
echo "ok  /boot/vmlinuz-$KVER is the built bzImage"
# mkinitcpio made this one for the old kernel; no package owns it.
expect_sha "$R/boot/initrd.img-$OLD_KVER" "$ROOT_OLD_INITRD_SHA256" "/boot/initrd.img-$OLD_KVER"
rm -- "$R/boot/initrd.img-$OLD_KVER"

log "IW620 Wi-Fi driver"
# ps5-iw620.conf keeps udev from loading moal through its PCI alias.
# ps5-iw620-firmware.service copies this console's firmware from lib/nxp/ on
# the FAT partition, which only the Wi-Fi loader build writes, and then loads
# the driver by name. The image ships no Wi-Fi firmware.
updates=usr/lib/modules/$KVER/updates
add_dir "$updates"
add_dir "$updates/ps5-iw620"
add_file 0644 "$iw620/mlan.ko" "$updates/ps5-iw620/mlan.ko"
add_file 0644 "$iw620/moal.ko" "$updates/ps5-iw620/moal.ko"
add_file 0644 "$PROFILE/files/ps5-iw620.conf" etc/modprobe.d/ps5-iw620.conf
add_file 0644 "$PROFILE/files/20-ps5-iw620.conf" \
  etc/NetworkManager/conf.d/20-ps5-iw620.conf
add_file 0755 "$PROFILE/files/ps5-iw620-firmware" usr/local/sbin/ps5-iw620-firmware
add_file 0644 "$PROFILE/files/ps5-iw620-firmware.service" \
  etc/systemd/system/ps5-iw620-firmware.service
add_link /etc/systemd/system/ps5-iw620-firmware.service \
  etc/systemd/system/multi-user.target.wants/ps5-iw620-firmware.service
in_root depmod -a "$KVER"
# kmod reports paths under /lib/modules, which is /usr/lib/modules here.
module_file() { # module
  local f
  f=$(in_root modinfo -k "$KVER" -F filename "$1")
  printf '/usr%s\n' "${f#/usr}"
}
for module in mlan moal; do
  [[ $(module_file "$module") == "/$updates/ps5-iw620/$module.ko" ]] ||
    die "modprobe would not load /$updates/ps5-iw620/$module.ko"
  [[ $(in_root modinfo -k "$KVER" -F vermagic "$module") == \
     "$(in_root modinfo -k "$KVER" -F vermagic cfg80211)" ]] ||
    die "$module.ko was not built for this kernel"
done
grep -qxF "alias $IW620_ALIAS moal" "$R/usr/lib/modules/$KVER/modules.alias" ||
  die "modules.alias has no IW620 entry"
# Only the alias load of moal is blocked, and only by ps5-iw620.conf.
blocks=$(grep -rsE '^[[:space:]]*(blacklist|install)[[:space:]]+(moal|mlan)([[:space:]]|$)' \
  "$R/etc/modprobe.d" "$R/usr/lib/modprobe.d" || true)
[[ $blocks == "$R/etc/modprobe.d/ps5-iw620.conf:blacklist moal" ]] ||
  die "expected only 'blacklist moal' in ps5-iw620.conf, found: ${blocks:-nothing}"
# The old package's firmware stager and its sysinit link went with it.
pullins=$(find "$R/etc/systemd/system" "$R/usr/lib/systemd/system" \
  -name 'ps5-stage-firmware*' -print)
[[ -z $pullins ]] || die "ps5-stage-firmware is still installed: $pullins"
echo "ok  mlan.ko and moal.ko in /$updates/ps5-iw620, loaded by ps5-iw620-firmware, not by udev"

log "Bluetooth helper"
# ps5-bt-quiet came with the old package and is enabled in the base image.
# The 7.3.0 package has no /etc or /usr/local files, so put it back as it was.
add_file 0755 "$PROFILE/files/ps5-bt-quiet" usr/local/sbin/ps5-bt-quiet
add_file 0644 "$PROFILE/files/ps5-bt-quiet.service" etc/systemd/system/ps5-bt-quiet.service
add_link ../ps5-bt-quiet.service etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service

# The working Bazzite Deck v1.0.3 image uses BlueZ's userspace HID path and
# keeps the controller pairable while accepting the DualSense Just-Works
# repair. Apply those settings to the pinned CachyOS BlueZ files instead of
# carrying a foreign module or a separate pairing daemon. PairableTimeout=0,
# ControllerMode=dual and AutoEnable=true are current defaults; spelling them
# out makes the tested policy unambiguous in reports and across upgrades.
expect_sha "$R/etc/bluetooth/main.conf" "$BLUEZ_MAIN_CONF_SHA256" \
  "/etc/bluetooth/main.conf before PS5 policy"
expect_sha "$R/etc/bluetooth/input.conf" "$BLUEZ_INPUT_CONF_SHA256" \
  "/etc/bluetooth/input.conf before PS5 policy"
for old in '#AlwaysPairable = false' '#PairableTimeout = 0' \
  '#ControllerMode = dual' '#Privacy = off' \
  '#JustWorksRepairing = never' '#AutoEnable=true'; do
  [[ $(grep -cxF "$old" "$R/etc/bluetooth/main.conf") == 1 ]] ||
    die "/etc/bluetooth/main.conf does not contain exactly one '$old'"
done
sed -i \
  -e 's/^#AlwaysPairable = false$/AlwaysPairable=true/' \
  -e 's/^#PairableTimeout = 0$/PairableTimeout=0/' \
  -e 's/^#ControllerMode = dual$/ControllerMode=dual/' \
  -e 's/^#Privacy = off$/Privacy=device/' \
  -e 's/^#JustWorksRepairing = never$/JustWorksRepairing=always/' \
  -e 's/^#AutoEnable=true$/AutoEnable=true/' \
  "$R/etc/bluetooth/main.conf"
[[ $(grep -cxF '#UserspaceHID=true' "$R/etc/bluetooth/input.conf") == 1 ]] ||
  die "/etc/bluetooth/input.conf does not contain exactly one '#UserspaceHID=true'"
sed -i 's/^#UserspaceHID=true$/UserspaceHID=true/' "$R/etc/bluetooth/input.conf"
for value in AlwaysPairable=true PairableTimeout=0 ControllerMode=dual \
  Privacy=device JustWorksRepairing=always AutoEnable=true; do
  [[ $(grep -cxF "$value" "$R/etc/bluetooth/main.conf") == 1 ]] ||
    die "/etc/bluetooth/main.conf does not contain exactly one '$value'"
done
[[ $(grep -cxF 'UserspaceHID=true' "$R/etc/bluetooth/input.conf") == 1 ]] ||
  die "/etc/bluetooth/input.conf does not select the userspace HID path"
for module in btusb uhid hid_playstation; do
  file=$(module_file "$module")
  [[ $file == "/usr/lib/modules/$KVER/kernel/"*".ko" ]] ||
    die "$module is not installed ($file)"
done
echo "ok  Bazzite-compatible BlueZ pairing policy and userspace HID path"

log "Frequency drivers and guarded startup"
for module in ps5_cpufreq ps5_gpufreq; do
  file=$(module_file "$module")
  [[ $file == "/usr/lib/modules/$KVER/kernel/drivers/"*"/${module//_/-}.ko" ]] ||
    die "$module is not installed ($file)"
  [[ -z $(in_root modinfo -k "$KVER" -F alias "$module") ]] || die "$module has a module alias"
  if grep -qw "$module" "$R/usr/lib/modules/$KVER/modules.alias" ||
    grep -rqsw -e "$module" -e "${module//_/-}" "$R/etc/modules-load.d" \
      "$R/usr/lib/modules-load.d"; then
    die "$module would be loaded at boot"
  fi
  echo "ok  $module in $file, no alias, not in modules-load.d"
done
add_file 0755 "$PROFILE/files/ps5-performance" usr/local/sbin/ps5-performance
add_file 0644 "$PROFILE/files/ps5-performance.service" \
  etc/systemd/system/ps5-performance.service
add_link /etc/systemd/system/ps5-performance.service \
  etc/systemd/system/multi-user.target.wants/ps5-performance.service
add_file 0755 "$PROFILE/files/ps5-stage-gpu-firmware" \
  usr/local/sbin/ps5-stage-gpu-firmware
add_file 0644 "$PROFILE/files/ps5-stage-gpu-firmware.service" \
  etc/systemd/system/ps5-stage-gpu-firmware.service
add_link /etc/systemd/system/ps5-stage-gpu-firmware.service \
  etc/systemd/system/multi-user.target.wants/ps5-stage-gpu-firmware.service

log "First-boot defaults (hostname ps5, UTC)"
add_file 0644 "$PROFILE/files/hostname" etc/hostname
! grep -q '^127\.0\.1\.1' "$R/etc/hosts" || die "/etc/hosts already has 127.0.1.1"
[[ -z $(tail -c1 -- "$R/etc/hosts") ]] || die "/etc/hosts does not end in a newline"
printf '127.0.1.1 ps5\n' >> "$R/etc/hosts"
[[ -f $R/usr/share/zoneinfo/UTC ]] || die "/usr/share/zoneinfo/UTC missing"
add_link /usr/share/zoneinfo/UTC etc/localtime
[[ ! -e $R/etc/ps5-first-boot-done ]] || die "first-boot marker already present"
install -o 0 -g 0 -m 0644 /dev/null "$R/etc/ps5-first-boot-done"

log "Fan"
add_file 0644 "$PROFILE/files/ps5-fan.conf" etc/default/ps5-fan
add_file 0755 "$PROFILE/files/ps5-fan-target" usr/local/sbin/ps5-fan-target
add_file 0644 "$PROFILE/files/ps5fan.service" etc/systemd/system/ps5fan.service
add_link /etc/systemd/system/ps5fan.service \
  etc/systemd/system/multi-user.target.wants/ps5fan.service

log "Display re-detect"
add_file 0755 "$PROFILE/files/ps5-amdgpu-reprobe" usr/local/sbin/ps5-amdgpu-reprobe
add_file 0644 "$PROFILE/files/ps5-amdgpu-reprobe.service" \
  etc/systemd/system/ps5-amdgpu-reprobe.service
add_link /etc/systemd/system/ps5-amdgpu-reprobe.service \
  etc/systemd/system/multi-user.target.wants/ps5-amdgpu-reprobe.service

log "TTY session switching"
# The base image has the tty-session marker and starts Gaming Mode on tty1.
# Image 3 starts once in Plasma so Wi-Fi can be configured before Steam's
# first Gaming Mode bootstrap. The launcher returns to Gaming Mode after that
# desktop session. Steam's -steamos mode then uses the existing legacy selector
# path for Power > Switch to Desktop; that exact route passed on the console.
[[ -f $R/etc/ps5-use-tty-sessions ]] || die "/etc/ps5-use-tty-sessions is missing"
next_session=$R/home/steam/.config/ps5-next-session
expect_sha "$next_session" "$OLD_NEXT_SESSION_SHA256" \
  "/home/steam/.config/ps5-next-session before replacement"
[[ $(stat -c '%a %u %g' -- "$next_session") == '644 1000 1000' ]] ||
  die "/home/steam/.config/ps5-next-session has unexpected mode or owner"
install -o 1000 -g 1000 -m 0644 /dev/null "$next_session.new"
printf 'desktop\n' >"$next_session.new"
mv -f -- "$next_session.new" "$next_session"
[[ $(sha "$next_session") == e1eb72e080d8498fb7988921455ab4e66cc25cefd4b1a802446ed9e798e18b8b ]] ||
  die "could not set the first session to Plasma"
replace_file 0755 "$REPO/distros/cachyos/files/steamos-session-select" \
  usr/bin/steamos-session-select "$OLD_SESSION_SELECT_SHA256"
replace_file 0755 "$REPO/distros/cachyos/files/gamescope-session-ps5" \
  usr/bin/gamescope-session-ps5 "$OLD_GAMESCOPE_SESSION_SHA256"

log "Disable unsupported Linux sleep targets"
for target in sleep suspend hibernate hybrid-sleep suspend-then-hibernate; do
  add_link /dev/null "etc/systemd/system/$target.target"
done

log "Boot report"
add_file 0755 "$PROFILE/files/ps5-boot-report" usr/local/sbin/ps5-boot-report
add_file 0644 "$PROFILE/files/ps5-boot-report.service" etc/systemd/system/ps5-boot-report.service
add_file 0644 "$PROFILE/files/ps5-boot-report.timer" etc/systemd/system/ps5-boot-report.timer
add_dir etc/systemd/system/timers.target.wants
add_link /etc/systemd/system/ps5-boot-report.timer \
  etc/systemd/system/timers.target.wants/ps5-boot-report.timer

in_root systemd-analyze verify \
  /etc/systemd/system/ps5fan.service \
  /etc/systemd/system/ps5-amdgpu-reprobe.service \
  /etc/systemd/system/ps5-performance.service \
  /etc/systemd/system/ps5-stage-gpu-firmware.service \
  /etc/systemd/system/ps5-iw620-firmware.service \
  /etc/systemd/system/ps5-bt-quiet.service \
  /etc/systemd/system/ps5-boot-report.service \
  /etc/systemd/system/ps5-boot-report.timer

log "Ethernet"
add_file 0644 "$PROFILE/files/ps5-ethernet.conf" etc/modules-load.d/ps5-ethernet.conf

log "Kernel hold and boot-file updates"
# IgnorePkg keeps pacman -Syu away from linux-ps5. The 95 hook rebuilds the
# initramfs and updates /boot/efi after a kernel or initramfs change, once the
# files pass the bounded loader's checks. The 05 hook stops a linux-ps5
# change before it starts when /boot/efi is not mounted read-write.
add_file 0755 "$CHECK" usr/local/sbin/ps5-1160-check-boot-files
add_file 0755 "$PROFILE/files/ps5-update-boot-files" usr/local/sbin/ps5-update-boot-files
add_dir etc/pacman.d/hooks
add_file 0644 "$PROFILE/files/05-ps5-boot-files-precheck.hook" \
  etc/pacman.d/hooks/05-ps5-boot-files-precheck.hook
add_file 0644 "$PROFILE/files/95-ps5-boot-files.hook" etc/pacman.d/hooks/95-ps5-boot-files.hook
[[ $(grep -c '^#IgnorePkg   =$' "$R/etc/pacman.conf") == 1 ]] ||
  die "IgnorePkg anchor not found once in /etc/pacman.conf"
! grep -q '^IgnorePkg' "$R/etc/pacman.conf" || die "IgnorePkg is already set"
sed -i 's/^#IgnorePkg   =$/&\nIgnorePkg   = linux-ps5/' "$R/etc/pacman.conf"
grep -n '^IgnorePkg' "$R/etc/pacman.conf"

# The initramfs is built last, from the finished root: mkinitcpio's modconf
# hook packs every file in /etc/modprobe.d into it.
log "Building the initramfs"
install -d -m 0755 "$R/tmp/ps5-initrd/tools" "$R/tmp/ps5-initrd/config"
install -m 0755 "$PROFILE/tools/build_1160_initrd.sh" "$R/tmp/ps5-initrd/tools/"
install -m 0644 "$PROFILE/config/ps5-amdgpu.conf" "$R/tmp/ps5-initrd/config/"
in_root /usr/bin/bash /tmp/ps5-initrd/tools/build_1160_initrd.sh \
  "$KVER" "/boot/initrd.img-$KVER"
initrd=$work/initrd.img
cp -- "$R/boot/initrd.img-$KVER" "$initrd"
initrd_size=$(stat -c %s -- "$initrd")
initrd_sha=$(sha "$initrd")
"$CHECK" "$R/boot/vmlinuz-$KVER" "$initrd" "$PROFILE/cmdline.txt"

log "FAT boot partition"
# Mount the FAT partition where the console mounts it and let the image's
# own ps5-update-boot-files write bzImage and initrd.img, as the pacman hook
# will after a kernel update. cmdline.txt goes on first, since the update
# checks it too. The base image's old files are not kept as .prev copies.
mount_at "$R/boot/efi" -t vfat -o rw "$P2_DEV"
listing=$(cd -- "$R/boot/efi" && find . -mindepth 1 -printf '%P\n' | sort)
[[ $listing == "$(printf '%s\n' "${FAT_FILES[@]}" | sort)" ]] ||
  die "unexpected FAT contents before changes: ${listing//$'\n'/ }"
expect_sha "$R/boot/efi/bzImage" "$OLD_FAT_BZIMAGE_SHA256" "FAT bzImage before changes"
cp -- "$PROFILE/cmdline.txt" "$R/boot/efi/cmdline.txt.new"
mv -f -- "$R/boot/efi/cmdline.txt.new" "$R/boot/efi/cmdline.txt"
in_root /usr/local/sbin/ps5-update-boot-files --no-mkinitcpio --no-backup
sync

# pacman -Qkk lists the package files that changed since installation. Only
# the module indexes, which depmod rewrote after the Wi-Fi modules went in,
# may differ.
qkk=$(in_root pacman -Qkk linux-ps5 2>&1 || true)
altered=$(sed -nE 's#^(warning|error): linux-ps5: /([^ ]+) .*#\2#p' <<<"$qkk" | sort -u)
unexpected=$(grep -vE "^usr/lib/modules/$KVER/modules\.[a-z.]+$" <<<"$altered" || true)
[[ -z $unexpected ]] || die "linux-ps5 files changed after installation: ${unexpected//$'\n'/ }"
echo "ok  pacman -Qkk linux-ps5: $(grep -c . <<<"$altered" || true) module index files rewritten by depmod"
package_paths "$R/var/lib/pacman/local/linux-ps5-7.3.0-4/files" > "$work/package-new.paths"
echo "linux-ps5 7.3.0-4 owns $(wc -l < "$work/package-new.paths") paths"

expect_sha "$R/etc/mkinitcpio.conf" "$MKINITCPIO_CONF_SHA256" "/etc/mkinitcpio.conf (unchanged)"
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
for name in cmdline.txt vram.txt kexec.sh; do
  expect_file "$M/$name" "${FAT_SIZE[$name]}" "${FAT_SHA256[$name]}" "FAT $name"
done
cmp -- "$M/bzImage" "$kernel_dir/kernel/bzImage" || die "FAT bzImage is not the built kernel"
cmp -- "$M/initrd.img" "$initrd" || die "FAT initrd.img is not the built initramfs"
"$CHECK" "$M/bzImage" "$M/initrd.img" "$M/cmdline.txt" | tee "$work/boot-check.txt"
(cd -- "$M" && for name in "${FAT_FILES[@]}"; do
  printf '%s  %s  %s\n' "$(sha "$name")" "$(stat -c %s -- "$name")" "$name"
done) > "$work/boot-files"
umount_all

# ----------------------------------------------------- root checks, after

log "Root filesystem checks"
e2fsck -fn "$P1_DEV"
mount_at "$M" -t ext4 -o ro,noload "$P1_DEV"
keys=$(find "$M/etc/ssh" -name 'ssh_host_*' -print)
[[ -z $keys ]] || die "SSH host keys in the image: $keys"
authkeys=$(find "$M" -xdev \( -name authorized_keys -o -name authorized_keys2 \) -print)
[[ -z $authkeys ]] || die "authorized_keys in the image: $authkeys"
firmware=$(find "$M" -xdev -name 'pcieuartiw620*' -print)
[[ -z $firmware ]] || die "IW620 firmware in the image: $firmware"
[[ -f $M/etc/ps5-first-boot-done ]] || die "first-boot marker missing"
[[ $(cat "$M/etc/hostname") == ps5 ]] || die "hostname is not ps5"
echo "ok  no SSH host keys, no authorized_keys, no IW620 firmware, hostname ps5, first-boot marker present"
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

# Split them: paths either kernel package owns (and their pacman database
# entries) are the kernel swap, checked by pacman above; everything else must
# match root-changes.expected exactly.
old_package_db=${OLD_PACKAGE// /-}
new_package_db=${NEW_PACKAGE// /-}
{
  cat "$work/package-old.paths" "$work/package-new.paths"
  echo "var/lib/pacman/local/$old_package_db"
  echo "var/lib/pacman/local/$new_package_db"
} | sort -u > "$work/package.paths"
awk -v swap="$work/kernel-swap" -v rest="$work/profile-changes" \
    -v old_db="$old_package_db" -v new_db="$new_package_db" '
  NR == FNR { owned[$0] = 1; next }
  {
    p = $2
    if (p in owned ||
        index(p, "var/lib/pacman/local/" old_db "/") == 1 ||
        index(p, "var/lib/pacman/local/" new_db "/") == 1)
      print > swap
    else
      print > rest
  }' "$work/package.paths" "$work/root-changes"
touch "$work/kernel-swap" "$work/profile-changes"

# Files of the old package still on disk must be shared directories, owned by
# the new package too, or the Bluetooth helper put back above.
leftover=$(comm -23 <(sort -u "$work/package-old.paths") <(sort -u "$work/package-new.paths") |
  awk -F'\t' 'NR == FNR { keep[$1] = 1; next } $1 in keep && $2 != "d" { print $1 }' - "$work/root-after.tsv" |
  grep -vxF -e usr/local/sbin/ps5-bt-quiet -e etc/systemd/system/ps5-bt-quiet.service \
    -e etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service || true)
[[ -z $leftover ]] || die "files of $OLD_PACKAGE were left behind: ${leftover//$'\n'/ }"

sed -e '/^#/d' -e '/^$/d' \
  -e "s/@MLAN_SIZE@/$mlan_size/" -e "s/@MLAN_SHA256@/$mlan_sha/" \
  -e "s/@MOAL_SIZE@/$moal_size/" -e "s/@MOAL_SHA256@/$moal_sha/" \
  -e "s/@INITRD_SIZE@/$initrd_size/" -e "s/@INITRD_SHA256@/$initrd_sha/" \
  "$PROFILE/root-changes.expected" | sort -k2,2 > "$work/profile-changes.expected"
if ! diff -u "$work/profile-changes.expected" "$work/profile-changes"; then
  die "root changes differ from distros/cachyos1160-k73/root-changes.expected"
fi
swap_counts=$(awk '{ n[$1]++ } END { printf "%d added, %d modified, %d removed", n["A"], n["M"], n["R"] }' \
  "$work/kernel-swap")
echo "ok  $(wc -l < "$work/profile-changes") profile changes, all expected"
echo "ok  kernel swap: $swap_counts"

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
  echo "# The kernel swap from $OLD_PACKAGE to $NEW_PACKAGE ($swap_counts paths,"
  echo "# all owned by one of the two packages) is listed separately in"
  echo "# $(basename -- "$swap_out")."
  cat "$work/profile-changes"
  echo "# Old values of modified paths:"
  awk '$1 == "M" { print $2 }' "$work/profile-changes" | while read -r path; do
    awk -F'\t' -v p="$path" '$1 == p { $1 = $1; print "# was " $0 }' "$work/root-before.tsv"
  done
} > "$changes_out.new"
{
  echo "# Kernel package swap in $(basename -- "$output"): $OLD_PACKAGE -> $NEW_PACKAGE"
  echo "# $swap_counts. Columns as in $(basename -- "$changes_out")."
  cat "$work/kernel-swap"
} > "$swap_out.new"
{
  echo "# FAT boot partition (p2, LABEL=boot) of $(basename -- "$output")"
  echo "# sha256  size  name"
  cat "$work/boot-files"
  echo
  cat "$work/boot-check.txt"
} > "$boot_out.new"
mv -f -- "$changes_out.new" "$changes_out"
mv -f -- "$swap_out.new" "$swap_out"
mv -f -- "$boot_out.new" "$boot_out"
mv -- "$PARTIAL" "$output"

log "Done"
cat "$changes_out"
echo
cat "$boot_out"
echo
echo "Image:        $output ($BASE_SIZE bytes)"
echo "Root changes: $changes_out"
echo "Kernel swap:  $swap_out"
echo "Boot files:   $boot_out"
