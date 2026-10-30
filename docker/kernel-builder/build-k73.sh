#!/bin/bash
# Builds Linux 7.3.0 for the CachyOS 7.3 image for PS5 firmware 11.60.
#
# Runs in the ps5-kernel-builder image (Debian gcc 14.2), started by
# scripts/build-linux-ps5-k73.sh with:
#   /in/linux.git        bare repository holding the pinned v7.3 commit (ro)
#   /ps5-linux-patches   the PS5 patch set at its pinned commit (ro). The
#                        kernel config builds firmware/amdgpu/ps5_vcn.bin into
#                        the kernel from ../ps5-linux-patches/firmware, which
#                        is this directory as seen from /src.
#   /repo                this repository (ro)
#   /src                 an empty Docker volume for the kernel tree
#   /out                 output directory
#
# The base patch set is rmux's 7.3 port. On top of it, the builder applies the
# exact hash-checked ps5-bazzite-deck v1.8.5 patch order: HDMI 2.1 FRL 4K120,
# the EDID/link guard and automatic fallback, VRR/display prerequisites, and
# PS5 Pro GPU/Bluetooth support. A small local follow-up recognizes rmux's
# second published Viola PCI ID as a Pro too. The two PS5 frequency drivers
# remain modules, but the Pro guard leaves its clocks to firmware.
set -euo pipefail

LINUX_COMMIT=c03c1a14507dfaf8b856c2608f9ac216021fc222   # tag v7.3
PATCHES_COMMIT=baee34dbbf9f6b33aca332e9487c5984e345f526
BAZZITE_COMMIT=96d0c342017968ee2bfc3f56730c9808f2b98342
KVER=7.3.0
PATCH_SHA256=fa7b9b6d204a1d16318fa293e0e7e8944d85a435a377d8c0836261c63ad353cf
BAZZITE_MANIFEST=/repo/distros/cachyos1160-k73/kernel/v1.8.5-patches.sha256
PRO_13DC_PATCH=/repo/distros/cachyos1160-k73/kernel/ps5-pro-13dc.patch
CONFIG_SHA256=2294e750518bbfedf9741f5638d81f6308a2fa3839b2e005f5e071224622533d
VCN_SHA256=bbd15ab65e76178c2918e8224b6ab4ab1711f1b59d935ee131ab188a9712e596
VCN_SIZE=404544
VCN_LICENSE_SHA256=572872598565dc3513470de971a32bf9db301f47afeef3636345eadae33b2eee
CHECK=/repo/distros/cachyos1160-k73/files/ps5-1160-check-boot-files

# Fixed build identity, so two builds from the same pins match.
export KBUILD_BUILD_USER=ps5
export KBUILD_BUILD_HOST=ps5-linux-image
export KBUILD_BUILD_TIMESTAMP='Sat Oct 24 14:21:36 UTC 2026'
export KBUILD_BUILD_VERSION=4
export TZ=UTC
export LC_ALL=C
export CCACHE_DISABLE=1
unset MAKEFLAGS CONFIG_OBJTOOL
JOBS=${JOBS:-$(nproc)}

