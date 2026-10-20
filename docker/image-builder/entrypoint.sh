#!/bin/bash
set -ex

DISTRO="${DISTRO:-ubuntu2604}"
IMG_SIZE="${IMG_SIZE:-12000}"
SKIP_CHROOT="${SKIP_CHROOT:-false}"
STAGING="/tmp/build-staging"
ROOT_LABEL="${DISTRO}"
EFI_LABEL="boot"
CHROOT="/build/chroot"
IMG="/output/ps5-${DISTRO}.img"
UBUNTU2404_PROFILE_MARKER=""

validate_ubuntu2404_rootfs_kernel() {
    UBUNTU2404_ROOT="$CHROOT" /bin/bash -euo pipefail <<'VERIFY_ROOTFS_KERNEL'
export LC_ALL=C

fail() {
    echo "ERROR: Ubuntu 24.04 rootfs kernel validation: $*" >&2
    exit 1
}

sha256_file() {
    sha256sum "$1" | awk '{print $1}'
}

assert_equal() {
    label=$1
    actual=$2
    expected=$3
    [ "$actual" = "$expected" ] ||
        fail "$label is $actual; expected $expected"
}

assert_file_sha256() {
    path=$1
    expected=$2
    label=$3
    [ -f "$path" ] || fail "missing $label: $path"
    assert_equal "$label SHA-256" "$(sha256_file "$path")" "$expected"
}

root=${UBUNTU2404_ROOT:?}
[ -d "$root" ] || fail "rootfs directory does not exist: $root"

mapfile -t installed_kernels < <(
    find "$root/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | sort
)
assert_equal "installed kernel directory count" "${#installed_kernels[@]}" 1
assert_equal "installed kernel version" "${installed_kernels[0]}" 7.1.7

assert_file_sha256 "$root/boot/vmlinuz-7.1.7" \
    11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde \
    vmlinuz-7.1.7
assert_equal "vmlinuz-7.1.7 size" \
    "$(stat -c %s "$root/boot/vmlinuz-7.1.7")" 12702720
assert_file_sha256 "$root/boot/config-7.1.7" \
    a2444227c03aaedc240be4631bab29922b901a4b80a1a200f991c73b9d88c641 \
    config-7.1.7
assert_file_sha256 "$root/boot/System.map-7.1.7" \
    3c0ac3e4094f7e08dd6a85ef7a1ab7684bc794d6c866d5c003be781a4e346a14 \
    System.map-7.1.7

modules=$root/lib/modules/7.1.7
kheaders=$modules/kernel/kernel/kheaders.ko
mts=$modules/kernel/drivers/net/phy/mts/mts.ko
[ ! -e "$modules/build" ] && [ ! -L "$modules/build" ] ||
    fail "unexpected kernel build link: $modules/build"
[ ! -e "$modules/source" ] && [ ! -L "$modules/source" ] ||
    fail "unexpected kernel source link: $modules/source"
assert_file_sha256 "$mts" \
    2d7ac8e6ecce80e0f23b624cec66835325951c5bc9c4e620e5f57283caa279a2 \
    mts.ko
assert_file_sha256 "$kheaders" \
    84565f3ecaa2c5a05fa49d1c37034a999fbf7b672faff85f8a444d1cbac23dd3 \
    kheaders.ko

# 517 modules from the kernel package plus the two IW620 Wi-Fi modules.
module_count=$(find "$modules" -type f -name '*.ko' -printf x | wc -c)
module_count=${module_count//[[:space:]]/}
assert_equal "kernel module count" "$module_count" 519

iw620_files=$(cd "$modules" && find ./updates -type f -print | sort)
assert_equal "IW620 module files" "$iw620_files" \
    "$(printf '%s\n' ./updates/ps5-iw620/mlan.ko ./updates/ps5-iw620/moal.ko)"
assert_file_sha256 "$modules/updates/ps5-iw620/mlan.ko" \
    e6f8e649974767f26d9bd8c60b3b49e1203d5282700493864b7e6fd7be482b23 \
    mlan.ko
assert_file_sha256 "$modules/updates/ps5-iw620/moal.ko" \
    3e00f26af4d71d6f459a56a1b99c435dcacb09d3ead28e0e722898a68a6347ed \
    moal.ko

non_kheaders_count=$(
    cd "$modules"
    find . -type f -name '*.ko' ! -path './updates/*' \
        ! -path './kernel/kernel/kheaders.ko' -printf x | wc -c
)
non_kheaders_count=${non_kheaders_count//[[:space:]]/}
assert_equal "non-kheaders module count" "$non_kheaders_count" 516

non_kheaders_manifest=$(
    cd "$modules"
    find . -type f -name '*.ko' ! -path './updates/*' \
        ! -path './kernel/kernel/kheaders.ko' -print0 |
        sort -z |
        xargs -0 sha256sum |
        sha256sum | awk '{print $1}'
)
assert_equal "non-kheaders module manifest" \
    "$non_kheaders_manifest" \
    cd5788850c7cf8f724fde5d17a6be5cd7c04de22e00cd14829ff443ec50b3837

symbol_value() {
    symbol=$1
    mapfile -t values < <(
        nm -n -- "$kheaders" | awk -v symbol="$symbol" '$3 == symbol {print $1}'
    )
    [ "${#values[@]}" -eq 1 ] ||
        fail "expected one $symbol symbol in kheaders.ko"
    case ${values[0]} in
        ''|*[!0-9A-Fa-f]*) fail "invalid $symbol value: ${values[0]}" ;;
    esac
    printf '%s\n' "${values[0]}"
}

tmp=$(mktemp -d)
cleanup() {
    rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

rodata=$tmp/kheaders.rodata
objcopy --dump-section .rodata="$rodata" \
    "$kheaders" "$tmp/kheaders-copy.ko"
[ -s "$rodata" ] || fail 'kheaders.ko has no nonempty .rodata section'

archive_start_hex=$(symbol_value kernel_headers_data)
archive_end_hex=$(symbol_value kernel_headers_data_end)
rodata_vma_hex=$(objdump -h -- "$kheaders" | awk '$2 == ".rodata" {print $4}')
case $rodata_vma_hex in
    ''|*[!0-9A-Fa-f]*) fail 'could not determine kheaders.ko .rodata address' ;;
esac

archive_start=$((16#$archive_start_hex))
archive_end=$((16#$archive_end_hex))
rodata_vma=$((16#$rodata_vma_hex))
[ "$archive_end" -gt "$archive_start" ] ||
    fail 'invalid embedded kheaders archive bounds'
[ "$archive_start" -ge "$rodata_vma" ] ||
    fail 'embedded kheaders archive starts before .rodata'
archive_offset=$((archive_start - rodata_vma))
archive_size=$((archive_end - archive_start))
rodata_size=$(stat -c %s "$rodata")
[ $((archive_offset + archive_size)) -le "$rodata_size" ] ||
    fail 'embedded kheaders archive extends past .rodata'

archive=$tmp/kheaders.tar.xz
dd if="$rodata" of="$archive" iflag=skip_bytes,count_bytes \
    skip="$archive_offset" count="$archive_size" status=none
assert_equal "embedded kheaders archive size" \
    "$(stat -c %s "$archive")" "$archive_size"
xz --test "$archive" || fail 'embedded kheaders archive is not valid XZ'

headers=$tmp/kheaders
mkdir "$headers"
tar --extract --xz --file "$archive" --directory "$headers" \
    --no-same-owner --no-same-permissions
header_count=$(find "$headers" -type f -printf x | wc -c)
header_count=${header_count//[[:space:]]/}
assert_equal "embedded kheaders regular-file count" "$header_count" 7069
header_manifest=$(
    cd "$headers"
    find . -type f -print0 |
        sort -z |
        xargs -0 sha256sum |
        sha256sum | awk '{print $1}'
)
assert_equal "embedded kheaders content manifest" \
    "$header_manifest" \
    6212fdada4054c4bb2bec76e45fb04602c65cf5bec372bea380e3a249b083f75

echo 'Ubuntu 24.04 installed kernel tree: OK'
VERIFY_ROOTFS_KERNEL
}

if [ "$DISTRO" = "ubuntu2404" ]; then
    : "${UBUNTU2404_PROFILE_ID:?Ubuntu 24.04 recipe profile ID is required}"
    if [ "$IMG_SIZE" != 16000 ]; then
        echo "ERROR: Ubuntu 24.04 requires a 16000 MiB tested-layout image" >&2
        exit 1
    fi
    case "$UBUNTU2404_PROFILE_ID" in
        *[!0-9a-f]*|'')
            echo "ERROR: invalid Ubuntu 24.04 recipe profile ID" >&2
            exit 1
            ;;
    esac
    test "${#UBUNTU2404_PROFILE_ID}" -eq 64
    actual_profile_id=$(/repo/scripts/ubuntu2404-profile-id.sh)
    if [ "$actual_profile_id" != "$UBUNTU2404_PROFILE_ID" ]; then
        echo "ERROR: mounted Ubuntu 24.04 recipe does not match its profile ID" >&2
        echo "  expected: $UBUNTU2404_PROFILE_ID" >&2
        echo "  actual:   $actual_profile_id" >&2
        exit 1
    fi
    UBUNTU2404_PROFILE_MARKER="ubuntu2404-1160-recipe-$UBUNTU2404_PROFILE_ID"
fi

# Detect kernel version from the staged kernel package (used by bazzite +
# batocera rootfs builders which install the linux-ps5 kernel manually).
detect_kver() {
    for f in /kernel-debs/linux-ps5-*.rpm /kernel-debs/linux-ps5_*.deb \
             /kernel-debs/linux-ps5-*.pkg.tar.zst; do
        [ -f "$f" ] || continue
        echo "$(basename "$f")" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
        return 0
    done
}
KVER="$(detect_kver)"
[ -n "$KVER" ] || { echo "WARN: could not detect KVER from /kernel-debs/"; }
export KVER

if [ "$DISTRO" = "ubuntu2404" ] && [ "$SKIP_CHROOT" = "true" ]; then
    if ! grep -qxF "$UBUNTU2404_PROFILE_MARKER" \
        "$CHROOT/etc/ps5-image-profile" 2>/dev/null; then
        echo "=== Cached rootfs is not the Ubuntu 24.04 tested profile; rebuilding ==="
        SKIP_CHROOT=false
    elif ! validate_ubuntu2404_rootfs_kernel; then
        echo "=== Cached Ubuntu 24.04 kernel tree failed validation; rebuilding ==="
        SKIP_CHROOT=false
    fi
fi

if [ "$SKIP_CHROOT" = "true" ] && [ -d "$CHROOT/bin" ]; then
    echo "=== Reusing cached $DISTRO rootfs ==="
elif [ -x "/repo/distros/${DISTRO}/build-rootfs.sh" ]; then
    # Distros with their own build-rootfs.sh (bazzite, bazzite-deck, batocera, ...)
    # are responsible for populating $CHROOT themselves — distrobuilder is
    # bypassed entirely. Most often used for OCI atomic images (bazzite via
    # skopeo+umoci) or pre-built rootfs images (batocera squashfs).
    echo "=== Building $DISTRO rootfs via distros/${DISTRO}/build-rootfs.sh ==="
    [ -n "$CHROOT" ] || { echo "FATAL: \$CHROOT empty"; exit 1; }
    mkdir -p "$CHROOT"
    rm -rf "${CHROOT:?}"/* "${CHROOT:?}"/.[!.]* 2>/dev/null || true
    DISTRO="$DISTRO" CHROOT="$CHROOT" KVER="$KVER" \
        ROOT_LABEL="$ROOT_LABEL" EFI_LABEL="$EFI_LABEL" \
        bash "/repo/distros/${DISTRO}/build-rootfs.sh"
else
    echo "=== Building $DISTRO rootfs ==="
    # --- Stage files for distrobuilder's copy generators ---
    rm -rf "$STAGING"
    mkdir -p "$STAGING/debs"
    cp /repo/distros/shared/zz-update-boot      "$STAGING/"
    # Generate per-distro fstab with partition labels
    cat <<EOF > "$STAGING/fstab"
# /etc/fstab: static file system information.
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
LABEL=$ROOT_LABEL / ext4 defaults 0 1
LABEL=$EFI_LABEL /boot/efi vfat defaults 0 1
EOF
    if [ "$DISTRO" = "ubuntu2404" ]; then
        cp /repo/distros/${DISTRO}/nm-dns.conf "$STAGING/"
    else
        cp /repo/distros/${DISTRO}/nm-dns.conf "$STAGING/" 2>/dev/null || true
    fi

    case "$DISTRO" in
        ubuntu*)
            cp /repo/distros/${DISTRO}/grow-rootfs       "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            cp /kernel-debs/*.deb                          "$STAGING/debs/"
            if [ "$DISTRO" = "ubuntu2404" ]; then
                mkdir -p "$STAGING/ps5-bootstrap"
                cp /repo/distros/ubuntu2404/files/ps5-boot-report \
                   /repo/distros/ubuntu2404/files/ps5-boot-report.service \
                   /repo/distros/ubuntu2404/files/ps5-boot-report.timer \
                   /repo/distros/ubuntu2404/files/ps5-amdgpu-reprobe \
                   /repo/distros/ubuntu2404/files/ps5-amdgpu-reprobe.service \
                   /repo/distros/ubuntu2404/files/ps5_fan_max.c \
                   /repo/distros/ubuntu2404/files/ps5fan.service \
                   /repo/distros/ubuntu2404/files/ps5-iw620.conf \
                   /repo/distros/ubuntu2404/files/ps5-iw620-firmware \
                   /repo/distros/ubuntu2404/files/ps5-iw620-firmware.service \
                   "$STAGING/ps5-bootstrap/"
                mkdir -p "$STAGING/ps5-iw620"
                cp /kernel-debs/ps5-iw620/mlan.ko \
                   /kernel-debs/ps5-iw620/moal.ko \
                   "$STAGING/ps5-iw620/"
            fi
            ;;
        proxmox)
            cp /repo/distros/${DISTRO}/grow-rootfs          "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service  "$STAGING/"
            cp /repo/distros/${DISTRO}/proxmox-release-bookworm.gpg "$STAGING/"
            cp /kernel-debs/*.deb                           "$STAGING/debs/"
            ;;
        debian)
            cp /repo/distros/${DISTRO}/grow-rootfs          "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service  "$STAGING/"
            cp /kernel-debs/*.deb                           "$STAGING/debs/"
            ;;
        fedora)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/${DISTRO}/grow-rootfs.service "$STAGING/"
            mkdir -p "$STAGING/rpms"
            cp /kernel-debs/*.rpm                          "$STAGING/rpms/"
            ;;
        arch)
            cp /repo/distros/${DISTRO}/grow-rootfs         "$STAGING/"
            cp /repo/distros/arch/grow-rootfs.service      "$STAGING/"
            cp /repo/distros/arch/first-boot-setup         "$STAGING/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                  "$STAGING/pkgs/"
            ;;
        cachyos)
            mkdir -p "$STAGING/files"
            cp /repo/distros/cachyos/files/grow-rootfs                "$STAGING/files/"
            cp /repo/distros/cachyos/files/grow-rootfs.service        "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot-setup           "$STAGING/files/"
            cp /repo/distros/cachyos/files/first-boot.service         "$STAGING/files/"
            cp /repo/distros/cachyos/files/gamescope-session-ps5      "$STAGING/files/"
            cp /repo/distros/cachyos/files/steamos-session-select     "$STAGING/files/"
            cp /repo/distros/cachyos/files/return-to-gaming-mode.desktop "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-display.lua            "$STAGING/files/"
            cp /repo/distros/cachyos/files/plasma-workspace-env-ps5.sh "$STAGING/files/"
            cp /repo/distros/cachyos/files/ps5-tty-session.sh         "$STAGING/files/"
            mkdir -p "$STAGING/pkgs"
            cp /kernel-debs/*.pkg.tar.zst                             "$STAGING/pkgs/"
            ;;
    esac

    find "$STAGING" -type f \
        ! -path "$STAGING/debs/*" \
        ! -path "$STAGING/pkgs/*" \
        ! -path "$STAGING/rpms/*" \
        ! -path "$STAGING/ps5-iw620/*" \
        -exec sed -i 's/\r$//' {} +

    # --- Build rootfs ---
    rm -rf "${CHROOT:?}"/* "${CHROOT:?}"/.[!.]* 2>/dev/null || true

    YAML="/repo/distros/${DISTRO}/image.yaml"
    distrobuilder build-dir "$YAML" "$CHROOT" --with-post-files --cache-dir /build/cache --cleanup=false
fi

# --- Post-distrobuilder fixups ---
case "$DISTRO" in
    ubuntu*)
        if [ "$DISTRO" = "ubuntu2404" ]; then
            # A valid cache marker is written only after every reusable-rootfs
            # invariant below succeeds. An interrupted validation stays invalid.
            rm -f "$CHROOT/etc/ps5-image-profile" \
                "$CHROOT/etc/ps5-image-profile.new"
        fi
        rm -f "$CHROOT/etc/resolv.conf"
        ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT/etc/resolv.conf"
        if [ "$DISTRO" = "ubuntu2404" ]; then
            # Public images deliberately ship no authorized key. SSH is
            # password-authenticated for ps5 until the default password is
            # changed by the user after first boot.
            if find "$CHROOT/root" "$CHROOT/home" \
                \( -type f -o -type l \) \
                \( -name authorized_keys -o -name authorized_keys2 \) \
                -print -quit | grep -q .; then
                echo "ERROR: reusable Ubuntu 24.04 rootfs contains authorized_keys" >&2
                exit 1
            fi

            test "$(sha256sum "$CHROOT/etc/fstab" | awk '{print $1}')" = \
                6508f0eb9f9f923c9cc1155197baaa62a782c8291ece71ad60b66f8b3c6a3176
            test "$(grep -Ev '^[[:space:]]*(#|$)' "$CHROOT/etc/fstab" | wc -l)" -eq 2
            grep -qxF 'LABEL=ubuntu2404 / ext4 defaults 0 1' "$CHROOT/etc/fstab"
            grep -qxF 'LABEL=boot /boot/efi vfat defaults 0 1' "$CHROOT/etc/fstab"
            test "$(sha256sum "$CHROOT/etc/NetworkManager/conf.d/dns.conf" | awk '{print $1}')" = \
                80ee32ae2b4038691ef64248f5794e7d59cc34e626e181482af8037a0e338c04
            test "$(readlink "$CHROOT/etc/resolv.conf")" = \
                /run/systemd/resolve/stub-resolv.conf
            test -x "$CHROOT/usr/local/sbin/grow-rootfs"
            bash -n "$CHROOT/usr/local/sbin/grow-rootfs"
            test "$(sha256sum "$CHROOT/usr/local/sbin/grow-rootfs" | awk '{print $1}')" = \
                a7e1831a568c0061b8d5591e61a152ed1d0820dd92426c6719c4ccdd55311ce6
            test "$(sha256sum "$CHROOT/etc/systemd/system/grow-rootfs.service" | awk '{print $1}')" = \
                67c340bf127383993dadbe9dda2695954b5baa5b13b6d79e83e4ae3f402250da
            chroot "$CHROOT" systemctl is-enabled grow-rootfs.service >/dev/null
            chroot "$CHROOT" systemctl is-enabled systemd-resolved.service >/dev/null
            chroot "$CHROOT" systemctl is-enabled ps5-ssh-host-keys.service >/dev/null
            test -f "$CHROOT/etc/systemd/system/ssh.service.d/10-ps5-host-keys.conf"
            test -f "$CHROOT/etc/systemd/system/ssh.socket.d/10-ps5-host-keys.conf"
            if find "$CHROOT/etc/ssh" -maxdepth 1 -name 'ssh_host_*' \
                -print -quit | grep -q .; then
                echo "ERROR: reusable Ubuntu 24.04 rootfs contains SSH host keys" >&2
                exit 1
            fi

            validate_ubuntu2404_rootfs_kernel

            # Package installation may seed both machine-ID locations from
            # the build VM. Leave the public image uninitialized so systemd
            # creates a unique ID on its first boot.
            rm -f "$CHROOT/etc/machine-id"
            install -o root -g root -m 0444 /dev/null \
                "$CHROOT/etc/machine-id"
            mkdir -p "$CHROOT/var/lib/dbus"
            rm -f "$CHROOT/var/lib/dbus/machine-id"
            ln -s /etc/machine-id "$CHROOT/var/lib/dbus/machine-id"
            test -f "$CHROOT/etc/machine-id"
            test ! -L "$CHROOT/etc/machine-id"
            test ! -s "$CHROOT/etc/machine-id"
            test "$(stat -c '%u:%g:%a' "$CHROOT/etc/machine-id")" = 0:0:444
            test "$(readlink "$CHROOT/var/lib/dbus/machine-id")" = \
                /etc/machine-id

            printf '%s\n' "$UBUNTU2404_PROFILE_MARKER" \
                > "$CHROOT/etc/ps5-image-profile.new"
            chmod 0644 "$CHROOT/etc/ps5-image-profile.new"
            mv "$CHROOT/etc/ps5-image-profile.new" \
                "$CHROOT/etc/ps5-image-profile"
        fi
        ;;
esac

# --- Create GPT disk image ---
echo "=== Creating ${IMG_SIZE}MB disk image ==="
TMPIMG="/output/.ps5-${DISTRO}.img.tmp"
LOOPDEV=""
ROOT_MOUNTED=false
EFI_MOUNTED=false

cleanup_image() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ "$status" -ne 0 ] && [ "$DISTRO" = "ubuntu2404" ]; then
        # Any failed image assembly invalidates the reusable rootfs marker.
        # This includes inline boot-envelope failures that happen before the
        # detached full-image audit is reached.
        rm -f "$CHROOT/etc/ps5-image-profile"
    fi
    mountpoint -q /tmp/usb_root && umount /tmp/usb_root
    mountpoint -q /tmp/usb_efi && umount /tmp/usb_efi
    if [ -n "$LOOPDEV" ]; then
        if mountpoint -q /tmp/usb_root || mountpoint -q /tmp/usb_efi; then
            echo "WARNING: leaving $LOOPDEV attached because an image mount is still active" >&2
        else
            kpartx -dv "$LOOPDEV" >/dev/null 2>&1
            losetup -d "$LOOPDEV" >/dev/null 2>&1
        fi
    fi
    exit "$status"
}
trap cleanup_image EXIT
trap 'exit 1' HUP INT TERM

rm -f "$TMPIMG"
truncate -s "${IMG_SIZE}M" "$TMPIMG"
sync

parted -s "$TMPIMG" mklabel gpt
parted -s "$TMPIMG" mkpart primary ext4  500MiB 100%
parted -s "$TMPIMG" mkpart primary fat32 1MiB   500MiB
parted -s "$TMPIMG" set 2 esp on

# Ensure the free loop device node exists (udev doesn't run inside containers,
# so when the kernel allocates a new loop number it may lack a /dev node)
LOOP_PATH=$(losetup -f)
if [ ! -e "$LOOP_PATH" ]; then
    LOOP_NUM=${LOOP_PATH#/dev/loop}
    mknod "$LOOP_PATH" b 7 "$LOOP_NUM"
fi

LOOPDEV=$(losetup -f --show "$TMPIMG")
# Use kpartx to create partition device mappings (more reliable in containers)
kpartx -av "$LOOPDEV"
sleep 1

# kpartx creates /dev/mapper/loopXp1, /dev/mapper/loopXp2
LOOP_BASE=$(basename "$LOOPDEV")
PART1="/dev/mapper/${LOOP_BASE}p1"
PART2="/dev/mapper/${LOOP_BASE}p2"

attempts=0
while { [ ! -b "$PART1" ] || [ ! -b "$PART2" ]; } && \
    [ "$attempts" -lt 20 ]; do
    sleep 1
    attempts=$((attempts + 1))
done
[ -b "$PART1" ] || {
    echo "ERROR: missing root partition mapping: $PART1" >&2
    exit 1
}
[ -b "$PART2" ] || {
    echo "ERROR: missing boot partition mapping: $PART2" >&2
    exit 1
}

echo "=== Formatting partitions ==="
mkfs.ext4 -L "$ROOT_LABEL" -m 1  "$PART1"
mkfs.vfat -n "$EFI_LABEL"  -F32  "$PART2"

mkdir -p /tmp/usb_root /tmp/usb_efi
mount "$PART1" /tmp/usb_root
ROOT_MOUNTED=true
mount "$PART2" /tmp/usb_efi
EFI_MOUNTED=true

echo "=== Copying rootfs to image ==="
cp -a "$CHROOT"/* /tmp/usb_root/
sync

echo "=== Assembling boot partition ==="
# Batocera mounts the FAT32 partition at /boot (not /boot/efi) so its
# batocera-part SHARE auto-detection works (greps /proc/mounts for /boot).
# Detect either layout and copy from the right place.
if [ -d /tmp/usb_root/boot/efi ] && [ -n "$(ls -A /tmp/usb_root/boot/efi 2>/dev/null)" ]; then
    mv /tmp/usb_root/boot/efi/* /tmp/usb_efi/ 2>/dev/null || true
elif [ -f /tmp/usb_root/boot/bzImage ]; then
    # batocera-style: bzImage + cmdline + everything else lives directly
    # in /boot. Move everything into the EFI partition so the PS5 loader
    # can find bzImage/initrd.img/cmdline.txt at the FAT root.
    mv /tmp/usb_root/boot/* /tmp/usb_efi/ 2>/dev/null || true
fi
CMDLINE_TEMPLATE="/repo/distros/${DISTRO}/cmdline.txt"
[ -f "$CMDLINE_TEMPLATE" ] || CMDLINE_TEMPLATE="/repo/boot/cmdline.txt"
sed "s|__DISTRO__|$ROOT_LABEL|" "$CMDLINE_TEMPLATE" > /tmp/usb_efi/cmdline.txt
cp /repo/boot/vram.txt     /tmp/usb_efi/
cp /repo/boot/kexec.sh     /tmp/usb_efi/

if [ "$DISTRO" = "ubuntu2404" ]; then
    echo "=== Verifying Ubuntu 24.04 tested boot envelope ==="
    test "$(stat -c %s /tmp/usb_efi/bzImage)" = 12702720
    test "$(sha256sum /tmp/usb_efi/bzImage | awk '{print $1}')" = \
        11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
    test "$(stat -c %s /tmp/usb_efi/initrd.img)" = 54376639
    test "$(stat -c %s /tmp/usb_efi/cmdline.txt)" = 121
    test "$(sha256sum /tmp/usb_efi/cmdline.txt | awk '{print $1}')" = \
        6b3c09112fe049d3cbeada65fb3c82bb0f5fcaddce6c0709051df3d9f5a79f6d
    test "$(stat -c %s /tmp/usb_efi/vram.txt)" = 11
    test "$(sha256sum /tmp/usb_efi/vram.txt | awk '{print $1}')" = \
        bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0
    test "$(stat -c %s /tmp/usb_efi/kexec.sh)" = 136
    test "$(sha256sum /tmp/usb_efi/kexec.sh | awk '{print $1}')" = \
        0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52
    root_initrd=/tmp/usb_root/boot/initrd.img-7.1.7
    test -s "$root_initrd"
    root_initrd_size=$(stat -c %s "$root_initrd")
    test "$root_initrd_size" -le 54376639
    lsinitramfs "$root_initrd" >/dev/null
    cmp -n "$root_initrd_size" "$root_initrd" /tmp/usb_efi/initrd.img
    padding_size=$((54376639 - root_initrd_size))
    if [ "$padding_size" -gt 0 ]; then
        test "$(tail -c "$padding_size" /tmp/usb_efi/initrd.img \
            | tr -d '\000' | wc -c)" -eq 0
    fi
fi
sync

umount /tmp/usb_root /tmp/usb_efi
ROOT_MOUNTED=false
EFI_MOUNTED=false
rmdir  /tmp/usb_root /tmp/usb_efi
kpartx -dv "$LOOPDEV"
losetup -d "$LOOPDEV"
LOOPDEV=""

if [ "$DISTRO" = "ubuntu2404" ]; then
    echo "=== Running complete Ubuntu 24.04 release-image audit ==="
    if ! EXPECTED_PROFILE_ID="$UBUNTU2404_PROFILE_ID" \
        /repo/scripts/verify-ubuntu2404-boot.sh --inside-image "$TMPIMG"; then
        exit 1
    fi
fi

# Publish only an image that passed every release gate above.
mv "$TMPIMG" "$IMG"
sync

trap - EXIT HUP INT TERM

echo "========================================"
echo "Done! $IMG (${IMG_SIZE}MB)"
echo "Flash: sudo dd if=$IMG of=/dev/sdX bs=4M status=progress"
echo "========================================"
