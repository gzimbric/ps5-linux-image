#!/usr/bin/env bash
# Package the Linux 7.3.0 kernel bundle as the linux-ps5 .deb for the Ubuntu
# 24.04 7.3 image (distros/ubuntu2404-k73).
#
# The input is the bundle the CachyOS 7.3 workflow makes and caches
# (scripts/build-linux-ps5-k73.sh, then scripts/package-linux-ps5-k73.sh).
# The .deb is made from the files in its linux-ps5 pacman package, so both
# images carry the same kernel and modules, byte for byte:
#
#   /boot/vmlinuz-7.3.0, System.map-7.3.0, config-7.3.0
#   /usr/lib/modules/7.3.0, with the module build tree in build/
#   /usr/share/doc/linux-ps5/LICENSE.amdgpu, AMD's licence for the VCN
#   firmware built into the kernel
#
# It also carries the bundle's IW620 Wi-Fi modules (ps5-iw620/mlan.ko and
# moal.ko, built against the same kernel tree) in
# /usr/lib/modules/7.3.0/updates/ps5-iw620. Every build has the release
# string 7.3.0, so modules installed outside the package would stay behind
# when a newer kernel package replaces the kernel, and depmod would keep
# preferring them. The pacman package has no IW620 files.
#
# Left out: the UAPI headers in /usr/include (Ubuntu's linux-libc-dev stays
# in charge of those) and the module indexes, which the postinst writes with
# depmod. The maintainer scripts come from distros/ubuntu2404-k73/kernel.
# File owners and times are fixed, so the same bundle always gives the same
# .deb.
#
# Usage: scripts/package-linux-ps5-k73-deb.sh [--kernel-dir DIR] [--package FILE] [--out DIR]
#
# Needs Linux with GNU tar, zstd and dpkg-deb. Root is not needed.
set -euo pipefail
export LC_ALL=C
umask 022

KVER=7.3.0
PKGNAME=linux-ps5
# 7.3.0-4 was the CachyOS Image 4 kernel; -5 adds the MediaTek Bluetooth
# patches (KBUILD_BUILD_VERSION 5 in docker/kernel-builder/build-k73.sh).
DEB_VERSION=${KVER}-5
# Commit time of the pinned patch set (36f173f), as in the pacman package.
SOURCE_DATE_EPOCH=1792339253
export SOURCE_DATE_EPOCH

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPTS=$REPO/distros/ubuntu2404-k73/kernel

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
  echo "Usage: $0 [--kernel-dir DIR] [--package FILE] [--out DIR]"
}

