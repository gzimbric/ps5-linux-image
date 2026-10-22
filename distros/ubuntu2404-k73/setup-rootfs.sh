#!/bin/bash
# Set up the Ubuntu 24.04 7.3 root filesystem for the PS5.
#
# distrobuilder runs this inside the new root as the post-files action of
# distros/ubuntu2404-k73/image.yaml, after the packages are installed and
# these are copied in:
#
#   /opt/ps5-bootstrap/       distros/ubuntu2404-k73/files
#   /opt/ps5-cmdline.txt      distros/ubuntu2404-k73/cmdline.txt
#   /opt/debs/                the linux-ps5 .deb (scripts/package-linux-ps5-k73-deb.sh)
#   /opt/ps5-iw620/           mlan.ko, moal.ko and SHA256SUMS from the kernel bundle
#
# It sets up the ps5 account, installs the kernel through its package so the
# image's own boot-file hook writes /boot/efi, adds the PS5 services and
# settings, checks the result and removes everything that must not ship
# (SSH host keys, the machine ID, apt lists, the files above).
# docker/image-builder/entrypoint.sh then moves /boot/efi to the FAT
# partition and adds cmdline.txt, vram.txt and kexec.sh.
set -euxo pipefail
export LC_ALL=C
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

KVER=7.3.0
DEB_VERSION=7.3.0-5
B=/opt/ps5-bootstrap
IW620_ALIAS='pci:v00001B4Bd00002B56sv*sd*bc*sc*i*'

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

put() { # mode file-in-/opt/ps5-bootstrap destination
    install -D -o root -g root -m "$1" "$B/$2" "$3"
}

sha() {
    sha256sum "$1" | awk '{print $1}'
}

# ------------------------------------------------------------------ account

passwd -l root
fc-cache -f

for group in input render; do
    getent group "$group" >/dev/null || groupadd --system "$group"
done
if getent passwd 1000 >/dev/null; then
    fail "UID 1000 is already taken"
fi
useradd --uid 1000 --create-home --user-group \
    --groups sudo,video,input,render --shell /bin/bash ps5
# Documented first-login password, so a headless console can be reached
# without shipping a key. The README tells users to change it.
printf 'ps5:ubuntu\n' | chpasswd

install -d -m 0750 /etc/sudoers.d
printf 'ps5 ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/90-ps5-control
chmod 0440 /etc/sudoers.d/90-ps5-control
visudo -cf /etc/sudoers.d/90-ps5-control

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-ps5-control.conf <<'EOF'
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AllowUsers ps5
EOF

install -d -m 0755 /etc/gdm3
cat > /etc/gdm3/custom.conf <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=ps5
EOF
install -d -m 0755 /etc/systemd/system/gdm.service.d
cat > /etc/systemd/system/gdm.service.d/10-ps5-bringup.conf <<'EOF'
[Unit]
Wants=NetworkManager.service ssh.service
After=NetworkManager.service ssh.service ps5fan.service ps5-amdgpu-reprobe.service ps5-performance.service
EOF

install -d -m 0755 /home/ps5/.config
printf 'yes\n' > /home/ps5/.config/gnome-initial-setup-done
install -d -m 0755 /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/ps5 <<'EOF'
[User]
Language=en_US.UTF-8
XSession=ubuntu
SystemAccount=false
EOF
chown -R ps5:ps5 /home/ps5

install -d -m 0755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-persistent.conf <<'EOF'
[Journal]
Storage=persistent
EOF
install -d -m 2755 -o root -g systemd-journal /var/log/journal
printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' \
    > /etc/systemd/zram-generator.conf

# distrobuilder's hostname generator wrote the build container's ID here on
# the 7.1.7 image.
printf 'ps5\n' > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 ps5

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# ------------------------------------------------------------- PS5 files

