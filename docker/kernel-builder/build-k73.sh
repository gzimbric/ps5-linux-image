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
# The patch set is the 7.3 port by rmux (Armandas Kvietkus) in
# rmuxnet/ps5-linux-patches-1. A byte-for-byte, hash-pinned follow-up from the
# ps5-bazzite-deck v1.0.3 release makes the IW620 Bluetooth quirks in that port
# take effect. The config changes made here build the two PS5 frequency
# drivers and Linux 7.3's in-tree MT7921 PCI Wi-Fi driver as modules.
set -euo pipefail

LINUX_COMMIT=c03c1a14507dfaf8b856c2608f9ac216021fc222   # tag v7.3
PATCHES_COMMIT=36f173f39e5e76c00c4e366a7b909f33bc665ad5
KVER=7.3.0
PATCH_SHA256=b8a238b9973febbcf851053d99195bd7320bb0827c8ee5e4c54eba6b6f7cde3f
BTUSB_PATCH=/repo/distros/cachyos1160-k73/kernel/ps5-btusb-iw620-quirks.patch
BTUSB_PATCH_SHA256=c01bdcc134f25a86825f2824d12a82da02db18e7b1940db722223b0c4611eed8
CONFIG_SHA256=2294e750518bbfedf9741f5638d81f6308a2fa3839b2e005f5e071224622533d
VCN_SHA256=bbd15ab65e76178c2918e8224b6ab4ab1711f1b59d935ee131ab188a9712e596
VCN_SIZE=404544
VCN_LICENSE_SHA256=572872598565dc3513470de971a32bf9db301f47afeef3636345eadae33b2eee
CHECK=/repo/distros/cachyos1160-k73/files/ps5-1160-check-boot-files

# Fixed build identity, so two builds from the same pins match.
export KBUILD_BUILD_USER=ps5
export KBUILD_BUILD_HOST=ps5-linux-image
export KBUILD_BUILD_TIMESTAMP='Sun Oct 18 16:00:53 UTC 2026'
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
expect_sha256 "$BTUSB_PATCH" "$BTUSB_PATCH_SHA256"
expect_sha256 /ps5-linux-patches/.config "$CONFIG_SHA256"
expect_sha256 /ps5-linux-patches/firmware/amdgpu/ps5_vcn.bin "$VCN_SHA256"
test "$(stat -c %s /ps5-linux-patches/firmware/amdgpu/ps5_vcn.bin)" = "$VCN_SIZE"
expect_sha256 /ps5-linux-patches/firmware/LICENSE.amdgpu "$VCN_LICENSE_SHA256"
test "$(git --git-dir=/in/linux.git rev-parse "$LINUX_COMMIT^{commit}")" = "$LINUX_COMMIT"

cd /src
[ -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)" ] || die "/src is not empty"
git --git-dir=/in/linux.git archive "$LINUX_COMMIT" | tar -xf - -C /src
git apply --check /ps5-linux-patches/linux.patch
git apply /ps5-linux-patches/linux.patch
echo "applied linux.patch ($(grep -c '^diff --git' /ps5-linux-patches/linux.patch) files)"
git apply --check "$BTUSB_PATCH"
git apply "$BTUSB_PATCH"
echo "applied ${BTUSB_PATCH##*/} ($(grep -c '^diff --git' "$BTUSB_PATCH") files)"
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
cp /ps5-linux-patches/.config .config
# Build the CPU and GPU frequency drivers as modules. Neither has a module
# alias, so only the image's guarded startup service can load them explicitly.
# MT7921E stays on the normal PCI modalias path and is never force-loaded.
scripts/config --file .config --module X86_PS5_CPUFREQ --module PS5_GPUFREQ \
  --module MT7921E
make -s olddefconfig
config_is CONFIG_X86_PS5_CPUFREQ m
config_is CONFIG_PS5_GPUFREQ m
config_is CONFIG_MT76_CORE m
config_is CONFIG_MT76_CONNAC_LIB m
config_is CONFIG_MT792x_LIB m
config_is CONFIG_MT7921_COMMON m
config_is CONFIG_MT7921E m
config_is CONFIG_X86_PS5 y
config_is CONFIG_RANDOMIZE_BASE y
config_is CONFIG_RELOCATABLE y
config_is CONFIG_OBJTOOL y
config_is CONFIG_MODVERSIONS y
config_is CONFIG_CFG80211 m
config_is CONFIG_FW_LOADER_COMPRESS y
config_is CONFIG_FW_LOADER_COMPRESS_ZSTD y
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
# the three module switches changed.
diff /ps5-linux-patches/.config .config > /tmp/config.diff || true
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
mt7921e=drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko
test -f "$mt7921e" || die "$mt7921e was not built"
mt_vermagic=$(modinfo -F vermagic "$mt7921e")
test "$mt_vermagic" = "$(modinfo -F vermagic net/wireless/cfg80211.ko)" ||
  die "mt7921e vermagic does not match cfg80211"
case "$mt_vermagic" in
  "$KVER "*) ;;
  *) die "mt7921e vermagic is not for $KVER: $mt_vermagic" ;;
