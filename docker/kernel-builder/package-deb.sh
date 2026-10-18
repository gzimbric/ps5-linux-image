#!/bin/bash
# Builds a combined linux-ps5 .deb from staged artifacts in /out/staging.
# Runs inside the kernel-builder container; output goes to /out.
set -e

STAGING="/out/staging"
EXACT_RUN16_KERNEL="${EXACT_RUN16_KERNEL:-0}"
mapfile -t MODULE_DIRS < <(
    find "$STAGING/lib/modules" -mindepth 1 -maxdepth 1 -type d \
        -printf '%f\n' | LC_ALL=C sort
)
if [ "${#MODULE_DIRS[@]}" -ne 1 ]; then
    echo "ERROR: expected exactly one staged kernel module directory" >&2
    printf '  %s\n' "${MODULE_DIRS[@]}" >&2
    exit 1
fi
KVER=${MODULE_DIRS[0]}
if [ "$EXACT_RUN16_KERNEL" = 1 ] && [ "$KVER" != 7.1.7 ]; then
    echo "ERROR: exact Ubuntu 24.04 package requires kernel 7.1.7" >&2
    exit 1
fi
VER="${KVER%%-*}"
ARCH=amd64
PROVIDES="linux-image-$KVER"
CONFLICTS="linux-image-$KVER"
REPLACES="linux-image-$KVER"
DESCRIPTION="PS5 Linux kernel $KVER (image + modules)"

PKG=$(mktemp -d)
mkdir -p "$PKG/DEBIAN"
mkdir -p "$PKG/boot"
mkdir -p "$PKG/lib/modules"

cp "$STAGING/boot/bzImage"  "$PKG/boot/vmlinuz-$KVER"
cp "$STAGING/System.map"    "$PKG/boot/System.map-$KVER"
cp "$STAGING/.config"       "$PKG/boot/config-$KVER"
cp -a "$STAGING/lib/modules/$KVER" "$PKG/lib/modules/"

# Userspace bits the kernel-builder staged at /out/staging/{etc,usr/local}:
# ps5-stage-firmware service + script (bridges nxp blob from /boot/efi),
# ps5-iw620 modprobe.d options. Without these the WLAN driver loads but
# request_firmware() returns -2 and wlan_pcie probe fails.
for d in etc usr/local; do
    [ -d "$STAGING/$d" ] && { mkdir -p "$PKG/$d"; cp -a "$STAGING/$d/." "$PKG/$d/"; }
done

# Kernel headers (for out-of-tree module builds)
if [ -d "$STAGING/headers" ]; then
    # $PKG/usr may already exist from other staged files, so merge contents
    # instead of creating a nested usr/usr/include/ directory.
    mkdir -p "$PKG/usr"
    cp -a "$STAGING/headers/usr/." "$PKG/usr/"
    # Point /lib/modules/$KVER/build at the installed headers
    HDR_DEST="/usr/lib/modules/$KVER/build"
    mkdir -p "$PKG/usr/lib/modules/$KVER"
    cp -a "$STAGING/headers/lib/modules/$KVER/build" "$PKG/usr/lib/modules/$KVER/build"
    ln -sf "$HDR_DEST" "$PKG/lib/modules/$KVER/build"
    PROVIDES="$PROVIDES, linux-headers-$KVER, linux-libc-dev"
    CONFLICTS="$CONFLICTS, linux-headers-$KVER, linux-libc-dev"
    REPLACES="$REPLACES, linux-headers-$KVER, linux-libc-dev"
    DESCRIPTION="PS5 Linux kernel $KVER (image + modules + headers + libc-dev)"
fi

cat > "$PKG/DEBIAN/control" << CTRL
Package: linux-ps5
Version: $VER
Architecture: $ARCH
Maintainer: PS5 Linux
Provides: $PROVIDES
Conflicts: $CONFLICTS
Replaces: $REPLACES
Description: $DESCRIPTION
CTRL

