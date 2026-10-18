#!/bin/sh
# SPDX-License-Identifier: 0BSD
set -eu

export LC_ALL=C

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
SELF=$SCRIPT_DIR/$(basename -- "$0")
IMAGE_VERIFIER_IMAGE=${IMAGE_VERIFIER_IMAGE:-ps5-image-builder}

loop_device=
image_mount_root=
kheaders_tmp=
initrd_tmp=

usage() {
    cat >&2 <<EOF
Usage:
  $0 --image <ps5-ubuntu2404.img> [--loader <loader.elf>]
  $0 [--loader <loader.elf>] <mounted-boot-directory> [mounted-root-directory]

The --image form performs the complete read-only release check in the
ps5-image-builder container. The directory form checks already mounted
filesystems; pass both partitions for the rootfs checks.
EOF
    exit 2
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    set +e
    mounts_active=false
    if [ -n "$image_mount_root" ]; then
        mountpoint -q "$image_mount_root/boot" && umount "$image_mount_root/boot"
        mountpoint -q "$image_mount_root/root" && umount "$image_mount_root/root"
        if mountpoint -q "$image_mount_root/boot" || \
            mountpoint -q "$image_mount_root/root"; then
            mounts_active=true
            echo "WARNING: leaving image mappings attached because a read-only mount is still active" >&2
        fi
    fi
    if [ -n "$loop_device" ] && [ "$mounts_active" = false ]; then
        kpartx -d "$loop_device" >/dev/null 2>&1
        losetup -d "$loop_device" >/dev/null 2>&1
    fi
    if [ -n "$image_mount_root" ] && [ "$mounts_active" = false ]; then
        rm -rf "$image_mount_root"
    fi
    [ -z "$kheaders_tmp" ] || rm -rf "$kheaders_tmp"
    [ -z "$initrd_tmp" ] || rm -rf "$initrd_tmp"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is missing: $1"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail "sha256sum or shasum is required"
    fi
}

file_size() {
    wc -c < "$1" | tr -d '[:space:]'
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

assert_line() {
    path=$1
    expected=$2
    label=$3
    [ -f "$path" ] || fail "missing $label: $path"
    grep -qxF "$expected" "$path" || fail "$label is missing: $expected"
}

canonical_file() {
    file_dir=$(CDPATH='' cd -- "$(dirname -- "$1")" && pwd)
    printf '%s/%s\n' "$file_dir" "$(basename -- "$1")"
}

image_path=
inside_image=
loader_path=

while [ "$#" -gt 0 ]; do
    case $1 in
        --image)
            [ "$#" -ge 2 ] || usage
            image_path=$2
            shift 2
            ;;
        --inside-image)
            [ "$#" -ge 2 ] || usage
            inside_image=$2
            shift 2
            ;;
        --loader)
            [ "$#" -ge 2 ] || usage
            loader_path=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -*)
            usage
            ;;
        *)
            break
            ;;
    esac
done

[ -z "$image_path" ] || [ -z "$inside_image" ] || usage

if [ -n "$image_path" ]; then
    [ "$#" -eq 0 ] || usage
    [ -f "$image_path" ] || fail "not a regular file: $image_path"
    image_path=$(canonical_file "$image_path")

    require_command docker
    docker image inspect "$IMAGE_VERIFIER_IMAGE" >/dev/null 2>&1 || {
        echo "Missing Docker image: $IMAGE_VERIFIER_IMAGE" >&2
        echo "Run build_image.sh once to build the image-builder image." >&2
        exit 1
    }

    profile_script=$SCRIPT_DIR/ubuntu2404-profile-id.sh
    [ -x "$profile_script" ] || fail "missing profile verifier: $profile_script"
    expected_profile_id=$($profile_script)

    if [ -n "$loader_path" ]; then
        [ -f "$loader_path" ] || fail "not a regular file: $loader_path"
        loader_path=$(canonical_file "$loader_path")
        exec docker run --rm --network none --privileged \
            --entrypoint /verify \
            -e "EXPECTED_PROFILE_ID=$expected_profile_id" \
            -v "$SELF:/verify:ro" \
            -v "$image_path:/input.img:ro" \
            -v "$loader_path:/loader.elf:ro" \
            "$IMAGE_VERIFIER_IMAGE" \
            --inside-image /input.img --loader /loader.elf
    fi

    exec docker run --rm --network none --privileged \
        --entrypoint /verify \
        -e "EXPECTED_PROFILE_ID=$expected_profile_id" \
        -v "$SELF:/verify:ro" \
        -v "$image_path:/input.img:ro" \
        "$IMAGE_VERIFIER_IMAGE" \
        --inside-image /input.img
fi

layout_disk=
root_partition=
boot_partition=

