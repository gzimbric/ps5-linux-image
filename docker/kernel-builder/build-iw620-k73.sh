#!/bin/bash
# Builds the NXP IW620 Wi-Fi modules (mlan.ko, moal.ko) for the Linux 7.3.0
# kernel that docker/kernel-builder/build-k73.sh just built.
#
# The same driver as the 7.1.7 Ubuntu Wi-Fi build: nxp-imx/mwifiex a5fe4e1
# with the four ps5-linux-mwifiex 4aff908 patches, plus
# ps5-iw620-kernel73-compat.patch from this repository for the 7.3 cfg80211
# and string changes. It runs in the ps5-kernel-builder image with no
# network, the built kernel tree at /src (so the module CRCs come from this
# kernel's Module.symvers), the two driver repositories at /in (read-only),
# this repository at /repo (read-only) and the kernel output directory at
# /out. The modules go to /out/ps5-iw620. No firmware is involved here.
set -euo pipefail

KVER=7.3.0
PS5_MWIFIEX_COMMIT=4aff9085530a3cdf7d5fbb124c006cc299ac3605
NXP_MWIFIEX_COMMIT=a5fe4e194bf99315e349d81d77d6dfacec70757a
COMPAT=/repo/distros/cachyos1160-k73/kernel/ps5-iw620-kernel73-compat.patch
COMPAT_SHA256=899b4b1cd83bf6b85074d3aff311bbc104723e118a327aa65f7326546c789304
ALIAS='pci:v00001B4Bd00002B56sv*sd*bc*sc*i*'

die() { echo "ERROR: $*" >&2; exit 1; }
expect_sha256() { # file sha256
  local actual
  actual=$(sha256sum "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || die "$1: sha256 $actual, expected $2"
  echo "ok  $2  ${1##*/}"
}

# The kernel's build environment. CONFIG_OBJTOOL stays unset: upstream's
# install.sh passes CONFIG_OBJTOOL=, which leaves the modules without
# .return_sites on this rethunk kernel.
export KBUILD_BUILD_USER=ps5
export KBUILD_BUILD_HOST=ps5-linux-image
export TZ=UTC
export LC_ALL=C
export CCACHE_DISABLE=1
unset MAKEFLAGS CONFIG_OBJTOOL KBUILD_BUILD_TIMESTAMP KBUILD_BUILD_VERSION
JOBS=${JOBS:-$(nproc)}

test "$(x86_64-linux-gnu-gcc --version | head -1)" = \
  'x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0'
test "$(make -s -C /src kernelrelease)" = "$KVER"
grep -qx 'CONFIG_OBJTOOL=y' /src/.config
test -s /src/Module.symvers
test -f /src/net/wireless/cfg80211.ko

git config --global safe.directory '*'
git config --global advice.detachedHead false
rm -rf /build
mkdir -p /build
git clone -q --no-hardlinks /in/ps5-linux-mwifiex /build/ps5-linux-mwifiex
git -C /build/ps5-linux-mwifiex checkout -q --detach "$PS5_MWIFIEX_COMMIT"
git clone -q --no-hardlinks /in/nxp-mwifiex /build/nxp
git -C /build/nxp checkout -q --detach "$NXP_MWIFIEX_COMMIT"
test "$(git -C /build/ps5-linux-mwifiex rev-parse HEAD)" = "$PS5_MWIFIEX_COMMIT"
test "$(git -C /build/nxp rev-parse HEAD)" = "$NXP_MWIFIEX_COMMIT"

# ps5-iw620-kernel72-compat.patch is left out on purpose: its 7.2
# remain_on_channel prototype does not build on 7.3, and its strscpy changes
# copy one byte less than the original code.
cd /build/nxp
while read -r patch expected; do
  expect_sha256 "/build/ps5-linux-mwifiex/$patch" "$expected"
  git apply "/build/ps5-linux-mwifiex/$patch"
  echo "applied $patch"
done <<'EOF'
ps5-iw620.patch ce5e7f72c15785b18948761474735ec26d80458d9e6dc39b207bf0ad31688f3a
ps5-iw620-cmd-timeout-recover.patch 3cf0a8fe9a15a139c37367c20f3cd5567e44e55d948fc7cb54f62c0c2bec7053
ps5-iw620-kernel71-compat.patch 7c091f69db2725b2fa52d01bb21126fe21c8bf97c9ec9ce87ca3340d29c5017c
ps5-iw620-rtnl-bounded-wait.patch 9b63bdd86301ca65768836dc6f7baa94797e5981d6d572c44f53e0512cc1fe1a
EOF
expect_sha256 "$COMPAT" "$COMPAT_SHA256"
git apply "$COMPAT"
echo "applied ${COMPAT##*/}"

make -C /build/nxp KERNELDIR=/src ARCH=x86 -j"$JOBS" 2>&1 | tee /tmp/iw620-make.log
# A clean build has no compiler, objtool or modpost warnings.
if grep -E 'warning:|error:|WARNING:' /tmp/iw620-make.log; then
  die "the IW620 build printed warnings"
fi

out=/out/ps5-iw620
rm -rf "$out"
mkdir -p "$out"
for module in mlan moal; do
  install -m 0644 "/build/nxp/$module.ko" "$out/$module.ko"
  x86_64-linux-gnu-strip --strip-debug "$out/$module.ko"
  sections=$(x86_64-linux-gnu-readelf -S "$out/$module.ko")
  grep -qF .return_sites <<<"$sections" || die "$module.ko has no .return_sites (objtool did not run)"
  if grep -qF .BTF <<<"$sections"; then
    die "$module.ko has BTF, but this kernel has none"
  fi
  if x86_64-linux-gnu-nm -u "$out/$module.ko" | grep -qw strncpy; then
    die "$module.ko still calls strncpy, which 7.3 does not export"
  fi
  test "$(modinfo -F vermagic "$out/$module.ko")" = \
    "$(modinfo -F vermagic /src/net/wireless/cfg80211.ko)"
done
test "$(modinfo -F alias "$out/moal.ko")" = "$ALIAS"
modinfo -F version "$out/moal.ko"
cp /tmp/iw620-make.log "$out/build.log"
(cd "$out" && sha256sum mlan.ko moal.ko | tee SHA256SUMS)
echo "=== IW620 modules for $KVER in $out"
