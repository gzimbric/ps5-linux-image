#!/bin/bash
# Compiles the kernel and stages all artifacts into /out/staging.
# Runs inside Docker; kernel source is bind-mounted at /src.
set -e

EXACT_RUN16_KERNEL="${EXACT_RUN16_KERNEL:-0}"
BUILD_JOBS=$(nproc)

assert_sha256() {
    file=$1
    expected=$2
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        echo "ERROR: $file does not match the required Ubuntu 24.04 artifact" >&2
        echo "  expected: $expected" >&2
        echo "  actual:   $actual" >&2
        exit 1
    fi
}

if [ "$EXACT_RUN16_KERNEL" = 1 ]; then
    : "${JOBS:=12}"
    if [ "$JOBS" != 12 ]; then
        echo "ERROR: the exact Ubuntu 24.04 kernel build requires JOBS=12" >&2
        exit 1
    fi
    BUILD_JOBS=$JOBS
    export CCACHE_DISABLE=1
    export KBUILD_BUILD_USER=root
    export KBUILD_BUILD_HOST=2036ea00dc79
    export TZ=UTC
    export LC_ALL=C
    export PATH="/run16-repro-bin:$PATH"
    unset KBUILD_BUILD_VERSION
    # The hardware-tested Run 16 kernel was built with this variable unset.
    # The date shim supplies its fixed UTS string without changing the build
    # graph or the resulting bzImage.
    unset KBUILD_BUILD_TIMESTAMP
    test -x /run16-repro-bin/date
    rm -f .version

    expected_gcc='x86_64-linux-gnu-gcc (Debian 14.2.0-19) 14.2.0'
    expected_ld='GNU ld (GNU Binutils for Debian) 2.44'
    expected_pahole='v1.30'
    test "$(x86_64-linux-gnu-gcc --version | head -1)" = "$expected_gcc"
    test "$(x86_64-linux-gnu-ld --version | head -1)" = "$expected_ld"
    test "$(pahole --version)" = "$expected_pahole"
    expected_package_manifest=7fe661a35d6f87ce22beacbd162880155be4b848e8668d8c66ef2e6f2923583f
    package_manifest=$(
        dpkg-query -W -f='${binary:Package}=${Version}\n' \
            | LC_ALL=C sort | sha256sum | awk '{print $1}'
    )
    if [ "$package_manifest" != "$expected_package_manifest" ]; then
        echo "ERROR: kernel-builder package manifest changed" >&2
        echo "  expected: $expected_package_manifest" >&2
        echo "  actual:   $package_manifest" >&2
        dpkg-query -W -f='${binary:Package}=${Version}\n' \
            | LC_ALL=C sort >&2
        exit 1
    fi
fi

# Clean host-built tool artifacts that may reference wrong include paths
make -C tools/objtool clean 2>/dev/null || true

make olddefconfig