if [ -n "$inside_image" ]; then
    [ "$#" -eq 0 ] || usage
    [ "$(id -u)" -eq 0 ] || fail "--inside-image requires root"
    [ -f "$inside_image" ] || fail "not a regular file: $inside_image"

    for command in blkid kpartx losetup mknod mount mountpoint parted stat umount; do
        require_command "$command"
    done

    assert_equal "disk image size" "$(stat -c %s "$inside_image")" 16777216000

    free_loop=$(losetup -f)
    if [ ! -e "$free_loop" ]; then
        loop_number=${free_loop#/dev/loop}
        case $loop_number in
            ''|*[!0-9]*) fail "invalid free loop device: $free_loop" ;;
        esac
        mknod "$free_loop" b 7 "$loop_number"
    fi
    loop_device=$(losetup --find --show --read-only "$inside_image")
    kpartx -ars "$loop_device"

    loop_base=${loop_device##*/}
    root_partition=/dev/mapper/${loop_base}p1
    boot_partition=/dev/mapper/${loop_base}p2
    attempts=0
    while { [ ! -b "$root_partition" ] || [ ! -b "$boot_partition" ]; } && \
        [ "$attempts" -lt 20 ]; do
        sleep 1
        attempts=$((attempts + 1))
    done
    [ -b "$root_partition" ] || fail "missing root partition mapping: $root_partition"
    [ -b "$boot_partition" ] || fail "missing boot partition mapping: $boot_partition"

    image_mount_root=$(mktemp -d)
    mkdir "$image_mount_root/root" "$image_mount_root/boot"
    mount -o ro,noload "$root_partition" "$image_mount_root/root"
    mount -o ro "$boot_partition" "$image_mount_root/boot"

    layout_disk=$loop_device
    boot_dir=$image_mount_root/boot
    root_dir=$image_mount_root/root
else
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
    boot_dir=${1%/}
    root_dir=${2:-}
    root_dir=${root_dir%/}

    [ -d "$boot_dir" ] || fail "not a directory: $boot_dir"
    boot_dir=$(CDPATH='' cd -- "$boot_dir" && pwd -P)
    if [ -n "$root_dir" ]; then
        [ -d "$root_dir" ] || fail "not a directory: $root_dir"
        root_dir=$(CDPATH='' cd -- "$root_dir" && pwd -P)
    fi
fi

if [ -n "$loader_path" ]; then
    [ -f "$loader_path" ] || fail "not a regular file: $loader_path"
    assert_equal "loader ELF size" "$(file_size "$loader_path")" 169872
    assert_file_sha256 "$loader_path" \
        422b87ec39ca0edfce8dddd609c2eff1cc7adcb2732b7909b76fafbd60dd2336 \
        "firmware 11.60 loader ELF"
    echo "loader ELF: OK"
else
    echo "loader ELF: not checked (it is delivered separately and is not in the disk image)"
fi

verify_partition_layout() {
    disk=$1
    root_part=$2
    boot_part=$3

    partition_table=$(parted -sm "$disk" unit s print)
    disk_record=$(printf '%s\n' "$partition_table" | awk -F: 'NR == 2 {print}')
    part1_record=$(printf '%s\n' "$partition_table" | awk -F: '$1 == "1" {print}')
    part2_record=$(printf '%s\n' "$partition_table" | awk -F: '$1 == "2" {print}')
    partition_count=$(printf '%s\n' "$partition_table" |
        awk -F: '$1 ~ /^[0-9]+$/ {count++} END {print count + 0}')

    [ -n "$disk_record" ] || fail "parted did not report the disk"
    [ -n "$part1_record" ] || fail "GPT partition 1 is missing"
    [ -n "$part2_record" ] || fail "GPT partition 2 is missing"
    assert_equal "partition count" "$partition_count" 2

    disk_sectors=$(printf '%s\n' "$disk_record" | awk -F: '{sub(/s$/, "", $2); print $2}')
    logical_sector=$(printf '%s\n' "$disk_record" | awk -F: '{print $4}')
    physical_sector=$(printf '%s\n' "$disk_record" | awk -F: '{print $5}')
    table_type=$(printf '%s\n' "$disk_record" | awk -F: '{print $6}')
    assert_equal "disk sector count" "$disk_sectors" 32768000
    assert_equal "logical sector size" "$logical_sector" 512
    assert_equal "physical sector size" "$physical_sector" 512
    assert_equal "partition table" "$table_type" gpt

    part1_start=$(printf '%s\n' "$part1_record" | awk -F: '{sub(/s$/, "", $2); print $2}')
    part1_end=$(printf '%s\n' "$part1_record" | awk -F: '{sub(/s$/, "", $3); print $3}')
    part1_size=$(printf '%s\n' "$part1_record" | awk -F: '{sub(/s$/, "", $4); print $4}')
    part1_fs=$(printf '%s\n' "$part1_record" | awk -F: '{print $5}')
    part1_flags=$(printf '%s\n' "$part1_record" | awk -F: '{gsub(/[ ;]/, "", $7); print $7}')
    assert_equal "root partition start sector" "$part1_start" 1024000
    assert_equal "root partition end sector" "$part1_end" 32765951
    assert_equal "root partition sector count" "$part1_size" 31741952
    assert_equal "root partition table filesystem" "$part1_fs" ext4
    assert_equal "root partition flags" "$part1_flags" ""

    part2_start=$(printf '%s\n' "$part2_record" | awk -F: '{sub(/s$/, "", $2); print $2}')
    part2_end=$(printf '%s\n' "$part2_record" | awk -F: '{sub(/s$/, "", $3); print $3}')
    part2_size=$(printf '%s\n' "$part2_record" | awk -F: '{sub(/s$/, "", $4); print $4}')
    part2_fs=$(printf '%s\n' "$part2_record" | awk -F: '{print $5}')
    part2_flags=$(printf '%s\n' "$part2_record" | awk -F: '{gsub(/[ ;]/, "", $7); print $7}')
    assert_equal "boot partition start sector" "$part2_start" 2048
    assert_equal "boot partition end sector" "$part2_end" 1023999
    assert_equal "boot partition sector count" "$part2_size" 1021952
    assert_equal "boot partition table filesystem" "$part2_fs" fat32
    case $part2_flags in
        boot,esp|esp,boot) ;;
        *) fail "boot partition flags are $part2_flags; expected boot,esp" ;;
    esac

    assert_equal "root filesystem type" \
        "$(blkid -s TYPE -o value "$root_part")" ext4
    assert_equal "root filesystem label" \
        "$(blkid -s LABEL -o value "$root_part")" ubuntu2404
    assert_equal "boot filesystem type" \
        "$(blkid -s TYPE -o value "$boot_part")" vfat
    assert_equal "boot filesystem label" \
        "$(blkid -s LABEL -o value "$boot_part")" boot

    echo "GPT layout and filesystem labels: OK"
}