put 0755 ps5-check-boot-files /usr/local/sbin/ps5-check-boot-files
put 0755 ps5-update-boot-files /usr/local/sbin/ps5-update-boot-files
put 0755 zz-ps5-boot-files /etc/initramfs/post-update.d/zz-ps5-boot-files
put 0644 initramfs-modules /etc/initramfs-tools/modules
put 0644 initramfs-ps5.conf /etc/initramfs-tools/conf.d/ps5-control
put 0755 initramfs-hook-ps5-firmware /etc/initramfs-tools/hooks/ps5-firmware
put 0644 ps5-amdgpu.conf /etc/modprobe.d/ps5-amdgpu.conf
put 0644 ps5-iw620.conf /etc/modprobe.d/ps5-iw620.conf
put 0644 ps5-mt7921e.conf /etc/modprobe.d/ps5-mt7921e.conf
put 0644 btusb-ps5.conf /etc/modprobe.d/btusb-ps5.conf
put 0644 99-ps5-bt-phantom.rules /etc/udev/rules.d/99-ps5-bt-phantom.rules
put 0644 ps5-ethernet.conf /etc/modules-load.d/ps5-ethernet.conf
put 0644 zz-ps5-iw620.conf /etc/NetworkManager/conf.d/zz-ps5-iw620.conf
put 0755 ps5-iw620-firmware /usr/local/sbin/ps5-iw620-firmware
put 0644 ps5-iw620-firmware.service /etc/systemd/system/ps5-iw620-firmware.service
put 0755 ps5-bt-quiet /usr/local/sbin/ps5-bt-quiet
put 0644 ps5-bt-quiet.service /etc/systemd/system/ps5-bt-quiet.service
put 0644 ps5-fan.conf /etc/default/ps5-fan
put 0755 ps5-fan-target /usr/local/sbin/ps5-fan-target
put 0644 ps5fan.service /etc/systemd/system/ps5fan.service
put 0755 ps5-performance /usr/local/sbin/ps5-performance
put 0644 ps5-performance.service /etc/systemd/system/ps5-performance.service
put 0755 ps5-amdgpu-reprobe /usr/local/sbin/ps5-amdgpu-reprobe
put 0644 ps5-amdgpu-reprobe.service /etc/systemd/system/ps5-amdgpu-reprobe.service
put 0755 ps5-boot-report /usr/local/sbin/ps5-boot-report
put 0644 ps5-boot-report.service /etc/systemd/system/ps5-boot-report.service
put 0644 ps5-boot-report.timer /etc/systemd/system/ps5-boot-report.timer
put 0644 ps5-ssh-host-keys.service /etc/systemd/system/ps5-ssh-host-keys.service
put 0644 ps5-ssh-keys.conf /etc/systemd/system/ssh.service.d/10-ps5-host-keys.conf
put 0644 ps5-ssh-keys.conf /etc/systemd/system/ssh.socket.d/10-ps5-host-keys.conf
# The 7.1.7 images' boot-file copier; this image uses zz-ps5-boot-files.
rm -f /etc/kernel/postinst.d/zz-update-boot

# The eight Cyan Skillfish 2 GPU firmware files the display needs in the
# initramfs, pinned to the payloads both earlier images booted with (Ubuntu
# 24.04 on 7.1.7 and CachyOS Image 4 on 7.3.0). A package drift is fixed from
# linux-firmware at the pinned commit; anything else stops the build.
firmware_dir=/usr/lib/firmware/amdgpu
firmware_ref=3b128b6069267b60a46a4074c383183177ee6e6d
test -d "$firmware_dir"
while read -r name expected; do
    raw="$firmware_dir/cyan_skillfish2_${name}.bin"
    compressed="${raw}.zst"
    candidate=$(mktemp)
    if [ -e "$raw" ]; then
        cp -L "$raw" "$candidate"
    elif [ -e "$compressed" ]; then
        # linux-firmware uses relative symlinks for identical blobs (mec2 ->
        # mec); zstd ignores symlink inputs unless forced.
        zstd -q -f -d -c "$compressed" > "$candidate"
    fi
    if [ "$(sha "$candidate")" != "$expected" ]; then
        curl -fsSL \
            "https://gitlab.com/kernel-firmware/linux-firmware/-/raw/$firmware_ref/amdgpu/$(basename "$raw")" \
            -o "$candidate"
    fi
    test "$(sha "$candidate")" = "$expected"
    rm -f "$raw"
    install -m 0644 "$candidate" "$raw"
    rm -f "$candidate"