if [ "$EXACT_RUN16_KERNEL" = 1 ]; then
    assert_sha256 .config \
        a2444227c03aaedc240be4631bab29922b901a4b80a1a200f991c73b9d88c641

    # The successful kernel used a fixed timestamp for its otherwise-empty
    # embedded initramfs. Build once to generate the dependency list, replace
    # that archive deterministically, then force the final relink.
    rm -f .version
    make -j"$BUILD_JOBS" bzImage modules
    sh usr/gen_initramfs.sh \
        -o usr/initramfs_data.cpio \
        -l usr/.initramfs_data.cpio.d \
        -d 'Sat Aug 29 17:59:03 UTC 2026' \
        ./usr/default_cpio_list
    assert_sha256 usr/initramfs_data.cpio \
        f3155403fc625d38c9ef7dedff93666bf92c2ec1468147dc96e0e59c52e7fc21
    rm -f \
        .version \
        include/generated/utsversion.h \
        init/version-timestamp.o \
        vmlinux \
        vmlinux.unstripped \
        arch/x86/boot/bzImage
    make -j"$BUILD_JOBS" bzImage modules

    test "$(stat -c %s arch/x86/boot/bzImage)" = 12702720
    assert_sha256 arch/x86/boot/bzImage \
        11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
    assert_sha256 System.map \
        3c0ac3e4094f7e08dd6a85ef7a1ab7684bc794d6c866d5c003be781a4e346a14
    assert_sha256 modules.order \
        41bb1fa838dd9861b04fd82f966268813ed794aac897ec1e3211e397d2595059
    assert_sha256 modules.builtin \
        4efb450a9b9532079a37237113658107f74d14de05dc835625f7172a0d9acf7b
    assert_sha256 modules.builtin.modinfo \
        92954de8139df0a54c6afa9d5993ab7caaa7f666c1a16e2272473a23bf871b3e
    assert_sha256 modules.builtin.ranges \
        807161be2910933bfc5ec65fbdcc11e63cfb80321c52fe5036b83bd37255c895
    test -s Module.symvers

    # CONFIG_IKHEADERS=m, so its archive is not part of bzImage. Regenerate it
    # with a fixed timestamp after the proven kernel image has been reproduced.
    # Rebuild only kheaders.ko so its archive receives a deterministic timestamp
    # without relinking the proven vmlinux. A single-target kernel make removes
    # modules.order and rewrites Module.symvers, so preserve the already-verified
    # map and complete module metadata set, then restore it before modules_install.
    run16_metadata=$(mktemp -d)
    for metadata in \
        System.map \
        modules.order \
        modules.builtin \
        modules.builtin.modinfo \
        modules.builtin.ranges \
        Module.symvers; do
        cp "$metadata" "$run16_metadata/$metadata"
    done
    rm -f kernel/kheaders_data.tar.xz kernel/kheaders.o kernel/kheaders.ko
    make -j"$BUILD_JOBS" \
        KBUILD_BUILD_TIMESTAMP='Sat Aug 29 18:01:15 UTC 2026' \
        kernel/kheaders.ko
    assert_sha256 arch/x86/boot/bzImage \
        11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
    for metadata in \
        System.map \
        modules.order \
        modules.builtin \
        modules.builtin.modinfo \
        modules.builtin.ranges \
        Module.symvers; do
        cp "$run16_metadata/$metadata" "$metadata"
    done
    rm -r -- "$run16_metadata"
    assert_sha256 System.map \
        3c0ac3e4094f7e08dd6a85ef7a1ab7684bc794d6c866d5c003be781a4e346a14
    assert_sha256 modules.order \
        41bb1fa838dd9861b04fd82f966268813ed794aac897ec1e3211e397d2595059
    assert_sha256 modules.builtin \
        4efb450a9b9532079a37237113658107f74d14de05dc835625f7172a0d9acf7b
    assert_sha256 modules.builtin.modinfo \
        92954de8139df0a54c6afa9d5993ab7caaa7f666c1a16e2272473a23bf871b3e
    assert_sha256 modules.builtin.ranges \
        807161be2910933bfc5ec65fbdcc11e63cfb80321c52fe5036b83bd37255c895
    test -s Module.symvers
else
    make -j"$BUILD_JOBS" bzImage modules
fi

# Stage all artifacts so downstream packagers don't need to run make
echo "=== Staging build artifacts ==="
rm -rf /out/staging
mkdir -p /out/staging/boot

cp arch/x86/boot/bzImage /out/staging/boot/
cp System.map             /out/staging/
cp .config                /out/staging/

if [ "$EXACT_RUN16_KERNEL" = 1 ]; then
    make KBUILD_BUILD_TIMESTAMP='Sat Aug 29 18:01:15 UTC 2026' \
        modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1
else
    make modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1
fi