if [ -n "$layout_disk" ]; then
    verify_partition_layout "$layout_disk" "$root_partition" "$boot_partition"
fi

check_exact_boot_file() {
    name=$1
    expected_size=$2
    expected_hash=$3
    path=$boot_dir/$name
    [ -f "$path" ] || fail "missing $path"
    assert_equal "$name size" "$(file_size "$path")" "$expected_size"
    assert_equal "$name SHA-256" "$(sha256_file "$path")" "$expected_hash"
    echo "$name: OK ($expected_size bytes)"
}

check_exact_boot_file bzImage 12702720 \
    11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde
check_exact_boot_file cmdline.txt 121 \
    6b3c09112fe049d3cbeada65fb3c82bb0f5fcaddce6c0709051df3d9f5a79f6d
check_exact_boot_file vram.txt 11 \
    bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0
check_exact_boot_file kexec.sh 136 \
    0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52

efi_initrd=$boot_dir/initrd.img
[ -f "$efi_initrd" ] || fail "missing $efi_initrd"
efi_size=$(file_size "$efi_initrd")
assert_equal "initrd.img size" "$efi_size" 54376639
efi_hash=$(sha256_file "$efi_initrd")
if [ "$efi_hash" = \
    2eef0352879e091083450b799c75514a450f4110cbc747f640962fdde2dc06c8 ]; then
    echo "initrd.img: exact tested artifact ($efi_size bytes, $efi_hash)"
else
    echo "initrd.img: loader-sized rebuild ($efi_size bytes, $efi_hash)"
fi

boot_files=$(cd "$boot_dir" && find . -type f -print | sort)
expected_boot_files='./bzImage
./cmdline.txt
./initrd.img
./kexec.sh
./vram.txt'
assert_equal "boot partition regular-file set" "$boot_files" "$expected_boot_files"

