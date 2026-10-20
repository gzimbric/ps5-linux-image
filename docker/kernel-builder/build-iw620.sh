#!/bin/bash
# Builds the NXP IW620 Wi-Fi modules (mlan.ko, moal.ko) for the exact Ubuntu
# 24.04 kernel, the same way as the modules that ran on the console in Run 17.
# Runs in ps5-kernel-builder with the built kernel tree at /src, the two pinned
# driver repositories at /in (read-only) and the kernel output directory at
# /out. The modules go to /out/ps5-iw620. No firmware is involved here.
set -euo pipefail

PS5_MWIFIEX_COMMIT=4aff9085530a3cdf7d5fbb124c006cc299ac3605
NXP_MWIFIEX_COMMIT=a5fe4e194bf99315e349d81d77d6dfacec70757a
MLAN_SHA256=e6f8e649974767f26d9bd8c60b3b49e1203d5282700493864b7e6fd7be482b23
MOAL_SHA256=3e00f26af4d71d6f459a56a1b99c435dcacb09d3ead28e0e722898a68a6347ed

assert_sha256() {
    file=$1
    expected=$2
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $file does not match the Run 17 IW620 build" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

# The environment the kernel was built in. CONFIG_OBJTOOL stays unset:
# upstream's install.sh passes CONFIG_OBJTOOL=, which leaves the modules
# without .return_sites on this rethunk kernel.
export CCACHE_DISABLE=1
export KBUILD_BUILD_USER=root
export KBUILD_BUILD_HOST=2036ea00dc79
export TZ=UTC
export LC_ALL=C
export PATH="/run16-repro-bin:$PATH"
unset KBUILD_BUILD_VERSION KBUILD_BUILD_TIMESTAMP CONFIG_OBJTOOL MAKEFLAGS

test "$(x86_64-linux-gnu-gcc --version | head -1)" = \
    'x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0'
test "$(x86_64-linux-gnu-ld --version | head -1)" = \
    'GNU ld (GNU Binutils for Debian) 2.44'
test "$(make -s -C /src kernelrelease)" = 7.1.7
assert_sha256 /src/.config \
    a2444227c03aaedc240be4631bab29922b901a4b80a1a200f991c73b9d88c641
assert_sha256 /src/arch/x86/boot/bzImage \
    11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
test -s /src/Module.symvers
test -f /src/vmlinux

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

# ps5-iw620-kernel72-compat.patch is left out on purpose. It changes
# remain_on_channel to the 7.2 prototype, which does not build on 7.1.7.
cd /build/nxp
while read -r patch expected; do
    assert_sha256 "/build/ps5-linux-mwifiex/$patch" "$expected"
    git apply "/build/ps5-linux-mwifiex/$patch"
    echo "Applied $patch"
done <<'EOF'
ps5-iw620.patch ce5e7f72c15785b18948761474735ec26d80458d9e6dc39b207bf0ad31688f3a
ps5-iw620-cmd-timeout-recover.patch 3cf0a8fe9a15a139c37367c20f3cd5567e44e55d948fc7cb54f62c0c2bec7053
ps5-iw620-kernel71-compat.patch 7c091f69db2725b2fa52d01bb21126fe21c8bf97c9ec9ce87ca3340d29c5017c
ps5-iw620-rtnl-bounded-wait.patch 9b63bdd86301ca65768836dc6f7baa94797e5981d6d572c44f53e0512cc1fe1a
EOF

# Run 17 built against a prepared kernel tree that had no vmlinux, so kbuild
# skipped module BTF. Hide vmlinux for the build to get the same bytes. The
# kernel loads modules without BTF; only BPF tracing of them loses type data.
restore_vmlinux() {
    if [ -f /src/.vmlinux.iw620 ]; then
        mv /src/.vmlinux.iw620 /src/vmlinux
    fi
}
trap restore_vmlinux EXIT
mv /src/vmlinux /src/.vmlinux.iw620
make -C /build/nxp KERNELDIR=/src ARCH=x86 -j12
restore_vmlinux

out=/out/ps5-iw620
rm -rf "$out"
mkdir -p "$out"
for module in mlan moal; do
    install -m 0644 "/build/nxp/$module.ko" "$out/$module.ko"
    x86_64-linux-gnu-strip --strip-debug "$out/$module.ko"
    sections=$(x86_64-linux-gnu-readelf -S "$out/$module.ko")
    grep -qF .return_sites <<<"$sections"
    if grep -qF .BTF <<<"$sections"; then
        echo "ERROR: $module.ko has BTF; vmlinux was visible to the build" >&2
        exit 1
    fi
done
assert_sha256 "$out/mlan.ko" "$MLAN_SHA256"
assert_sha256 "$out/moal.ko" "$MOAL_SHA256"
test "$(modinfo -F vermagic "$out/moal.ko")" = \
    "$(modinfo -F vermagic /out/staging/lib/modules/7.1.7/kernel/net/wireless/cfg80211.ko)"
test "$(modinfo -F alias "$out/moal.ko")" = 'pci:v00001B4Bd00002B56sv*sd*bc*sc*i*'
(cd "$out" && sha256sum mlan.ko moal.ko)
echo "=== IW620 modules match the Run 17 build ==="