kernel_dir=$REPO/linux-bin/cachyos1160-k73
package=
out=$REPO/linux-bin/ubuntu2404-k73
while (($#)); do
  case $1 in
    --kernel-dir) (($# >= 2)) || die "--kernel-dir needs a directory"; kernel_dir=$2; shift 2 ;;
    --package) (($# >= 2)) || die "--package needs a file"; package=$2; shift 2 ;;
    --out) (($# >= 2)) || die "--out needs a directory"; out=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for cmd in tar zstd dpkg-deb sha256sum md5sum find sort; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done
kernel_dir=$(cd -- "$kernel_dir" && pwd)
[[ -n $package ]] || package=$kernel_dir/$PKGNAME-$KVER-4-x86_64.pkg.tar.zst
[[ -f $package ]] || die "$package is missing; build the kernel bundle first"
[[ -f $kernel_dir/kernel/bzImage ]] || die "$kernel_dir/kernel/bzImage is missing"
for module in mlan moal; do
  [[ -f $kernel_dir/ps5-iw620/$module.ko ]] || die "$kernel_dir/ps5-iw620/$module.ko is missing"
done
(cd -- "$kernel_dir/ps5-iw620" && sha256sum -c --status SHA256SUMS) ||
  die "$kernel_dir/ps5-iw620 does not match its SHA256SUMS"
if [[ -f $package.sha256 ]]; then
  (cd -- "${package%/*}" && sha256sum -c --status -- "${package##*/}.sha256") ||
    die "$package does not match ${package##*/}.sha256"
fi
for script in preinst postinst prerm postrm; do
  [[ -f $SCRIPTS/$script ]] || die "$SCRIPTS/$script is missing"
done
mkdir -p -- "$out"
out=$(cd -- "$out" && pwd)

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
src=$work/pkg root=$work/root
mkdir -p -- "$src" "$root"
tar --zstd -xf "$package" -C "$src" --no-same-owner

# What the pacman package has to contain.
m=$src/usr/lib/modules/$KVER
for f in "boot/vmlinuz-$KVER" "boot/System.map-$KVER" "boot/config-$KVER" \
  "usr/lib/modules/$KVER/modules.order" "usr/lib/modules/$KVER/modules.builtin" \
  "usr/lib/modules/$KVER/modules.builtin.modinfo" \
  "usr/lib/modules/$KVER/build/Makefile" \
  "usr/lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko" \
  "usr/lib/modules/$KVER/kernel/drivers/bluetooth/btusb.ko" \
  "usr/share/licenses/$PKGNAME/LICENSE.amdgpu"; do
  [[ -f $src/$f ]] || die "$f is missing from ${package##*/}"
done
cmp -s -- "$src/boot/vmlinuz-$KVER" "$kernel_dir/kernel/bzImage" ||
  die "boot/vmlinuz-$KVER in ${package##*/} is not $kernel_dir/kernel/bzImage"
trees=$(cd -- "$src/usr/lib/modules" && find . -mindepth 1 -maxdepth 1 -printf '%P\n')
[[ $trees == "$KVER" ]] || die "expected only usr/lib/modules/$KVER, found: ${trees//$'\n'/ }"
if find "$src" \( -name mlan.ko -o -name moal.ko -o -name 'pcieuartiw620*' \) -print -quit | grep -q .; then
  die "${package##*/} has IW620 files; the .deb takes them from ps5-iw620/ in the bundle"
fi

# The .deb tree.
install -d -m 0755 "$root/boot" "$root/usr/lib/modules" "$root/usr/share/doc/$PKGNAME" "$root/DEBIAN"
for f in vmlinuz System.map config; do
  install -m 0644 "$src/boot/$f-$KVER" "$root/boot/$f-$KVER"
done
cp -a -- "$m" "$root/usr/lib/modules/"
[[ ! -e $root/usr/lib/modules/$KVER/updates ]] ||
  die "${package##*/} already has usr/lib/modules/$KVER/updates"
install -d -m 0755 "$root/usr/lib/modules/$KVER/updates/ps5-iw620"
install -m 0644 "$kernel_dir/ps5-iw620/mlan.ko" "$kernel_dir/ps5-iw620/moal.ko" \
  "$root/usr/lib/modules/$KVER/updates/ps5-iw620/"
# depmod output; the postinst writes these.
for index in modules.alias modules.alias.bin modules.builtin.alias.bin \
  modules.builtin.bin modules.dep modules.dep.bin modules.devname \
  modules.softdep modules.symbols modules.symbols.bin modules.weakdep; do
  rm -f -- "$root/usr/lib/modules/$KVER/$index"
done
install -m 0644 "$src/usr/share/licenses/$PKGNAME/LICENSE.amdgpu" \
  "$root/usr/share/doc/$PKGNAME/LICENSE.amdgpu"
cat > "$root/usr/share/doc/$PKGNAME/copyright" <<'EOF'
linux-ps5: Linux 7.3.0 for the PS5, built by gzimbric/ps5-linux-image.

The kernel and its modules are licensed under the GNU General Public License
version 2 (/usr/share/common-licenses/GPL-2). The sources are Linux v7.3
(git.kernel.org, commit c03c1a14507dfaf8b856c2608f9ac216021fc222) with
rmuxnet/ps5-linux-patches-1 at 36f173f39e5e76c00c4e366a7b909f33bc665ad5 and
the patches in distros/cachyos1160-k73/kernel of
https://github.com/gzimbric/ps5-linux-image.

The IW620 Wi-Fi modules in updates/ps5-iw620 (GPL-2) are built from
nxp-imx/mwifiex a5fe4e194bf99315e349d81d77d6dfacec70757a with patches from
ps5-linux/ps5-linux-mwifiex 4bce848dd098bf74fbafd0078463da3d9f0d7f80 and
distros/cachyos1160-k73/kernel/ps5-iw620-kernel73-compat.patch.

bzImage includes AMD's ps5_vcn.bin firmware; its licence is LICENSE.amdgpu
in this directory.
EOF
chmod 0644 "$root/usr/share/doc/$PKGNAME/copyright"

for script in preinst postinst prerm postrm; do
  sed "s/__KVER__/$KVER/g" "$SCRIPTS/$script" > "$root/DEBIAN/$script"
  ! grep -q __KVER__ "$root/DEBIAN/$script" || die "$script still has a placeholder"
  chmod 0755 "$root/DEBIAN/$script"
done

# No group or other write bits (the kernel tree's own modes come from git
# archive, which leaves files group-writable), fixed times.
chmod -R u+rwX,go+rX,go-w "$root"
(cd -- "$root" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z |
  xargs -0 md5sum) > "$root/DEBIAN/md5sums"
chmod 0644 "$root/DEBIAN/md5sums"
installed_size=$(du -sk --exclude=DEBIAN "$root" | awk '{print $1}')
cat > "$root/DEBIAN/control" <<EOF
Package: $PKGNAME
Version: $DEB_VERSION
Architecture: amd64
Maintainer: ps5-linux-image <https://github.com/gzimbric/ps5-linux-image/issues>
Installed-Size: $installed_size
Depends: kmod, initramfs-tools
Provides: linux-image-$KVER, linux-modules-$KVER, linux-headers-$KVER
Section: kernel
Priority: optional
Homepage: https://github.com/gzimbric/ps5-linux-image
Description: Linux $KVER for the PS5 (kernel, modules and module build tree)
 Linux v7.3 with rmux's PS5 patch set (rmuxnet/ps5-linux-patches-1) and the
 PS5 Bluetooth patches from VivaLaVent's ps5-bazzite-deck, made from the
 same kernel build as the CachyOS 7.3 image, plus the IW620 Wi-Fi modules
 (mlan, moal) built against it. On the PS5 Ubuntu image, installing it
 updates bzImage and initrd.img on the boot partition through the image's
 initramfs-tools hook.
EOF
chmod 0644 "$root/DEBIAN/control"
find "$root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

deb=$out/${PKGNAME}_${DEB_VERSION}_amd64.deb
dpkg-deb --root-owner-group -Zxz --build "$root" "$deb.new" >/dev/null
mv -f -- "$deb.new" "$deb"

# Check what went in.
[[ $(dpkg-deb -f "$deb" Package) == "$PKGNAME" ]] || die "wrong Package field"
[[ $(dpkg-deb -f "$deb" Version) == "$DEB_VERSION" ]] || die "wrong Version field"
listing=$(dpkg-deb --fsys-tarfile "$deb" | tar -t)
for f in "./boot/vmlinuz-$KVER" "./usr/lib/modules/$KVER/modules.order" \
  "./usr/lib/modules/$KVER/build/Makefile" \
  "./usr/lib/modules/$KVER/kernel/drivers/bluetooth/btusb.ko" \
  "./usr/lib/modules/$KVER/updates/ps5-iw620/mlan.ko" \
  "./usr/lib/modules/$KVER/updates/ps5-iw620/moal.ko" \
  "./usr/share/doc/$PKGNAME/LICENSE.amdgpu"; do
  grep -qxF -- "$f" <<<"$listing" || die "$f is missing from the .deb"
done
if grep -E '^\./(usr/include|etc)/|pcieuartiw620|/modules\.dep$' <<<"$listing"; then
  die "the .deb has files it should not have"
fi
iw620=$(grep -E '(^|/)(mlan|moal)\.ko$' <<<"$listing" | sort | tr '\n' ' ')
[[ $iw620 == "./usr/lib/modules/$KVER/updates/ps5-iw620/mlan.ko ./usr/lib/modules/$KVER/updates/ps5-iw620/moal.ko " ]] ||
  die "unexpected IW620 modules in the .deb: $iw620"
for module in mlan moal; do
  cmp -s <(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "./usr/lib/modules/$KVER/updates/ps5-iw620/$module.ko") \
    "$kernel_dir/ps5-iw620/$module.ko" || die "$module.ko in the .deb is not the built module"
done
cmp -s <(dpkg-deb --fsys-tarfile "$deb" | tar -xOf - "./boot/vmlinuz-$KVER") "$kernel_dir/kernel/bzImage" ||
  die "boot/vmlinuz-$KVER in the .deb is not the built bzImage"
owners=$(dpkg-deb --fsys-tarfile "$deb" | tar -tv | awk '{print $2}' | sort -u)
[[ $owners == root/root ]] || die "the .deb has files not owned by root: ${owners//$'\n'/ }"

deb_sha=$(sha256sum "$deb" | awk '{print $1}')
printf '%s  %s\n' "$deb_sha" "${deb##*/}" > "$deb.sha256"
echo "$PKGNAME $DEB_VERSION: $(stat -c %s "$deb") bytes, $(grep -c . <<<"$listing") entries"
cat "$deb.sha256"