verify_kheaders() {
    kheaders=$1
    [ -f "$kheaders" ] || fail "missing kheaders.ko: $kheaders"

    symbol_value() {
        symbol=$1
        values=$(nm -n -- "$kheaders" |
            awk -v wanted="$symbol" '$3 == wanted {print $1}')
        value_count=$(printf '%s\n' "$values" |
            awk 'NF {count++} END {print count + 0}')
        [ "$value_count" -eq 1 ] ||
            fail "expected one $symbol symbol in kheaders.ko"
        case $values in
            ''|*[!0-9A-Fa-f]*) fail "invalid $symbol value: $values" ;;
        esac
        printf '%s\n' "$values"
    }

    kheaders_sha256=$(sha256_file "$kheaders")
    assert_equal "kheaders.ko SHA-256" \
        "$kheaders_sha256" \
        84565f3ecaa2c5a05fa49d1c37034a999fbf7b672faff85f8a444d1cbac23dd3

    kheaders_tmp=$(mktemp -d)
    rodata=$kheaders_tmp/kheaders.rodata
    objcopy --dump-section .rodata="$rodata" \
        "$kheaders" "$kheaders_tmp/kheaders-copy.ko"
    [ -s "$rodata" ] || fail "kheaders.ko has no nonempty .rodata section"

    archive_start_hex=$(symbol_value kernel_headers_data)
    archive_end_hex=$(symbol_value kernel_headers_data_end)
    rodata_vma_hex=$(objdump -h -- "$kheaders" |
        awk '$2 == ".rodata" {print $4}')
    case $rodata_vma_hex in
        ''|*[!0-9A-Fa-f]*)
            fail "could not determine the kheaders.ko .rodata address"
            ;;
    esac

    archive_start=$(printf '%d' "0x$archive_start_hex")
    archive_end=$(printf '%d' "0x$archive_end_hex")
    rodata_vma=$(printf '%d' "0x$rodata_vma_hex")
    [ "$archive_end" -gt "$archive_start" ] ||
        fail "invalid embedded kheaders archive bounds"
    [ "$archive_start" -ge "$rodata_vma" ] ||
        fail "embedded kheaders archive starts before .rodata"
    archive_offset=$((archive_start - rodata_vma))
    archive_size=$((archive_end - archive_start))
    rodata_size=$(stat -c %s "$rodata")
    [ $((archive_offset + archive_size)) -le "$rodata_size" ] ||
        fail "embedded kheaders archive extends past .rodata"

    archive=$kheaders_tmp/kheaders.tar.xz
    dd if="$rodata" of="$archive" iflag=skip_bytes,count_bytes \
        skip="$archive_offset" count="$archive_size" status=none
    assert_equal "embedded kheaders archive size" \
        "$(stat -c %s "$archive")" "$archive_size"
    xz --test "$archive" || fail "embedded kheaders archive is not valid XZ"

    headers=$kheaders_tmp/headers
    mkdir "$headers"
    tar --extract --xz --file "$archive" --directory "$headers" \
        --no-same-owner --no-same-permissions
    header_count=$(find "$headers" -type f -printf x | wc -c)
    header_count=$(printf '%s' "$header_count" | tr -d '[:space:]')
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

    rm -rf "$kheaders_tmp"
    kheaders_tmp=
}