if [ "$EXACT_RUN16_KERNEL" = 1 ]; then
    module_root=/out/staging/lib/modules/7.1.7
    assert_sha256 "$module_root/modules.order" \
        386c8c15f5b3ebb9947f431fc8c08acfb6c28ffd0dc9bab2a1096071396c84d6
    assert_sha256 "$module_root/modules.builtin" \
        4efb450a9b9532079a37237113658107f74d14de05dc835625f7172a0d9acf7b
    assert_sha256 "$module_root/modules.builtin.modinfo" \
        92954de8139df0a54c6afa9d5993ab7caaa7f666c1a16e2272473a23bf871b3e
    assert_sha256 "$module_root/modules.builtin.ranges" \
        807161be2910933bfc5ec65fbdcc11e63cfb80321c52fe5036b83bd37255c895
    exact_kheaders=$module_root/kernel/kernel/kheaders.ko
    test -f "$exact_kheaders"
    assert_sha256 "$exact_kheaders" \
        84565f3ecaa2c5a05fa49d1c37034a999fbf7b672faff85f8a444d1cbac23dd3
    module_count=$(
        find "$module_root" -type f -name '*.ko' \
            ! -path "$module_root/kernel/kernel/kheaders.ko" | wc -l
    )
    test "$module_count" -eq 516
    module_manifest_hash=$(
        cd "$module_root"
        find . -type f -name '*.ko' \
            ! -path './kernel/kernel/kheaders.ko' -print0 \
            | LC_ALL=C sort -z \
            | while IFS= read -r -d '' module; do
                printf '%s  %s\n' \
                    "$(sha256sum "$module" | cut -d' ' -f1)" "$module"
            done \
            | sha256sum | cut -d' ' -f1
    )
    if [ "$module_manifest_hash" != \
        cd5788850c7cf8f724fde5d17a6be5cd7c04de22e00cd14829ff443ec50b3837 ]; then
        echo "ERROR: exact Ubuntu 24.04 runtime module set changed" >&2
        echo "  expected: cd5788850c7cf8f724fde5d17a6be5cd7c04de22e00cd14829ff443ec50b3837" >&2
        echo "  actual:   $module_manifest_hash" >&2
        exit 1
    fi

    exact_mts=/out/staging/lib/modules/7.1.7/kernel/drivers/net/phy/mts/mts.ko
    test -f "$exact_mts"
    assert_sha256 "$exact_mts" \
        2d7ac8e6ecce80e0f23b624cec66835325951c5bc9c4e620e5f57283caa279a2
fi

# Remove dangling symlinks back into the source tree
KVER=$(make -s kernelrelease)
rm -f "/out/staging/lib/modules/$KVER/build" \
      "/out/staging/lib/modules/$KVER/source"

if [ "$EXACT_RUN16_KERNEL" != 1 ]; then
    # The tested Ubuntu 24.04 package contained only the image and modules.
    # Keep headers in the ordinary builder path; adding them to this exact
    # package would also claim and replace Ubuntu's linux-libc-dev package.
    echo "=== Staging kernel headers ==="
    HDR="/out/staging/headers"
    make headers_install INSTALL_HDR_PATH="$HDR/usr"

    # Use the kernel's own install-extmod-build script (same as deb-pkg uses)
    export srctree=/src SRCARCH=x86
    CC="${CROSS_COMPILE}gcc" HOSTCC=gcc MAKE=make \
        /src/scripts/package/install-extmod-build "$HDR/lib/modules/$KVER/build"
fi

if [ "$EXACT_RUN16_KERNEL" = 1 ]; then
    # The proven control package ended here: kernel image plus in-tree modules,
    # with no headers, external modules, or wireless helper units.
    echo "=== Exact Ubuntu 24.04 build artifacts staged in /out/staging ==="
    exit 0
fi

# ---- NXP IW620 mwifiex driver (the PS5's onboard wifi) ----
# Build the out-of-tree moal+mlan modules against the kernel we just built
# and stage them into /out/staging so they get bundled in linux-ps5.{deb,rpm,
# pkg.tar.zst}. Without this, users get no wifi until they manually run
# ps5-linux-mwifiex/install.sh on the target (which needs gcc + headers).
echo "=== Building NXP IW620 mwifiex driver ==="
MWIFIEX_REPO="${MWIFIEX_REPO:-https://github.com/ps5-linux/ps5-linux-mwifiex.git}"
MWIFIEX_REF="${MWIFIEX_REF:-main}"
MWIFIEX_NXP_REPO=https://github.com/nxp-imx/mwifiex.git
MWIFIEX_NXP_REF=lf-6.18.2_1.0.0

PS5_MW=/tmp/ps5-linux-mwifiex
NXP_MW=/tmp/nxp-mwifiex
rm -rf "$PS5_MW" "$NXP_MW"
git clone "$MWIFIEX_REPO" "$PS5_MW"
git -C "$PS5_MW" checkout "$MWIFIEX_REF" 2>/dev/null || true
git clone --depth 1 --branch "$MWIFIEX_NXP_REF" "$MWIFIEX_NXP_REPO" "$NXP_MW"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620.patch"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620-cmd-timeout-recover.patch"
git -C "$NXP_MW" apply "$PS5_MW/ps5-iw620-kernel71-compat.patch"

