#!/usr/bin/env bash
# Package the Linux 7.3.0 build from scripts/build-linux-ps5-k73.sh as the
# linux-ps5 pacman package for the CachyOS 7.3 image.
#
# The package has the same layout as docker/kernel-builder-arch/build.sh
# makes (kernel, System.map and config in /boot, modules and build headers
# in /usr/lib/modules/7.3.0, UAPI headers in /usr/include), plus AMD's
# licence for the VCN firmware built into the kernel. Its install script
# leaves /boot/efi to the image's pacman hook. File times and owners are
# fixed, so the same kernel build always gives the same package.
#
# Run as root on Linux with bsdtar (libarchive-tools), gzip and zstd. The IW620
# Wi-Fi modules are not part of the package; the image installs them.
set -euo pipefail
export LC_ALL=C
umask 022

KVER=7.3.0
PKGNAME=linux-ps5
# -4 is CachyOS Image 4's kernel. docker/kernel-builder/build-k73.sh now makes
# kernel #5 (Image 4 plus the MediaTek Bluetooth patches), which the Ubuntu
# image packages as 7.3.0-5. Bump this, the CachyOS workflow's PACKAGE and the
# CachyOS image scripts together before the next CachyOS image is built.
PKGVER=${KVER}-4
# Commit time of the pinned patch set (36f173f).
SOURCE_DATE_EPOCH=1792339253

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALL_TEMPLATE=$REPO/distros/cachyos1160-k73/kernel/linux-ps5.install

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

kernel_dir=$REPO/linux-bin/cachyos1160-k73
while (($#)); do
  case $1 in
    --kernel-dir) (($# >= 2)) || die "--kernel-dir needs a directory"; kernel_dir=$2; shift 2 ;;
    -h|--help) echo "Usage: sudo $0 [--kernel-dir DIR]"; exit 0 ;;
    *) echo "Usage: sudo $0 [--kernel-dir DIR]" >&2; exit 2 ;;
  esac
done

((EUID == 0)) || die "run as root, so the package files are owned by root"
for cmd in bsdtar gzip zstd find sort du sha256sum; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
kernel_dir=$(cd -- "$kernel_dir" && pwd)
staging=$kernel_dir/staging
for f in boot/bzImage System.map .config "lib/modules/$KVER/modules.order" \
  "headers/usr/include/linux/version.h" "headers/lib/modules/$KVER/build/Makefile"; do
  [[ -e $staging/$f ]] || die "$staging/$f is missing; run scripts/build-linux-ps5-k73.sh first"
done
[[ -f $kernel_dir/kernel/LICENSE.amdgpu ]] || die "$kernel_dir/kernel/LICENSE.amdgpu is missing"
modules=("$staging"/lib/modules/*)
((${#modules[@]} == 1)) && [[ ${modules[0]##*/} == "$KVER" ]] ||
  die "expected only lib/modules/$KVER in $staging"

pkg=$kernel_dir/$PKGNAME-$PKGVER-x86_64.pkg.tar.zst
# Put the package tree together on local disk, so the file modes are the
# ones Linux gives them even when the kernel directory is a shared folder.
root=$(mktemp -d)
trap 'rm -rf -- "$root"' EXIT

install -d -m 0755 "$root/boot" "$root/usr/lib/modules" "$root/usr/share/licenses/$PKGNAME"
install -m 0644 "$staging/boot/bzImage" "$root/boot/vmlinuz-$KVER"
install -m 0644 "$staging/System.map" "$root/boot/System.map-$KVER"
install -m 0644 "$staging/.config" "$root/boot/config-$KVER"
cp -a "$staging/lib/modules/$KVER" "$root/usr/lib/modules/"
cp -a "$staging/headers/usr/." "$root/usr/"
cp -a "$staging/headers/lib/modules/$KVER/build" "$root/usr/lib/modules/$KVER/build"
install -m 0644 "$kernel_dir/kernel/LICENSE.amdgpu" \
  "$root/usr/share/licenses/$PKGNAME/LICENSE.amdgpu"
sed "s/__KVER__/$KVER/g" "$INSTALL_TEMPLATE" > "$root/.INSTALL"
! grep -q __KVER__ "$root/.INSTALL" || die ".INSTALL still has a placeholder"

size=$(du -sb --exclude=.INSTALL "$root" | awk '{print $1}')
cat > "$root/.PKGINFO" <<EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = $PKGVER
pkgdesc = PS5 Linux kernel $KVER (image + modules + headers)
url = https://github.com/gzimbric/ps5-linux-image
builddate = $SOURCE_DATE_EPOCH
packager = ps5-linux-image
size = $size
arch = x86_64
license = GPL-2.0-only
provides = linux=$KVER
provides = linux-headers=$KVER
provides = linux-api-headers=$KVER
conflict = linux
conflict = linux-headers
conflict = linux-api-headers
conflict = linux-custom
replaces = linux
replaces = linux-headers
replaces = linux-api-headers
replaces = linux-custom
EOF

# Owned by root, no group or other write bits (the kernel tree's own modes
# come from git archive, which leaves files group-writable).
chown -R -h 0:0 "$root"
chmod -R u+rwX,go+rX,go-w "$root"
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

list_files() {
  (cd -- "$root" && find . -mindepth 1 ! -name .MTREE -printf '%P\0' | sort -z)
}
cd -- "$root"
list_files | bsdtar --no-acls --no-xattrs --no-fflags -cnf - --format=mtree \
  --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
  --null --files-from - | gzip -c -f -n > .MTREE
touch -d "@$SOURCE_DATE_EPOCH" .MTREE
{ printf '.MTREE\0'; list_files; } |
  bsdtar --no-acls --no-xattrs --no-fflags -cnf - --null --files-from - |
  zstd -q -c -T0 > "$pkg.new"
cd - >/dev/null
mv -f -- "$pkg.new" "$pkg"

# Check what went in.
listing=$(bsdtar -tf "$pkg")
for f in .PKGINFO .INSTALL .MTREE "boot/vmlinuz-$KVER" \
  "usr/lib/modules/$KVER/kernel/drivers/cpufreq/ps5-cpufreq.ko" \
  "usr/lib/modules/$KVER/kernel/drivers/devfreq/ps5-gpufreq.ko" \
  "usr/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko" \
  "usr/lib/modules/$KVER/build/Makefile" \
  "usr/share/licenses/$PKGNAME/LICENSE.amdgpu"; do
  grep -qxF -- "$f" <<<"$listing" || die "$f is missing from the package"
done
if grep -E '(^|/)(mlan|moal)\.ko|pcieuartiw620|^etc/' <<<"$listing"; then
  die "the package has IW620 files or /etc files; the image installs those"
fi
cmp -s <(bsdtar -xOf "$pkg" "boot/vmlinuz-$KVER") "$staging/boot/bzImage" ||
  die "boot/vmlinuz-$KVER in the package is not the built bzImage"

pkg_sha=$(sha256sum "$pkg" | awk '{print $1}')
printf '%s  %s\n' "$pkg_sha" "${pkg##*/}" > "$pkg.sha256"
echo "$PKGNAME $PKGVER: $(stat -c %s "$pkg") bytes, $(grep -c . <<<"$listing") entries"
cat "$pkg.sha256"