done <<'EOF'
ce 5946efbf7e46ccfe7e9f965da56c35b1187469d1c1a49c8a9eff433eb3ab4723
me d4ed4d968de0d7720f7c8215d42fdae727bf99cdf43cee6f8f864dc2584b17e2
mec b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4
mec2 b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4
pfp 50e56dc1913571ff589425d2b059bddfc5e8a2b4bc22d3eb78cac75d1e0479a1
rlc 20acefdb6128a36275f4382425a109a7c9927f6053eab685bb51164ff1d18cfb
sdma 15d0d3626da7f2513f03b13bb7e02eeeeccab276276ae27d0b6067b5f25e9e95
sdma1 bd1c0b0f6a6a4f17ede034f2c844b6553fc444e08915c7bb500c09fde59d6255
EOF

# ------------------------------------------------------------------ kernel

if find /usr/lib/modules -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
    find /usr/lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' >&2
    fail "a kernel was installed before linux-ps5"
fi
shopt -s nullglob
debs=(/opt/debs/*.deb)
shopt -u nullglob
[ "${#debs[@]}" -eq 1 ] || fail "expected one .deb in /opt/debs, found ${#debs[@]}"
deb=${debs[0]}
[ "$(dpkg-deb -f "$deb" Package)" = linux-ps5 ] || fail "$deb is not linux-ps5"
[ "$(dpkg-deb -f "$deb" Version)" = "$DEB_VERSION" ] || fail "$deb is not version $DEB_VERSION"

# Install it the way an update would: with /boot/efi mounted and
# cmdline.txt on it, so the package's preinst check passes and
# update-initramfs runs zz-ps5-boot-files, which checks the files and
# writes bzImage and initrd.img. Here /boot/efi is bound onto itself.
mkdir -p /boot/efi
if find /boot/efi -mindepth 1 -print -quit | grep -q .; then
    fail "/boot/efi is not empty"
fi
install -m 0644 /opt/ps5-cmdline.txt /boot/efi/cmdline.txt
mount --bind /boot/efi /boot/efi
trap 'umount /boot/efi 2>/dev/null || true' EXIT
dpkg -i "$deb"
# shellcheck disable=SC2016 # dpkg-query expands these
[ "$(dpkg-query -W -f='${Status} ${Version}' linux-ps5)" = "install ok installed $DEB_VERSION" ] ||
    fail "linux-ps5 $DEB_VERSION is not installed"
apt-mark hold linux-ps5
apt-mark showhold | grep -qxF linux-ps5
cmp /boot/vmlinuz-$KVER /boot/efi/bzImage
cmp /boot/initrd.img-$KVER /boot/efi/initrd.img
listing=$(cd /boot/efi && find . -mindepth 1 -printf '%P\n' | sort | tr '\n' ' ')
[ "$listing" = "bzImage cmdline.txt initrd.img " ] ||
    fail "unexpected files in /boot/efi after the kernel install: $listing"
# The entrypoint writes the final cmdline.txt, from the same file.
rm -f /boot/efi/cmdline.txt
umount /boot/efi
trap - EXIT
mountpoint -q /boot/efi && fail "/boot/efi is still mounted"
modules=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n')
[ "$modules" = "$KVER" ] || fail "kernel module trees: $modules"

# IW620 Wi-Fi modules, built against this kernel and installed by the
# linux-ps5 package, so a newer package replaces them with the kernel. They
# have to be the bundle's modules. udev's alias load is blocked by
# ps5-iw620.conf; ps5-iw620-firmware.service loads moal once the loader's
# firmware dump is in place.
(cd /opt/ps5-iw620 && sha256sum -c SHA256SUMS)
updates=/usr/lib/modules/$KVER/updates/ps5-iw620
for m in mlan moal; do
    cmp /opt/ps5-iw620/$m.ko "$updates/$m.ko"
    dpkg -S "$updates/$m.ko" | grep -qx "linux-ps5: $updates/$m.ko" ||
        fail "$updates/$m.ko is not from the linux-ps5 package"
done
depmod -a "$KVER"
module_file() {
    readlink -f "$(modinfo -k "$KVER" -F filename "$1")"
}
cfg80211_vermagic=$(modinfo -k "$KVER" -F vermagic cfg80211)
case $cfg80211_vermagic in
    "$KVER "*) ;;
    *) fail "cfg80211 vermagic is not for $KVER: $cfg80211_vermagic" ;;
esac
for module in mlan moal; do
    [ "$(module_file "$module")" = "$updates/$module.ko" ] ||
        fail "modprobe would not load $updates/$module.ko"
    [ "$(modinfo -k "$KVER" -F vermagic "$module")" = "$cfg80211_vermagic" ] ||
        fail "$module.ko was not built for this kernel"
done
grep -qxF "alias $IW620_ALIAS moal" "/usr/lib/modules/$KVER/modules.alias"
[ "$(module_file mt7921e)" = \
    "/usr/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt76/mt7921/mt7921e.ko" ] ||
    fail "modprobe would not load the in-tree mt7921e"
[ "$(modinfo -k "$KVER" -F vermagic mt7921e)" = "$cfg80211_vermagic" ]
modinfo -k "$KVER" -F parm btusb |
    grep -qxF 'ps5_tx_ep:PS5 MediaTek BT: bulk OUT endpoint for ACL (0 = default) (int)' ||
    fail "btusb does not have the MediaTek bulk OUT fix"
# The PS5's MT7921 Wi-Fi (PCI 14c3:7961) and its Bluetooth (USB 0e8d:3603)
# firmware, from Ubuntu's linux-firmware.
for firmware in mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin \
    mediatek/WIFI_RAM_CODE_MT7961_1.bin \
    mediatek/BT_RAM_CODE_MT7961_1_2_hdr.bin; do
    [ -e "/usr/lib/firmware/$firmware" ] || [ -e "/usr/lib/firmware/$firmware.zst" ] ||
        fail "MediaTek firmware is missing: /usr/lib/firmware/$firmware"
done

# ---------------------------------------------------------------- network

# Ubuntu's network-manager sets wifi.powersave = 3 in
# default-wifi-powersave-on.conf; zz-ps5-iw620.conf sorts after it.
nm_config=$(NetworkManager --print-config)
nm_get() { # section key
    awk -v s="[$1]" -v k="$2" '
        $0 == s { in_s = 1; next }
        /^\[/ { in_s = 0 }
        in_s && (p = index($0, "=")) > 0 {
            key = substr($0, 1, p - 1)
            sub(/[[:space:]]+$/, "", key)
            if (key == k) {
                v = substr($0, p + 1)
                sub(/^[[:space:]]+/, "", v)
            }
        }
        END { print v }
    ' <<<"$nm_config"
}
[ "$(nm_get connection wifi.powersave)" = 2 ] || fail "NetworkManager wifi.powersave is not 2"
[ "$(nm_get connection wifi.cloned-mac-address)" = permanent ] ||
    fail "NetworkManager wifi.cloned-mac-address is not permanent"
[ "$(nm_get device wifi.scan-rand-mac-address)" = no ] ||
    fail "NetworkManager wifi.scan-rand-mac-address is not no"
[ "$(nm_get main dns)" = systemd-resolved ] || fail "NetworkManager dns is not systemd-resolved"

# --------------------------------------------------------------- Bluetooth

# The BlueZ settings Image 4 and the Bazzite Deck image use: pairable, Just
# Works repairing for the DualSense, and the userspace HID path (uhid).
set_ini() { # file section key value
    local file=$1 section=$2 key=$3 value=$4
    [ -f "$file" ] || fail "$file is missing"
    if ! grep -qxF "[$section]" "$file"; then
        printf '\n[%s]\n' "$section" >> "$file"
    fi
    [ "$(grep -cxF "[$section]" "$file")" = 1 ] || fail "$file has more than one [$section]"
    awk -v s="[$section]" -v k="$key" -v v="$value" '
        $0 == s { print; print k "=" v; in_s = 1; next }
        /^\[/ { in_s = 0 }
        in_s && $0 ~ ("^[[:space:]]*" k "[[:space:]]*=") { next }
        { print }
    ' "$file" > "$file.new"
    cat "$file.new" > "$file"
    rm -f "$file.new"
    [ "$(grep -cE "^[[:space:]]*${key}[[:space:]]*=" "$file")" = 1 ] ||
        fail "$key is set more than once in $file"
    grep -qxF "$key=$value" "$file"
}
set_ini /etc/bluetooth/main.conf General AlwaysPairable true
set_ini /etc/bluetooth/main.conf General PairableTimeout 0
set_ini /etc/bluetooth/main.conf General ControllerMode dual
set_ini /etc/bluetooth/main.conf General Privacy device
set_ini /etc/bluetooth/main.conf General JustWorksRepairing always
set_ini /etc/bluetooth/main.conf Policy AutoEnable true
set_ini /etc/bluetooth/input.conf General UserspaceHID true
for module in btusb btmtk bluetooth uhid hid_playstation; do
    modinfo -k "$KVER" -F filename "$module" >/dev/null || fail "$module is not installed"
done

# ---------------------------------------------------------------- services

systemctl enable NetworkManager.service ssh.service bluetooth.service \
    grow-rootfs.service systemd-resolved.service ps5-ssh-host-keys.service \
    ps5fan.service ps5-amdgpu-reprobe.service ps5-performance.service \
    ps5-iw620-firmware.service ps5-bt-quiet.service ps5-boot-report.timer
test -f /usr/lib/systemd/system/gdm.service
ln -sfn /usr/lib/systemd/system/gdm.service /etc/systemd/system/display-manager.service
systemctl set-default graphical.target
# NetworkManager owns every link. networkd's wait-online unit timed out
# after two minutes on Image 3; keep it from being enabled.
systemctl disable systemd-networkd-wait-online.service 2>/dev/null || true
systemctl mask systemd-networkd-wait-online.service
# Linux sleep does not work on the PS5.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
    suspend-then-hibernate.target
systemd-analyze verify \
    /etc/systemd/system/ps5fan.service \
    /etc/systemd/system/ps5-amdgpu-reprobe.service \
    /etc/systemd/system/ps5-performance.service \
    /etc/systemd/system/ps5-iw620-firmware.service \
    /etc/systemd/system/ps5-bt-quiet.service \
    /etc/systemd/system/ps5-ssh-host-keys.service \
    /etc/systemd/system/ps5-boot-report.service \
    /etc/systemd/system/ps5-boot-report.timer
for unit in NetworkManager.service ssh.service bluetooth.service grow-rootfs.service \
    systemd-resolved.service ps5-ssh-host-keys.service ps5fan.service \
    ps5-amdgpu-reprobe.service ps5-performance.service ps5-iw620-firmware.service \
    ps5-bt-quiet.service ps5-boot-report.timer; do
    [ "$(systemctl is-enabled "$unit")" = enabled ] || fail "$unit is not enabled"
done
for unit in systemd-networkd-wait-online.service sleep.target suspend.target \
    hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
    [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = masked ] || fail "$unit is not masked"
done
[ "$(readlink -f /etc/systemd/system/display-manager.service)" = /usr/lib/systemd/system/gdm.service ]

# ---------------------------------------------------------------- initramfs

initrd=/boot/initrd.img-$KVER
grep -qx 'CONFIG_RD_ZSTD=y' "/boot/config-$KVER" || fail "the kernel cannot unpack a zstd initramfs"
contents=$(lsinitramfs "$initrd")
grep -Eq "(^|/)lib/modules/$KVER/kernel/drivers/gpu/drm/amd/amdgpu/amdgpu\\.ko(\\.zst)?\$" <<<"$contents" ||
    fail "the initramfs has no amdgpu.ko for $KVER"
if grep -E '(^|/)((mlan|moal|mt7921e|btusb|ps5-cpufreq|ps5-gpufreq)\.ko(\.zst)?|pcieuartiw620[^/]*)$' <<<"$contents"; then
    fail "the initramfs has a Wi-Fi driver, its firmware, btusb or a frequency driver"
fi
audit=$(mktemp -d)
unmkinitramfs "$initrd" "$audit"
mapfile -t policy < <(find "$audit" -type f -path '*/etc/modprobe.d/ps5-amdgpu.conf' -print)
[ "${#policy[@]}" -eq 1 ] || fail "the initramfs has ${#policy[@]} copies of ps5-amdgpu.conf"
cmp "${policy[0]}" /etc/modprobe.d/ps5-amdgpu.conf
# udev in the initramfs turns off the phantom MediaTek interfaces before
# btusb can load.
mapfile -t bt_rule < <(find "$audit" -type f -path '*/lib/udev/rules.d/99-ps5-bt-phantom.rules' -print)
[ "${#bt_rule[@]}" -eq 1 ] || fail "the initramfs has ${#bt_rule[@]} copies of 99-ps5-bt-phantom.rules"
cmp "${bt_rule[0]}" /etc/udev/rules.d/99-ps5-bt-phantom.rules
while read -r name expected; do
    mapfile -t matches < <(find "$audit" -type f -path "*/usr/lib/firmware/amdgpu/cyan_skillfish2_$name.bin" -print)
    [ "${#matches[@]}" -eq 1 ] || fail "the initramfs has ${#matches[@]} copies of cyan_skillfish2_$name.bin"
    [ "$(sha "${matches[0]}")" = "$expected" ] || fail "cyan_skillfish2_$name.bin in the initramfs is not the pinned file"
done <<'EOF'
ce 5946efbf7e46ccfe7e9f965da56c35b1187469d1c1a49c8a9eff433eb3ab4723
me d4ed4d968de0d7720f7c8215d42fdae727bf99cdf43cee6f8f864dc2584b17e2
mec b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4
mec2 b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4
pfp 50e56dc1913571ff589425d2b059bddfc5e8a2b4bc22d3eb78cac75d1e0479a1
rlc 20acefdb6128a36275f4382425a109a7c9927f6053eab685bb51164ff1d18cfb
sdma 15d0d3626da7f2513f03b13bb7e02eeeeccab276276ae27d0b6067b5f25e9e95
sdma1 bd1c0b0f6a6a4f17ede034f2c844b6553fc444e08915c7bb500c09fde59d6255
EOF
rm -rf "$audit"
/usr/local/sbin/ps5-check-boot-files "/boot/vmlinuz-$KVER" "$initrd" /opt/ps5-cmdline.txt

# --------------------------------------------------------------------- SSH

install -d -m 0755 /run/sshd
sshd -t
sshd -T > /tmp/ps5-sshd.effective
for setting in 'permitrootlogin no' 'pubkeyauthentication yes' \
    'passwordauthentication yes' 'permitemptypasswords no' \
    'kbdinteractiveauthentication no' 'allowusers ps5'; do
    grep -qxF "$setting" /tmp/ps5-sshd.effective || fail "sshd: $setting is not in effect"
done
rm -f /tmp/ps5-sshd.effective
shadow_hash=$(getent shadow ps5 | cut -d: -f2)
case $shadow_hash in
    ''|'!'*|'*'*) fail "the ps5 account is locked" ;;