# Build against the kernel source we just built (out-of-tree build needs
# the in-tree build dir, not just headers; same as install-extmod-build).
make -C "$NXP_MW" CONFIG_OBJTOOL= KERNELDIR=/src ARCH=x86 -j"$(nproc)"
[ -f "$NXP_MW/mlan.ko" ] && [ -f "$NXP_MW/moal.ko" ] \
    || { echo "ERROR: mwifiex build did not produce mlan.ko/moal.ko"; exit 1; }

EXTRA_DIR="/out/staging/lib/modules/$KVER/extra/ps5-iw620"
mkdir -p "$EXTRA_DIR"
install -m 0644 "$NXP_MW/mlan.ko" "$EXTRA_DIR/mlan.ko"
install -m 0644 "$NXP_MW/moal.ko" "$EXTRA_DIR/moal.ko"

# Modprobe + modules-load.d so the driver auto-loads at boot.
mkdir -p /out/staging/etc/modprobe.d /out/staging/etc/modules-load.d
echo moal > /out/staging/etc/modules-load.d/moal
cat > /out/staging/etc/modprobe.d/moal.conf <<'MPCONF'
# PS5 IW620 mwifiex (NXP moal/mlan, built out-of-tree by kernel-builder).
softdep moal pre: cfg80211 mlan
options moal fw_name=nxp/pcieuartiw620_combo_v1.bin pcie_int_mode=1 drv_mode=1 cfg80211_wext=4 sta_name=mlan ext_scan=1 auto_fw_reload=0 wifi_reset_config=0 sched_scan=0 ps_mode=2 auto_ds=2 amsdu_disable=1
MPCONF

# Rebuild module index so modprobe moal works without depmod -a post-install.
depmod -b /out/staging "$KVER"

# ---- PS5 runtime helpers packaged with the kernel ----
mkdir -p /out/staging/usr/local/sbin
mkdir -p /out/staging/etc/systemd/system/sysinit.target.wants
mkdir -p /out/staging/etc/systemd/system/multi-user.target.wants

cat > /out/staging/usr/local/sbin/ps5-stage-firmware <<'HELPER'
#!/bin/sh
set -eu
FW=nxp/pcieuartiw620_combo_v1.bin
if [ -f /run/ostree-booted ]; then
    DST_DIR=/etc/firmware
    echo "$DST_DIR" > /sys/module/firmware_class/parameters/path 2>/dev/null || true
else
    DST_DIR=/lib/firmware
fi
DST=$DST_DIR/$FW
[ -e "$DST" ] || for d in /efi /boot/efi /boot; do
    if [ -f "$d/lib/$FW" ]; then
        install -Dm644 "$d/lib/$FW" "$DST"
        break
    fi
done
modprobe -r moal mlan 2>/dev/null || true
modprobe moal 2>/dev/null || true
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-stage-firmware

cat > /out/staging/etc/systemd/system/ps5-stage-firmware.service <<'UNIT'
[Unit]
Description=Stage PS5 NXP IW620 wifi firmware from EFI partition
After=local-fs.target
Before=systemd-modules-load.service network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-stage-firmware
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT
ln -sf ../ps5-stage-firmware.service \
    /out/staging/etc/systemd/system/sysinit.target.wants/ps5-stage-firmware.service

cat > /out/staging/usr/local/sbin/ps5-bt-quiet <<'HELPER'
#!/bin/sh
for i in $(seq 1 15); do
    [ -n "$(ls /sys/class/bluetooth/hci* 2>/dev/null)" ] && break
    sleep 1
done
for h in /sys/class/bluetooth/hci*; do
    [ -e "$h/address" ] || continue
    idx=$(basename "$h" | sed 's/hci//')
    addr=$(cat "$h/address")
    if [ "$addr" = "00:00:00:00:00:00" ]; then
        hciconfig hci$idx down 2>/dev/null || btmgmt -i $idx power off 2>/dev/null || true
    else
        bluetoothctl -- select "$addr" >/dev/null 2>&1 || true
        bluetoothctl -- power on       >/dev/null 2>&1 || true
    fi
done
HELPER
chmod +x /out/staging/usr/local/sbin/ps5-bt-quiet

cat > /out/staging/etc/systemd/system/ps5-bt-quiet.service <<'UNIT'
[Unit]
Description=PS5: silence broken hciN + power the working one
After=bluetooth.service
Wants=bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ps5-bt-quiet
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
ln -sf ../ps5-bt-quiet.service \
    /out/staging/etc/systemd/system/multi-user.target.wants/ps5-bt-quiet.service

echo "=== Build artifacts staged in /out/staging ==="
