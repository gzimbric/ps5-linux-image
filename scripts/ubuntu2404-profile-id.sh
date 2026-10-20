#!/usr/bin/env bash
# SPDX-License-Identifier: 0BSD

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        echo "ERROR: sha256sum or shasum is required" >&2
        exit 1
    fi
}

sha256_stream() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        echo "ERROR: sha256sum or shasum is required" >&2
        exit 1
    fi
}

required_files=(
    build_image.sh
    scripts/ubuntu2404-profile-id.sh
    scripts/verify-ubuntu2404-boot.sh
    scripts/verify-ubuntu2404-kernel-deb.sh
    docker/image-builder/Dockerfile
    docker/image-builder/entrypoint.sh
    docker/kernel-builder/Dockerfile
    docker/kernel-builder/build.sh
    docker/kernel-builder/build-iw620.sh
    docker/kernel-builder/package-deb.sh
    docker/kernel-builder/repro-date
    distros/shared/zz-update-boot
)

for relative_path in "${required_files[@]}"; do
    if [ ! -f "$REPO_ROOT/$relative_path" ]; then
        echo "ERROR: required profile input is missing: $relative_path" >&2
        exit 1
    fi
done

profile_paths() {
    cd "$REPO_ROOT"
    find distros/ubuntu2404 -type f -print
    printf '%s\n' "${required_files[@]}"
}

profile_manifest() {
    profile_paths | sort -u | while IFS= read -r relative_path; do
        printf '%s  %s\n' \
            "$(sha256_file "$REPO_ROOT/$relative_path")" \
            "$relative_path"
    done
}

profile_manifest | sha256_stream