esac

# ---------------------------------------------------------------- cleanup

rm -rf /opt/ps5-bootstrap /opt/ps5-cmdline.txt /opt/ps5-iw620 /opt/debs
# Package installation made host keys so sshd could be checked above.
# ps5-ssh-host-keys.service makes a unique set on first boot.
rm -f /etc/ssh/ssh_host_*
if find /etc/ssh -maxdepth 1 -name 'ssh_host_*' -print -quit | grep -q .; then
    fail "SSH host keys are still in /etc/ssh"
fi
if find /root /home /etc/skel \( -type f -o -type l \) \
    \( -name authorized_keys -o -name authorized_keys2 \) -print -quit | grep -q .; then
    fail "the image has an authorized_keys file"
fi
# systemd makes a unique machine ID on first boot.
rm -f /etc/machine-id
install -o root -g root -m 0444 /dev/null /etc/machine-id
mkdir -p /var/lib/dbus
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
# Stale the day the image is built; apt update fetches them again.
rm -rf /var/lib/apt/lists
install -d -m 0755 /var/lib/apt/lists /var/lib/apt/lists/partial
rm -f /var/cache/apt/*.bin
find /usr/lib/firmware /boot -name 'pcieuartiw620*' -print -quit | grep -q . &&
    fail "IW620 firmware is in the image"
echo "Ubuntu 24.04 7.3 root filesystem: OK"