verify_rootfs() {
    for command in cmp dd find grep lsinitramfs nm objcopy objdump python3 \
        sha256sum sort stat systemctl tar tr unmkinitramfs wc xargs xz; do
        require_command "$command"
    done

    root_initrd=$root_dir/boot/initrd.img-7.1.7
    [ -f "$root_initrd" ] || fail "missing $root_initrd"
    root_size=$(file_size "$root_initrd")
    [ "$root_size" -gt 0 ] || fail "root initramfs is empty"
    [ "$root_size" -le 54376639 ] ||
        fail "root initramfs is too large: $root_size bytes"
    initrd_tmp=$(mktemp -d)
    initrd_contents=$initrd_tmp/contents
    lsinitramfs "$root_initrd" > "$initrd_contents" ||
        fail "root initramfs is invalid"
    cmp -n "$root_size" "$root_initrd" "$efi_initrd" ||
        fail "EFI initrd.img does not begin with the rootfs initramfs"
    padding_size=$((efi_size - root_size))
    if [ "$padding_size" -gt 0 ]; then
        nonzero_padding=$(tail -c "$padding_size" "$efi_initrd" |
            tr -d '\000' | wc -c | tr -d '[:space:]')
        [ "$nonzero_padding" = 0 ] ||
            fail "EFI initrd.img has nonzero bytes in its padding tail"
    fi
    kernel_config=$root_dir/boot/config-7.1.7
    [ -s "$kernel_config" ] || fail "missing kernel config: $kernel_config"
    require_initrd_driver() {
        symbol=$1
        module_pattern=$2
        if grep -qx "${symbol}=y" "$kernel_config"; then
            return 0
        fi
        grep -qx "${symbol}=m" "$kernel_config" ||
            fail "$symbol is neither built in nor modular"
        grep -Eq "$module_pattern" "$initrd_contents" ||
            fail "$symbol module is missing from the initramfs"
    }
    require_initrd_driver CONFIG_DRM_AMDGPU '(^|/)amdgpu\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_USB_XHCI_HCD '(^|/)xhci[_-]hcd\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_USB_XHCI_PCI '(^|/)xhci[_-]pci\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_USB_STORAGE '(^|/)usb[_-]storage\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_USB_UAS '(^|/)uas\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_BLK_DEV_SD '(^|/)sd[_-]mod\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_EXT4_FS '(^|/)ext4\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_VFAT_FS '(^|/)vfat\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_USB_HID '(^|/)usbhid\.ko(\.(gz|xz|zst))?$'
    require_initrd_driver CONFIG_HID_GENERIC '(^|/)hid[_-]generic\.ko(\.(gz|xz|zst))?$'

    grep -Eq '(^|/)etc/modprobe.d/ps5-amdgpu\.conf$' "$initrd_contents" ||
        fail "PS5 amdgpu policy is missing from the initramfs"
    grep -Eq '(^|/)etc/modprobe.d/ps5-iw620-noautoload\.conf$' \
        "$initrd_contents" ||
        fail "IW620 no-autoload policy is missing from the initramfs"
    if grep -Eq '(^|/)etc/modules-load.d/moal$' "$initrd_contents"; then
        fail "IW620 autoload file is present in the initramfs"
    fi

    initrd_extract=$initrd_tmp/extracted
    mkdir "$initrd_extract"
    unmkinitramfs "$root_initrd" "$initrd_extract"

    find_single_initrd_file() {
        relative_path=$1
        matches=$(find "$initrd_extract" -type f \
            -path "*/$relative_path" -print)
        match_count=$(printf '%s\n' "$matches" |
            awk 'NF {count++} END {print count + 0}')
        assert_equal "$relative_path initramfs file count" "$match_count" 1
        printf '%s\n' "$matches"
    }

    embedded_amdgpu_policy=$(find_single_initrd_file \
        etc/modprobe.d/ps5-amdgpu.conf)
    assert_file_sha256 "$embedded_amdgpu_policy" \
        b8790c02b88ea706e6d5bb495996e3ddfffcc3f3a0caa35aa8d8384a96ac6f64 \
        "PS5 amdgpu policy in initramfs"
    embedded_iw620_policy=$(find_single_initrd_file \
        etc/modprobe.d/ps5-iw620-noautoload.conf)
    assert_file_sha256 "$embedded_iw620_policy" \
        e12a72fdbfe929e6628c6e68bfb398291f84503f47715248b1146a2ff943fe88 \
        "IW620 no-autoload policy in initramfs"

    while read -r firmware_name firmware_hash; do
        firmware_file=cyan_skillfish2_${firmware_name}.bin
        firmware_path=$(find_single_initrd_file \
            "usr/lib/firmware/amdgpu/$firmware_file")
        assert_file_sha256 "$firmware_path" "$firmware_hash" \
            "$firmware_file in initramfs"
    done <<'EOF_FIRMWARE_HASHES'
ce 5946efbf7e46ccfe7e9f965da56c35b1187469d1c1a49c8a9eff433eb3ab4723
me d4ed4d968de0d7720f7c8215d42fdae727bf99cdf43cee6f8f864dc2584b17e2
mec b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4
mec2 b1c1f843a8faaa2de537d6ba05052a3776b5a1b73f8a3c3f5ed9d568489776a4
pfp 50e56dc1913571ff589425d2b059bddfc5e8a2b4bc22d3eb78cac75d1e0479a1
rlc 20acefdb6128a36275f4382425a109a7c9927f6053eab685bb51164ff1d18cfb
sdma 15d0d3626da7f2513f03b13bb7e02eeeeccab276276ae27d0b6067b5f25e9e95
sdma1 bd1c0b0f6a6a4f17ede034f2c844b6553fc444e08915c7bb500c09fde59d6255
EOF_FIRMWARE_HASHES

    assert_file_sha256 "$root_dir/etc/modprobe.d/ps5-amdgpu.conf" \
        b8790c02b88ea706e6d5bb495996e3ddfffcc3f3a0caa35aa8d8384a96ac6f64 \
        ps5-amdgpu-policy
    assert_file_sha256 "$root_dir/etc/modprobe.d/ps5-iw620-noautoload.conf" \
        e12a72fdbfe929e6628c6e68bfb398291f84503f47715248b1146a2ff943fe88 \
        ps5-iw620-policy

    rm -rf "$initrd_tmp"
    initrd_tmp=
    echo "root initramfs: OK ($root_size-byte exact prefix, zero padding, drivers, and firmware)"

    kernel_dirs=$(find "$root_dir/lib/modules" -mindepth 1 -maxdepth 1 \
        -type d -printf '%f\n' | sort)
    kernel_dir_count=$(printf '%s\n' "$kernel_dirs" |
        awk 'NF {count++} END {print count + 0}')
    assert_equal "installed kernel directory count" "$kernel_dir_count" 1
    assert_equal "installed kernel version" "$kernel_dirs" 7.1.7

    assert_file_sha256 "$root_dir/boot/vmlinuz-7.1.7" \
        11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde \
        vmlinuz-7.1.7
    assert_equal "vmlinuz-7.1.7 size" \
        "$(file_size "$root_dir/boot/vmlinuz-7.1.7")" 12702720
    assert_file_sha256 "$root_dir/boot/config-7.1.7" \
        a2444227c03aaedc240be4631bab29922b901a4b80a1a200f991c73b9d88c641 \
        config-7.1.7
    assert_file_sha256 "$root_dir/boot/System.map-7.1.7" \
        3c0ac3e4094f7e08dd6a85ef7a1ab7684bc794d6c866d5c003be781a4e346a14 \
        System.map-7.1.7

    modules=$root_dir/lib/modules/7.1.7
    [ ! -e "$modules/build" ] && [ ! -L "$modules/build" ] ||
        fail "unexpected kernel build link: $modules/build"
    [ ! -e "$modules/source" ] && [ ! -L "$modules/source" ] ||
        fail "unexpected kernel source link: $modules/source"
    compressed_module=$(find "$modules" -type f \
        \( -name '*.ko.gz' -o -name '*.ko.xz' -o -name '*.ko.zst' \) \
        -print -quit)
    [ -z "$compressed_module" ] ||
        fail "unexpected compressed kernel module: $compressed_module"

    module_count=$(find "$modules" -type f -name '*.ko' -printf x | wc -c)
    module_count=$(printf '%s' "$module_count" | tr -d '[:space:]')
    assert_equal "kernel module count" "$module_count" 517

    kheaders=$modules/kernel/kernel/kheaders.ko
    non_kheaders_count=$(
        cd "$modules"
        find . -type f -name '*.ko' \
            ! -path './kernel/kernel/kheaders.ko' -printf x | wc -c
    )
    non_kheaders_count=$(printf '%s' "$non_kheaders_count" | tr -d '[:space:]')
    assert_equal "non-kheaders module count" "$non_kheaders_count" 516
    non_kheaders_manifest=$(
        cd "$modules"
        find . -type f -name '*.ko' \
            ! -path './kernel/kernel/kheaders.ko' -print0 |
            sort -z |
            xargs -0 sha256sum |
            sha256sum | awk '{print $1}'
    )
    assert_equal "non-kheaders module manifest" \
        "$non_kheaders_manifest" \
        cd5788850c7cf8f724fde5d17a6be5cd7c04de22e00cd14829ff443ec50b3837
    assert_file_sha256 \
        "$modules/kernel/drivers/net/phy/mts/mts.ko" \
        2d7ac8e6ecce80e0f23b624cec66835325951c5bc9c4e620e5f57283caa279a2 \
        mts.ko
    verify_kheaders "$kheaders"
    echo "installed kernel, modules, and embedded headers: OK"

    if [ -n "${EXPECTED_PROFILE_ID:-}" ]; then
        expected_profile_id=$EXPECTED_PROFILE_ID
    elif [ -x "$SCRIPT_DIR/ubuntu2404-profile-id.sh" ]; then
        expected_profile_id=$($SCRIPT_DIR/ubuntu2404-profile-id.sh)
    else
        fail "EXPECTED_PROFILE_ID is required outside the source tree"
    fi
    case $expected_profile_id in
        ''|*[!0-9a-f]*) fail "invalid expected recipe profile ID" ;;
    esac
    [ "${#expected_profile_id}" -eq 64 ] || fail "invalid expected recipe profile ID"
    marker=$root_dir/etc/ps5-image-profile
    [ -f "$marker" ] || fail "missing profile marker: $marker"
    marker_lines=$(wc -l < "$marker" | tr -d '[:space:]')
    assert_equal "profile marker line count" "$marker_lines" 1
    assert_equal "profile marker" "$(cat "$marker")" \
        "ubuntu2404-1160-recipe-$expected_profile_id"

    fstab=$root_dir/etc/fstab
    assert_file_sha256 "$fstab" \
        6508f0eb9f9f923c9cc1155197baaa62a782c8291ece71ad60b66f8b3c6a3176 \
        fstab
    fstab_entries=$(grep -Evc '^[[:space:]]*(#|$)' "$fstab")
    assert_equal "fstab entry count" "$fstab_entries" 2
    assert_line "$fstab" 'LABEL=ubuntu2404 / ext4 defaults 0 1' fstab
    assert_line "$fstab" 'LABEL=boot /boot/efi vfat defaults 0 1' fstab

    passwd_entry=$(awk -F: '$1 == "ps5" {print}' "$root_dir/etc/passwd")
    assert_equal "ps5 passwd entry" "$passwd_entry" \
        'ps5:x:1000:1000::/home/ps5:/bin/bash'
    group_entry=$(awk -F: '$1 == "ps5" {print}' "$root_dir/etc/group")
    assert_equal "ps5 primary group" "$group_entry" 'ps5:x:1000:'
    for group in sudo video input render; do
        awk -F: -v wanted="$group" '
            $1 == wanted {
                count++
                members = "," $4 ","
                if (members ~ /,ps5,/) found = 1
            }
            END {exit !(count == 1 && found)}
        ' "$root_dir/etc/group" || fail "ps5 is not a member of $group"
    done

    ps5_shadow=$(awk -F: '$1 == "ps5" {print $2}' "$root_dir/etc/shadow")
    [ -n "$ps5_shadow" ] || fail "ps5 password hash is empty"
    case $ps5_shadow in
        '!'*|'*'*) fail "ps5 account is locked" ;;
    esac
    python3 - "$ps5_shadow" <<'PY' || fail "ps5 default password is not ubuntu"