step() { printf '\n=== %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
expect_sha256() { # file sha256
  local actual
  actual=$(sha256sum "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || die "$1: sha256 $actual, expected $2"
  echo "ok  $2  $1"
}
config_is() { # option value
  grep -qx "$1=$2" .config || die ".config: expected $1=$2, found: $(grep -E "^(# )?$1[= ]" .config || echo nothing)"
}

step "Toolchain"
test "$(x86_64-linux-gnu-gcc --version | head -1)" = \
  'x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0'
test "$(x86_64-linux-gnu-ld --version | head -1)" = \
  'GNU ld (GNU Binutils for Debian) 2.44'
test "$(pahole --version)" = v1.30
echo "$(uname -m) host, $(x86_64-linux-gnu-gcc --version | head -1), $JOBS jobs"

step "Sources"
expect_sha256 /ps5-linux-patches/linux.patch "$PATCH_SHA256"
expect_sha256 /ps5-linux-patches/.config "$CONFIG_SHA256"
expect_sha256 /ps5-linux-patches/firmware/amdgpu/ps5_vcn.bin "$VCN_SHA256"
test "$(stat -c %s /ps5-linux-patches/firmware/amdgpu/ps5_vcn.bin)" = "$VCN_SIZE"
expect_sha256 /ps5-linux-patches/firmware/LICENSE.amdgpu "$VCN_LICENSE_SHA256"
test "$(git --git-dir=/in/linux.git rev-parse "$LINUX_COMMIT^{commit}")" = "$LINUX_COMMIT"
(cd /bazzite-patches && sha256sum -c "$BAZZITE_MANIFEST")

# v1.8.5 was made on rmux's baee34d plus the suspend-to-idle patch. Apply
# that patch to a writable copy of linux.patch/.config before patching Linux.
rm -rf /tmp/ps5-linux-patches
cp -a /ps5-linux-patches /tmp/ps5-linux-patches
git -C /tmp/ps5-linux-patches apply --check \
  /bazzite-patches/ps5-linux-patches-pr4-s2idle.patch
git -C /tmp/ps5-linux-patches apply \
  /bazzite-patches/ps5-linux-patches-pr4-s2idle.patch
PS5_PATCHSET=/tmp/ps5-linux-patches

cd /src
[ -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)" ] || die "/src is not empty"
git --git-dir=/in/linux.git archive "$LINUX_COMMIT" | tar -xf - -C /src
git apply --check "$PS5_PATCHSET/linux.patch"
git apply "$PS5_PATCHSET/linux.patch"
echo "applied linux.patch ($(grep -c '^diff --git' "$PS5_PATCHSET/linux.patch") files)"

BAZZITE_PATCHES=(
  ps5-bluetooth.patch
  ps5-hdmi-upstream.patch
  ps5-hdmi-rearm-pr46.patch
  ps5-hdmi-output-fixes.patch
  ps5-hdmi-modes.patch
  ps5-hdmi-debug-log.patch
  ps5-hdmi-link-lock.patch
  ps5-gpu-overlay.patch
  ps5-hdmi-cec-upstream53.patch
  ps5-hdmi-sleep-mute.patch
  ps5-hdmi-scdc-source-version.patch
  ps5-usbc-dp-pr57.patch
  ps5-hdmi-rgb-full-range.patch
  ps5-hdmi-edid-fallback.patch
  ps5-hdmi-edid-keep.patch
  ps5-hdmi-verde-game-content.patch
  ps5-hdmi-session-switch.patch
  ps5-hdmi-rgb-range-encoding.patch
  ps5-usbc-dp-optin.patch
  ps5-vrr.patch
  ps5-vrr-stock-setup.patch
  ps5-hdmi-frl-4k120.patch
  ps5-vrr-follow-guard.patch
  ps5-vrr-min-48.patch
  ps5-pro-gpu.patch
  ps5-pro-bluetooth.patch
  ps5-pro-no-freqdrivers.patch
  ps5-hdmi-4k120-guard.patch
)
for name in "${BAZZITE_PATCHES[@]}"; do
  patch=/bazzite-patches/$name
  git apply --check "$patch"
  git apply "$patch"
  echo "applied $name ($(grep -c '^--- a/' "$patch") files)"
done
git apply --check "$PRO_13DC_PATCH"
git apply "$PRO_13DC_PATCH"
echo "applied ${PRO_13DC_PATCH##*/}"
btusb=drivers/bluetooth/btusb.c
btusb_table_iw620=$(awk '
  /static const struct usb_device_id btusb_table\[\] = \{/ { in_table = 1 }
  in_table && /USB_DEVICE\(0x1286, 0x2059\)/ { count++ }
  in_table && /^};$/ { print count + 0; exit }
' "$btusb")
quirks_table_iw620=$(awk '
  /static const struct usb_device_id quirks_table\[\] = \{/ { in_table = 1 }
  in_table && /USB_DEVICE\(0x1286, 0x2059\)/ { count++ }
  in_table && /^};$/ { print count + 0; exit }
' "$btusb")
test "$btusb_table_iw620" = 0 ||
  die "$btusb still has the IW620 in btusb_table"
test "$quirks_table_iw620" = 1 ||
  die "$btusb does not have exactly one IW620 entry in quirks_table"
test "$(grep -c 'match = usb_match_id(intf, quirks_table);' "$btusb")" = 1 ||
  die "$btusb does not have exactly one quirks-table lookup"
test "$(grep -c 'if ((id->driver_info & BTUSB_IFNUM_0)' "$btusb")" = 1 ||
  die "$btusb does not have exactly one BTUSB_IFNUM_0 check"
quirks_lookup_line=$(grep -n 'match = usb_match_id(intf, quirks_table);' "$btusb" | cut -d: -f1)
ifnum0_line=$(grep -n 'if ((id->driver_info & BTUSB_IFNUM_0)' "$btusb" | cut -d: -f1)
test "$ifnum0_line" -gt "$quirks_lookup_line" ||
  die "btusb BTUSB_IFNUM_0 check still runs before the quirks lookup"

step "Config"
cp "$PS5_PATCHSET/.config" .config
# Build the CPU and GPU frequency drivers as modules. Neither has a module
# alias, so only the image's guarded startup service can load them explicitly.
scripts/config --file .config --module X86_PS5_CPUFREQ --module PS5_GPUFREQ
make -s olddefconfig
config_is CONFIG_X86_PS5_CPUFREQ m
config_is CONFIG_PS5_GPUFREQ m
config_is CONFIG_X86_PS5 y
config_is CONFIG_RANDOMIZE_BASE y
config_is CONFIG_RELOCATABLE y
config_is CONFIG_OBJTOOL y
config_is CONFIG_MODVERSIONS y
config_is CONFIG_CFG80211 m
config_is CONFIG_SENSORS_K10TEMP m
config_is CONFIG_PM_DEVFREQ y
config_is CONFIG_DRM_AMDGPU m
config_is CONFIG_EXTRA_FIRMWARE '"amdgpu/ps5_vcn.bin"'
config_is CONFIG_EXTRA_FIRMWARE_DIR '"../ps5-linux-patches/firmware"'
config_is CONFIG_LOCALVERSION '""'
grep -qx '# CONFIG_LOCALVERSION_AUTO is not set' .config
grep -qx '# CONFIG_MODULE_SIG is not set' .config
test "$(make -s kernelrelease)" = "$KVER"
# Everything else should be the published config; show what olddefconfig and
# the two module switches changed.
diff "$PS5_PATCHSET/.config" .config > /tmp/config.diff || true
cat /tmp/config.diff
sha256sum .config

step "Build"
make -j"$JOBS" bzImage modules
test "$(make -s kernelrelease)" = "$KVER"
test -f drivers/base/firmware_loader/builtin/amdgpu/ps5_vcn.bin.gen.o ||
  die "ps5_vcn.bin was not built into the kernel"
for module in drivers/cpufreq/ps5-cpufreq.ko drivers/devfreq/ps5-gpufreq.ko; do
  test -f "$module" || die "$module was not built"
  [ -z "$(modinfo -F alias "$module")" ] || die "$module has a module alias"
done
ls -l arch/x86/boot/bzImage
sha256sum arch/x86/boot/bzImage

step "Loader limits"
"$CHECK" arch/x86/boot/bzImage

step "Staging"
rm -rf /out/staging /out/kernel
mkdir -p /out/staging/boot /out/kernel
cp arch/x86/boot/bzImage /out/staging/boot/bzImage
cp System.map .config Module.symvers /out/staging/
make -s modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1
rm -f "/out/staging/lib/modules/$KVER/build" "/out/staging/lib/modules/$KVER/source"

# Kernel headers, for building out-of-tree modules on the console. The same
# steps as docker/kernel-builder/build.sh. The build tree is put together on
# the container's own filesystem first: GNU tar extracts symlinks that point
# upwards through a mode 000 placeholder, which a shared host folder (Docker
# Desktop, colima) may not let it replace.
make -s headers_install INSTALL_HDR_PATH=/out/staging/headers/usr
export srctree=/src SRCARCH=x86
rm -rf /tmp/extmod-build
CC="${CROSS_COMPILE}gcc" HOSTCC=gcc MAKE=make \
  /src/scripts/package/install-extmod-build /tmp/extmod-build
mkdir -p "/out/staging/headers/lib/modules/$KVER"
cp -a /tmp/extmod-build "/out/staging/headers/lib/modules/$KVER/build"

# Modules are installed uncompressed: the config enables zstd module support
# but not MODULE_COMPRESS_ALL, as in the 7.1.7 package.
modules=/out/staging/lib/modules/$KVER
for module in kernel/drivers/cpufreq/ps5-cpufreq.ko \
  kernel/drivers/devfreq/ps5-gpufreq.ko \
  kernel/drivers/hwmon/k10temp.ko \
  kernel/drivers/gpu/drm/amd/amdgpu/amdgpu.ko \
  kernel/net/wireless/cfg80211.ko; do
  test -f "$modules/$module" || die "$module is missing from the staged modules"
done
module_count=$(find "$modules" -name '*.ko*' | wc -l)

cp arch/x86/boot/bzImage /out/kernel/bzImage
cp .config /out/kernel/config
cp /tmp/config.diff /out/kernel/config-changes.diff
# AMD's licence for ps5_vcn.bin, which is now part of bzImage. The package
# installs it under /usr/share/licenses/linux-ps5.
cp "$PS5_PATCHSET/firmware/LICENSE.amdgpu" /out/kernel/LICENSE.amdgpu
cp System.map Module.symvers /out/kernel/
{
  echo "Linux $KVER for the CachyOS 7.3 image, PS5 firmware 11.60"
  echo "Kernel:       v7.3, commit $LINUX_COMMIT"
  echo "Patch set:    rmuxnet/ps5-linux-patches-1, commit $PATCHES_COMMIT"
  echo "              linux.patch sha256 $PATCH_SHA256"
  echo "              .config sha256 $CONFIG_SHA256"
  echo "Display/Pro:  ps5-bazzite-deck v1.8.5, commit $BAZZITE_COMMIT"
  echo "              ${#BAZZITE_PATCHES[@]} kernel patches + local PS5 Pro 13dc follow-up"
  echo "              firmware/amdgpu/ps5_vcn.bin $VCN_SIZE bytes, sha256 $VCN_SHA256 (built in)"
  echo "HDMI:         4K120 FRL with EDID/chip-rate gate, link check and automatic fallback"
  echo "Config:       X86_PS5_CPUFREQ=m PS5_GPUFREQ=m, then olddefconfig; sha256 $(sha256sum .config | awk '{print $1}')"
  echo "Compiler:     $(x86_64-linux-gnu-gcc --version | head -1), $(uname -m) build host"
  echo "Version:      $(strings arch/x86/boot/bzImage | awk -v k="$KVER (" 'index($0, k) == 1 && !n { print; n = 1 }')"
  echo "bzImage:      $(stat -c %s arch/x86/boot/bzImage) bytes, sha256 $(sha256sum arch/x86/boot/bzImage | awk '{print $1}')"
  echo "Modules:      $module_count"
  echo
  "$CHECK" arch/x86/boot/bzImage
} > /out/kernel/kernel-build-info.txt
cat /out/kernel/kernel-build-info.txt
echo "=== Linux $KVER staged in /out/staging"
