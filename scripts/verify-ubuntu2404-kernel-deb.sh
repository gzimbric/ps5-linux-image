#!/bin/sh
# SPDX-License-Identifier: 0BSD
set -eu

usage() {
    echo "Usage: $0 <linux-ps5_7.1.7_amd64.deb>" >&2
    exit 2
}

[ "$#" -eq 1 ] || usage
deb=$1
[ -f "$deb" ] || {
    echo "Not a regular file: $deb" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 || {
    echo "docker is required" >&2
    exit 1
}

deb_dir=$(cd "$(dirname "$deb")" && pwd)
deb="$deb_dir/$(basename "$deb")"
verifier_image=${KERNEL_VERIFIER_IMAGE:-ps5-kernel-builder}

docker image inspect "$verifier_image" >/dev/null 2>&1 || {
    echo "Missing Docker image: $verifier_image" >&2
    echo "Run build_image.sh once to build the pinned kernel-builder image." >&2
    exit 1
}

docker run --rm --network none --platform linux/amd64 \
    --entrypoint /bin/bash \
    -v "$deb:/input.deb:ro" \
    "$verifier_image" -euo pipefail -c '
        export LC_ALL=C
        export TZ=UTC

        fail() {
            echo "ERROR: $*" >&2
            exit 1
        }

        sha256_file() {
            sha256sum "$1" | awk "{print \$1}"
        }

        assert_equal() {
            label=$1
            actual=$2
            expected=$3
            [ "$actual" = "$expected" ] ||
                fail "$label is $actual; expected $expected"
        }

        assert_field() {
            field=$1
            expected=$2
            actual=$(dpkg-deb -f /input.deb "$field")
            assert_equal "$field" "$actual" "$expected"
        }

        assert_file_sha256() {
            path=$1
            expected=$2
            label=$3
            [ -f "$path" ] || fail "missing $label: $path"
            actual=$(sha256_file "$path")
            assert_equal "$label SHA-256" "$actual" "$expected"
        }

        symbol_value() {
            symbol=$1
            mapfile -t values < <(
                nm -n -- "$kheaders" |
                    awk -v symbol="$symbol" "\$3 == symbol {print \$1}"
            )
            [ "${#values[@]}" -eq 1 ] ||
                fail "expected one $symbol symbol in kheaders.ko"
            case ${values[0]} in
                ""|*[!0-9A-Fa-f]*)
                    fail "invalid $symbol value: ${values[0]}"
                    ;;
            esac
            printf "%s\n" "${values[0]}"
        }

        tmp=$(mktemp -d)
        cleanup() {
            rm -rf "$tmp"
        }
        trap cleanup EXIT INT TERM

        assert_field Package linux-ps5
        assert_field Version 7.1.7
        assert_field Architecture amd64
        assert_field Provides linux-image-7.1.7
        assert_field Conflicts linux-image-7.1.7
        assert_field Replaces linux-image-7.1.7

        package_root=$tmp/package
        mkdir "$package_root"
        dpkg-deb --raw-extract /input.deb "$package_root"
        [ -f "$package_root/DEBIAN/control" ] ||
            fail "raw extraction did not include DEBIAN/control"

        ownership_error=$(find "$package_root" \
            \( ! -uid 0 -o ! -gid 0 \) -print -quit)
        [ -z "$ownership_error" ] ||
            fail "package entry is not owned by root: ${ownership_error#"$package_root"/}"

        assert_file_sha256 "$package_root/boot/vmlinuz-7.1.7" \
            11280a8f5ca197ee5458fd446a4dadf2d0b5d0ef6218583cbe6325ee34e99cde \
            vmlinuz-7.1.7
        assert_file_sha256 "$package_root/boot/config-7.1.7" \
            a2444227c03aaedc240be4631bab29922b901a4b80a1a200f991c73b9d88c641 \
            config-7.1.7
        assert_file_sha256 "$package_root/boot/System.map-7.1.7" \
            3c0ac3e4094f7e08dd6a85ef7a1ab7684bc794d6c866d5c003be781a4e346a14 \
            System.map-7.1.7

        modules=$package_root/lib/modules/7.1.7
        [ -d "$modules" ] || fail "missing module tree: $modules"
        [ ! -e "$modules/build" ] && [ ! -L "$modules/build" ] ||
            fail "unexpected kernel build link: $modules/build"
        [ ! -e "$modules/source" ] && [ ! -L "$modules/source" ] ||
            fail "unexpected kernel source link: $modules/source"
        mts=$modules/kernel/drivers/net/phy/mts/mts.ko
        assert_file_sha256 "$mts" \
            2d7ac8e6ecce80e0f23b624cec66835325951c5bc9c4e620e5f57283caa279a2 \
            mts.ko

        module_count=$(find "$modules" -type f -name "*.ko" -printf x | wc -c)
        module_count=${module_count//[[:space:]]/}
        assert_equal "kernel module count" "$module_count" 517

        kheaders=$modules/kernel/kernel/kheaders.ko
        [ -f "$kheaders" ] || fail "missing kheaders.ko"
        non_kheaders_count=$(cd "$modules" &&
            find . -type f -name "*.ko" \
                ! -path "./kernel/kernel/kheaders.ko" -printf x | wc -c)
        non_kheaders_count=${non_kheaders_count//[[:space:]]/}
        assert_equal "non-kheaders module count" "$non_kheaders_count" 516
        non_kheaders_manifest=$(cd "$modules" &&
            find . -type f -name "*.ko" \
                ! -path "./kernel/kernel/kheaders.ko" -print0 |
                sort -z |
                xargs -0 sha256sum |
                sha256sum | awk "{print \$1}")
        assert_equal "non-kheaders module manifest" \
            "$non_kheaders_manifest" \
            cd5788850c7cf8f724fde5d17a6be5cd7c04de22e00cd14829ff443ec50b3837

        kheaders_sha256=$(sha256_file "$kheaders")
        assert_equal "kheaders.ko SHA-256" \
            "$kheaders_sha256" \
            84565f3ecaa2c5a05fa49d1c37034a999fbf7b672faff85f8a444d1cbac23dd3

        rodata=$tmp/kheaders.rodata
        objcopy --dump-section .rodata="$rodata" \
            "$kheaders" "$tmp/kheaders-copy.ko"
        [ -s "$rodata" ] || fail "kheaders.ko has no nonempty .rodata section"

        archive_start_hex=$(symbol_value kernel_headers_data)
        archive_end_hex=$(symbol_value kernel_headers_data_end)
        rodata_vma_hex=$(objdump -h -- "$kheaders" |
            awk "\$2 == \".rodata\" {print \$4}")
        case $rodata_vma_hex in
            ""|*[!0-9A-Fa-f]*)
                fail "could not determine the kheaders.ko .rodata address"
                ;;
        esac

        archive_start=$((16#$archive_start_hex))
        archive_end=$((16#$archive_end_hex))
        rodata_vma=$((16#$rodata_vma_hex))
        [ "$archive_end" -gt "$archive_start" ] ||
            fail "invalid embedded kheaders archive bounds"
        [ "$archive_start" -ge "$rodata_vma" ] ||
            fail "embedded kheaders archive starts before .rodata"
        archive_offset=$((archive_start - rodata_vma))
        archive_size=$((archive_end - archive_start))
        rodata_size=$(stat -c %s "$rodata")
        [ $((archive_offset + archive_size)) -le "$rodata_size" ] ||
            fail "embedded kheaders archive extends past .rodata"

        archive=$tmp/kheaders.tar.xz
        dd if="$rodata" of="$archive" iflag=skip_bytes,count_bytes \
            skip="$archive_offset" count="$archive_size" status=none
        assert_equal "embedded kheaders archive size" \
            "$(stat -c %s "$archive")" "$archive_size"
        xz --test "$archive" || fail "embedded kheaders archive is not valid XZ"

        headers=$tmp/kheaders
        mkdir "$headers"
        tar --extract --xz --file "$archive" --directory "$headers" \
            --no-same-owner --no-same-permissions
        header_count=$(find "$headers" -type f -printf x | wc -c)
        header_count=${header_count//[[:space:]]/}
        assert_equal "embedded kheaders regular-file count" "$header_count" 7069
        header_manifest=$(cd "$headers" &&
            find . -type f -print0 |
                sort -z |
                xargs -0 sha256sum |
                sha256sum | awk "{print \$1}")
        assert_equal "embedded kheaders content manifest" \
            "$header_manifest" \
            6212fdada4054c4bb2bec76e45fb04602c65cf5bec372bea380e3a249b083f75

        package_manifest=$tmp/package-tree.manifest
        (
            cd "$package_root"
            find . -mindepth 1 -print0 | sort -z |
                while IFS= read -r -d "" entry; do
                    mode=$(stat -c %a -- "$entry")
                    if [ -L "$entry" ]; then
                        printf "l\0%s\0%s\0%s\0" \
                            "$mode" "$entry" "$(readlink -- "$entry")"
                    elif [ -f "$entry" ]; then
                        printf "f\0%s\0%s\0%s\0" \
                            "$mode" "$entry" "$(sha256_file "$entry")"
                    elif [ -d "$entry" ]; then
                        printf "d\0%s\0%s\0" "$mode" "$entry"
                    else
                        fail "unsupported package entry type: $entry"
                    fi
                done
        ) > "$package_manifest"
        package_tree_sha256=$(sha256_file "$package_manifest")
        assert_equal "semantic package tree SHA-256" \
            "$package_tree_sha256" \
            1ad9a74eba7ad736a14996fe8f5f8eb706a2dbdd77e1b059efbe715a00a362e9

        echo "Ubuntu 24.04 kernel package: OK"
    '