import hmac
import sys
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)
import crypt

stored = sys.argv[1]
candidate = crypt.crypt("ubuntu", stored)
raise SystemExit(0 if candidate and hmac.compare_digest(candidate, stored) else 1)
PY
    root_shadow=$(awk -F: '$1 == "root" {print $2}' "$root_dir/etc/shadow")
    case $root_shadow in
        '!'*|'*'*) ;;
        *) fail "root account is not locked" ;;
    esac

    sudoers=$root_dir/etc/sudoers.d/90-ps5-control
    assert_line "$sudoers" 'ps5 ALL=(ALL:ALL) NOPASSWD: ALL' ps5-sudoers
    assert_equal "ps5 sudoers mode" "$(stat -c %a "$sudoers")" 440
    assert_line "$root_dir/etc/gdm3/custom.conf" \
        'AutomaticLoginEnable=true' gdm-autologin
    assert_line "$root_dir/etc/gdm3/custom.conf" \
        'AutomaticLogin=ps5' gdm-autologin

    ssh_config=$root_dir/etc/ssh/sshd_config.d/10-ps5-control.conf
    assert_line "$ssh_config" 'PermitRootLogin no' ssh-policy
    assert_line "$ssh_config" 'PubkeyAuthentication yes' ssh-policy
    assert_line "$ssh_config" 'PasswordAuthentication yes' ssh-policy
    assert_line "$ssh_config" 'PermitEmptyPasswords no' ssh-policy
    assert_line "$ssh_config" 'KbdInteractiveAuthentication no' ssh-policy
    assert_line "$ssh_config" 'AllowUsers ps5' ssh-policy

    for search_root in "$root_dir/home" "$root_dir/root" \
        "$root_dir/etc/skel" "$root_dir/etc/ssh"; do
        [ -d "$search_root" ] || continue
        authorized_key=$(find "$search_root" \( -type f -o -type l \) \
            \( -name authorized_keys -o -name authorized_keys2 \) -print -quit)
        [ -z "$authorized_key" ] ||
            fail "public image contains an authorized_keys file: $authorized_key"
    done
    host_key=$(find "$root_dir/etc/ssh" -maxdepth 1 -name 'ssh_host_*' -print -quit)
    [ -z "$host_key" ] || fail "public image contains an SSH host key: $host_key"

    machine_id=$root_dir/etc/machine-id
    [ -f "$machine_id" ] && [ ! -L "$machine_id" ] ||
        fail "public image /etc/machine-id is not a regular file"
    [ "$(stat -c %s "$machine_id")" -eq 0 ] ||
        fail "public image contains a populated machine ID"
    assert_equal "machine ID owner" "$(stat -c %u:%g "$machine_id")" 0:0
    machine_id_mode=$(stat -c %a "$machine_id")
    [ $((0$machine_id_mode & 0022)) -eq 0 ] ||
        fail "public image machine ID is group/other writable"
    dbus_machine_id=$root_dir/var/lib/dbus/machine-id
    [ -L "$dbus_machine_id" ] ||
        fail "public image D-Bus machine ID is not a symlink"
    assert_equal "D-Bus machine-id link" \
        "$(readlink "$dbus_machine_id")" /etc/machine-id
    journal_file=$(find "$root_dir/var/log/journal" -type f \
        -print -quit 2>/dev/null || true)
    [ -z "$journal_file" ] ||
        fail "public image contains a persisted runtime journal: $journal_file"

    assert_file_sha256 "$root_dir/usr/local/sbin/grow-rootfs" \
        a7e1831a568c0061b8d5591e61a152ed1d0820dd92426c6719c4ccdd55311ce6 \
        grow-rootfs
    assert_file_sha256 "$root_dir/etc/systemd/system/grow-rootfs.service" \
        67c340bf127383993dadbe9dda2695954b5baa5b13b6d79e83e4ae3f402250da \
        grow-rootfs.service
    assert_file_sha256 "$root_dir/etc/systemd/system/ps5fan.service" \
        19711fd4b0d001a0e4218e6051341b63cff6369420f5b999c4868d731c1d9404 \
        ps5fan.service
    [ -x "$root_dir/usr/local/sbin/ps5_fan_max" ] ||
        fail "missing executable ps5_fan_max"
    [ ! -e "$root_dir/usr/local/sbin/ps5_control" ] ||
        fail "obsolete ps5_control helper is present"
    assert_file_sha256 "$root_dir/usr/local/sbin/ps5-amdgpu-reprobe" \
        6a2d4657f2d845a01644e6b4e5f088cec052310dfcfe7d9bec06fce3f40edaca \
        ps5-amdgpu-reprobe
    assert_file_sha256 "$root_dir/etc/systemd/system/ps5-amdgpu-reprobe.service" \
        2409fd812118088098ce6b740acb913d872c1df1efdb38e6254d4d388cabe72e \
        ps5-amdgpu-reprobe.service
    assert_file_sha256 "$root_dir/usr/local/sbin/ps5-boot-report" \
        0ffa81a72d57153590853c00c452f8a497ce951f986eb9c08ddfdd155e700f78 \
        ps5-boot-report
    assert_file_sha256 "$root_dir/etc/systemd/system/ps5-boot-report.service" \
        ecce500865af6769bc92cb41ad00a0d1fa62364480058c645323cbe9f40378a2 \
        ps5-boot-report.service
    assert_file_sha256 "$root_dir/etc/systemd/system/ps5-boot-report.timer" \
        9074e18c67eaec808a8934417573020249d2c3938b8688fb9ef3b36307c04fec \
        ps5-boot-report.timer

    for unit in NetworkManager.service ssh.service \
        grow-rootfs.service systemd-resolved.service \
        ps5-ssh-host-keys.service ps5fan.service \
        ps5-amdgpu-reprobe.service ps5-boot-report.timer; do
        unit_state=$(systemctl --root="$root_dir" is-enabled "$unit" 2>/dev/null || true)
        assert_equal "$unit state" "$unit_state" enabled
    done
    default_target=$(readlink "$root_dir/etc/systemd/system/default.target")
    assert_equal "default systemd target" "$default_target" \
        /usr/lib/systemd/system/graphical.target
    display_manager=$(readlink "$root_dir/etc/systemd/system/display-manager.service")
    assert_equal "display manager" "$display_manager" \
        /usr/lib/systemd/system/gdm.service
    assert_line "$root_dir/etc/systemd/system/gdm.service.d/10-ps5-bringup.conf" \
        'Wants=NetworkManager.service ssh.service' gdm-ordering
    assert_line "$root_dir/etc/systemd/system/gdm.service.d/10-ps5-bringup.conf" \
        'After=NetworkManager.service ssh.service ps5fan.service ps5-amdgpu-reprobe.service' \
        gdm-ordering

    host_key_unit=$root_dir/etc/systemd/system/ps5-ssh-host-keys.service
    assert_line "$host_key_unit" 'ExecStart=/usr/bin/ssh-keygen -A' ssh-host-key-unit
    assert_line "$host_key_unit" 'ExecStart=/usr/sbin/sshd -t' ssh-host-key-unit
    for unit in ssh.service ssh.socket; do
        dropin=$root_dir/etc/systemd/system/$unit.d/10-ps5-host-keys.conf
        assert_line "$dropin" 'Requires=ps5-ssh-host-keys.service' ssh-host-key-ordering
        assert_line "$dropin" 'After=ps5-ssh-host-keys.service' ssh-host-key-ordering
    done

    stage_firmware=$root_dir/etc/systemd/system/ps5-stage-firmware.service
    [ -L "$stage_firmware" ] || fail "ps5-stage-firmware.service is not masked"
    assert_equal "ps5-stage-firmware.service target" \
        "$(readlink "$stage_firmware")" /dev/null
    [ ! -e "$root_dir/etc/modules-load.d/moal" ] && \
        [ ! -L "$root_dir/etc/modules-load.d/moal" ] ||
        fail "IW620 automatic load file is present"
    assert_line "$root_dir/etc/modules-load.d/ps5-ethernet.conf" mts \
        ps5-ethernet-module

    [ ! -e "$root_dir/var/log/ps5-boot-report.txt" ] ||
        fail "unbooted image contains a runtime boot report"
    [ ! -e "$boot_dir/ps5-boot-report.txt" ] ||
        fail "unbooted boot partition contains a runtime boot report"

    echo "profile marker, services, default account, and SSH hygiene: OK"
    echo "runtime identity and boot-report privacy: OK"
}

if [ -n "$root_dir" ]; then
    verify_rootfs
    if [ -n "$layout_disk" ]; then
        echo "Ubuntu 24.04 release image: OK"
    else
        echo "Ubuntu 24.04 mounted filesystems: OK"
        echo "  Partition layout was not checked; use --image for the complete release check."
    fi
else
    echo "Ubuntu 24.04 boot files: partial check passed"
    echo "  Pass the root partition, or use --image, for full validation."
fi

echo "Privacy note: a report created after boot can contain network addresses,"
echo "MAC addresses, connection names, and journal identifiers; redact it before sharing."