esac
mt_deps=$(modinfo -F depends "$mt7921e" | tr ',' '\n' | sort | tr '\n' ' ')
test "$mt_deps" = 'mt76 mt76-connac-lib mt7921-common mt792x-lib ' ||
  die "unexpected mt7921e dependencies: $mt_deps"
mt_aliases=(
  'pci:v000014C3d00007961sv*sd*bc*sc*i*'
  'pci:v000014C3d00007922sv*sd*bc*sc*i*'
  'pci:v00000B48d00007922sv*sd*bc*sc*i*'
  'pci:v000014C3d00000608sv*sd*bc*sc*i*'
  'pci:v000014C3d00000616sv*sd*bc*sc*i*'
  'pci:v000014C3d00007920sv*sd*bc*sc*i*'
  'pci:v000014C3d00007902sv*sd*bc*sc*i*'
)
actual=$(modinfo -F alias "$mt7921e" | sort)
expected=$(printf '%s\n' "${mt_aliases[@]}" | sort)
test "$actual" = "$expected" || die "unexpected mt7921e PCI aliases"
modinfo -F parm "$mt7921e" | grep -qxF 'disable_aspm:disable PCI ASPM support' ||
  die "mt7921e does not expose the expected disable_aspm parameter"
mt_firmware=(
  mediatek/WIFI_MT7902_patch_mcu_1_1_hdr.bin
  mediatek/WIFI_RAM_CODE_MT7902_1.bin
  mediatek/WIFI_MT7922_patch_mcu_1_1_hdr.bin
  mediatek/WIFI_RAM_CODE_MT7922_1.bin
  mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin
  mediatek/WIFI_RAM_CODE_MT7961_1.bin
  mediatek/WIFI_MT7961_patch_mcu_1a_2_hdr.bin
  mediatek/WIFI_RAM_CODE_MT7961_1a.bin
)
actual=$(modinfo -F firmware "$mt7921e" | sort)
expected=$(printf '%s\n' "${mt_firmware[@]}" | sort)
test "$actual" = "$expected" || die "unexpected mt7921e firmware declarations"
echo "ok  mt7921e: Linux 7.3 module, dependencies, 7 PCI aliases, disable_aspm and 8 firmware names"
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
  kernel/drivers/net/wireless/mediatek/mt76/mt76.ko \
  kernel/drivers/net/wireless/mediatek/mt76/mt76-connac-lib.ko \
  kernel/drivers/net/wireless/mediatek/mt76/mt792x-lib.ko \
  kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921-common.ko \
  kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko \
  kernel/net/wireless/cfg80211.ko; do
  test -f "$modules/$module" || die "$module is missing from the staged modules"
done
grep -q '^kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e\.ko:' \
  "$modules/modules.dep" || die "mt7921e.ko is missing from staged modules.dep"
module_count=$(find "$modules" -name '*.ko*' | wc -l)

cp arch/x86/boot/bzImage /out/kernel/bzImage
cp .config /out/kernel/config
cp /tmp/config.diff /out/kernel/config-changes.diff
# AMD's licence for ps5_vcn.bin, which is now part of bzImage. The package
# installs it under /usr/share/licenses/linux-ps5.
cp /ps5-linux-patches/firmware/LICENSE.amdgpu /out/kernel/LICENSE.amdgpu
cp System.map Module.symvers /out/kernel/
{
  echo "Linux $KVER for the CachyOS 7.3 image, PS5 firmware 11.60"
  echo "Kernel:       v7.3, commit $LINUX_COMMIT"
  echo "Patch set:    rmuxnet/ps5-linux-patches-1, commit $PATCHES_COMMIT"
  echo "              linux.patch sha256 $PATCH_SHA256"
  echo "              .config sha256 $CONFIG_SHA256"
  echo "              firmware/amdgpu/ps5_vcn.bin $VCN_SIZE bytes, sha256 $VCN_SHA256 (built in)"
  echo "Bluetooth:    ps5-bazzite-deck v1.0.3 release asset ps5-btusb-quirks-fix.patch"
  echo "              vendored as ps5-btusb-iw620-quirks.patch sha256 $BTUSB_PATCH_SHA256"
  echo "Config:       X86_PS5_CPUFREQ=m PS5_GPUFREQ=m MT7921E=m, then olddefconfig; sha256 $(sha256sum .config | awk '{print $1}')"
  echo "Compiler:     $(x86_64-linux-gnu-gcc --version | head -1), $(uname -m) build host"
  echo "Version:      $(strings arch/x86/boot/bzImage | awk -v k="$KVER (" 'index($0, k) == 1 && !n { print; n = 1 }')"
  echo "bzImage:      $(stat -c %s arch/x86/boot/bzImage) bytes, sha256 $(sha256sum arch/x86/boot/bzImage | awk '{print $1}')"
  echo "Modules:      $module_count"
  echo
  "$CHECK" arch/x86/boot/bzImage
} > /out/kernel/kernel-build-info.txt
cat /out/kernel/kernel-build-info.txt
echo "=== Linux $KVER staged in /out/staging"