{
cat << 'POSTINST_HEAD'
#!/bin/bash
set -e
POSTINST_HEAD
printf 'KVER=%q\n' "$KVER"
if [ "$EXACT_RUN16_KERNEL" = 1 ]; then
    printf 'PS5_INITRD_TARGET_SIZE=%q\n' 54376639
else
    printf 'PS5_INITRD_TARGET_SIZE=%q\n' ''
fi
cat << 'POSTINST_BODY'
echo ">> linux-ps5 postinst: kernel $KVER"

# Rebuild initramfs
if command -v update-initramfs >/dev/null 2>&1; then
    if [ -e "/boot/initrd.img-$KVER" ]; then
        echo ">> Updating initramfs with update-initramfs for $KVER"
        update-initramfs -u -k "$KVER"
    else
        echo ">> Creating initramfs with update-initramfs for $KVER"
        update-initramfs -c -k "$KVER"
    fi
elif command -v mkinitcpio >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with mkinitcpio for $KVER"
    mkinitcpio -k "$KVER" -g "/boot/initrd.img-$KVER"
elif command -v mkinitfs >/dev/null 2>&1; then
    echo ">> Rebuilding initramfs with mkinitfs for $KVER"
    mkinitfs -o "/boot/initrd.img-$KVER" "$KVER"
fi

# Copy kernel + initrd to EFI partition
if [ -d /boot/efi ]; then
    OLD_BZ=$(ls -l /boot/efi/bzImage 2>/dev/null | awk '{print $5}') || true
    OLD_INITRD=$(ls -l /boot/efi/initrd.img 2>/dev/null | awk '{print $5}') || true
    echo ">> Copying /boot/vmlinuz-$KVER -> /boot/efi/bzImage"
    install -m 0644 "/boot/vmlinuz-$KVER" /boot/efi/.bzImage.new
    NEW_BZ=$(stat -c %s /boot/efi/.bzImage.new)
    echo ">> Copying /boot/initrd.img-$KVER -> /boot/efi/initrd.img"
    initrd_source="/boot/initrd.img-$KVER"
    initrd_size=$(stat -c %s "$initrd_source")
    if [ -n "$PS5_INITRD_TARGET_SIZE" ] && \
       [ "$initrd_size" -gt "$PS5_INITRD_TARGET_SIZE" ]; then
        echo ">> initrd is larger than the PS5 loader envelope" >&2
        echo ">>   $initrd_size > $PS5_INITRD_TARGET_SIZE bytes" >&2
        exit 1
    fi
    install -m 0644 "$initrd_source" /boot/efi/.initrd.img.new
    if [ -n "$PS5_INITRD_TARGET_SIZE" ]; then
        truncate -s "$PS5_INITRD_TARGET_SIZE" /boot/efi/.initrd.img.new
        test "$(stat -c %s /boot/efi/.initrd.img.new)" = \
            "$PS5_INITRD_TARGET_SIZE"
        cmp -n "$initrd_size" "$initrd_source" \
            /boot/efi/.initrd.img.new
    fi
    NEW_INITRD=$(stat -c %s /boot/efi/.initrd.img.new)
    mv /boot/efi/.initrd.img.new /boot/efi/initrd.img
    mv /boot/efi/.bzImage.new /boot/efi/bzImage
    echo ">>   bzImage: ${OLD_BZ:-<new>} -> $NEW_BZ bytes"
    echo ">>   initrd.img: ${OLD_INITRD:-<new>} -> $NEW_INITRD bytes"
    echo ">> Kernel $KVER deployed to /boot/efi"
else
    echo ">> /boot/efi not found, skipping EFI deploy"
fi
POSTINST_BODY
} > "$PKG/DEBIAN/postinst"
chmod 755 "$PKG/DEBIAN/postinst"

dpkg-deb --build --root-owner-group "$PKG" "/out/linux-ps5_${VER}_${ARCH}.deb"
rm -rf "$PKG"
