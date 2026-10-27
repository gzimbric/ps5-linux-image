#!/bin/bash
set -e

export DOCKER_DEFAULT_PLATFORM=linux/amd64

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DISTRO="ubuntu2604"
KERNEL_SRC=""
KERNEL_SRC_SET=false
CLEAN=false
IMG_SIZE=12000
KERNEL_ONLY=false
PATCHES_REF="kernel-7.2.3-9bad84f"
PATCHES_REF_SET=false
UBUNTU2404_PROFILE_ID=""

MULTI_DISTROS="ubuntu2604 arch cachyos"

usage() {
    echo "Usage: $0 [--distro <distro>] [--kernel <path>] [--img-size <MB>] [--clean]"
    echo ""
    echo "Options:"
    echo "  --distro     Distribution to build: ubuntu2404, ubuntu2604, arch, cachyos, fedora, proxmox, debian, bazzite, bazzite-deck, batocera, all (default: ubuntu2604)"
    echo "  --kernel     Path to kernel source directory (default: auto-clone to work/linux/)"
    echo "  --img-size   Disk image size in MB (default: 12000, 16000 for ubuntu2404, 32000 for all)"
    echo "  --clean      Remove all cached build artifacts and start from scratch"
    echo "  --clean-only Remove all cached build artifacts and exit"
    echo "  --kernel-only  Build and package the kernel only, then exit"
    echo "  --patches-ref  Branch, tag, or commit SHA for patches (default: v1.2; pinned for ubuntu2404)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --distro)    DISTRO="$2";          shift 2 ;;
        --kernel)    KERNEL_SRC="$2"; KERNEL_SRC_SET=true; shift 2 ;;
        --img-size)  IMG_SIZE="$2";        shift 2 ;;
        --clean)     CLEAN=true;           shift ;;
        --clean-only) CLEAN=true; CLEAN_EXIT=true; shift ;;
        --kernel-only) KERNEL_ONLY=true;   shift ;;
        --patches-ref) [ -n "$2" ] && PATCHES_REF="$2"; PATCHES_REF_SET=true; shift 2 ;;
        -h|--help)   usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

if [ "$DISTRO" = "ubuntu2404" ]; then
    if [ "$KERNEL_SRC_SET" = true ]; then
        echo "ERROR: ubuntu2404 uses the pinned Linux source and does not accept --kernel." >&2
        exit 1
    fi
    if [ "$PATCHES_REF_SET" = true ] && \
        [ "$PATCHES_REF" != "kernel-7.1.7-56922cf" ]; then
        echo "ERROR: ubuntu2404 requires --patches-ref kernel-7.1.7-56922cf" >&2
        exit 1
    fi
    PATCHES_REF="kernel-7.1.7-56922cf"
fi

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

verify_source_file() {
    local relative_path="$1"
    local expected_hash="$2"
    local actual_hash
    actual_hash=$(sha256_file "$SCRIPT_DIR/$relative_path")
    if [ "$actual_hash" != "$expected_hash" ]; then
        echo "ERROR: $relative_path does not match the Ubuntu 24.04 tested profile." >&2
        echo "  expected: $expected_hash" >&2
        echo "  actual:   $actual_hash" >&2
        exit 1
    fi
}

validate_ubuntu2404_kernel_cache() {
    local packages=("$KERNEL_OUT"/*.deb)
    if [ "${#packages[@]}" -ne 1 ] || [ ! -f "${packages[0]}" ] ||
        [[ "$(basename "${packages[0]}")" != linux-ps5_*.deb ]]; then
        echo "ERROR: expected exactly one cached Debian package, named linux-ps5_*.deb" >&2
        return 1
    fi
    "$SCRIPT_DIR/scripts/verify-ubuntu2404-kernel-deb.sh" "${packages[0]}"
}

if [ "$DISTRO" = "ubuntu2404" ]; then
    # Fail before the expensive container build if a tested profile input was
    # changed or if an authorized key was accidentally placed in the tree.
    if find "$SCRIPT_DIR/distros/ubuntu2404" \
        \( -type f -o -type l \) -name authorized_keys \
        -print -quit | grep -q .; then
        echo "ERROR: the public Ubuntu 24.04 profile must not embed authorized_keys." >&2
        exit 1
    fi
    verify_source_file distros/ubuntu2404/cmdline.txt \
        6b3c09112fe049d3cbeada65fb3c82bb0f5fcaddce6c0709051df3d9f5a79f6d
    verify_source_file boot/vram.txt \
        bc4642feb06a4cc6d10d5865e321efaad7ab3f3f1d5d025151b79978164310a0
    verify_source_file boot/kexec.sh \
        0f26e09911a8a2bc9912d7c77fee6ac09ccd18a820086cb103be92de081b6c52
    verify_source_file docker/kernel-builder/repro-date \
        3eaadea97d3dc161b9a912b6587dcb1390c0adf4023f470011edd2953e4ac9b4
    verify_source_file distros/ubuntu2404/files/ps5_fan_max.c \
        b4167315a767c3b598b4b99bc6995441422d3ec00c8c9406dbf50518d639d86f
    verify_source_file distros/ubuntu2404/files/ps5fan.service \
        19711fd4b0d001a0e4218e6051341b63cff6369420f5b999c4868d731c1d9404
    verify_source_file distros/ubuntu2404/files/ps5-amdgpu-reprobe \
        6a2d4657f2d845a01644e6b4e5f088cec052310dfcfe7d9bec06fce3f40edaca
    verify_source_file distros/ubuntu2404/files/ps5-amdgpu-reprobe.service \
        2409fd812118088098ce6b740acb913d872c1df1efdb38e6254d4d388cabe72e
    verify_source_file distros/ubuntu2404/files/ps5-boot-report \
        0ffa81a72d57153590853c00c452f8a497ce951f986eb9c08ddfdd155e700f78
    verify_source_file distros/ubuntu2404/files/ps5-boot-report.service \
        ecce500865af6769bc92cb41ad00a0d1fa62364480058c645323cbe9f40378a2
    verify_source_file distros/ubuntu2404/files/ps5-boot-report.timer \
        9074e18c67eaec808a8934417573020249d2c3938b8688fb9ef3b36307c04fec
    verify_source_file distros/ubuntu2404/nm-dns.conf \
        80ee32ae2b4038691ef64248f5794e7d59cc34e626e181482af8037a0e338c04
    verify_source_file distros/ubuntu2404/grow-rootfs \
        a7e1831a568c0061b8d5591e61a152ed1d0820dd92426c6719c4ccdd55311ce6
    verify_source_file distros/ubuntu2404/grow-rootfs.service \
        67c340bf127383993dadbe9dda2695954b5baa5b13b6d79e83e4ae3f402250da
    UBUNTU2404_PROFILE_ID=$("$SCRIPT_DIR/scripts/ubuntu2404-profile-id.sh")
    if ! [[ "$UBUNTU2404_PROFILE_ID" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: invalid Ubuntu 24.04 recipe profile identifier" >&2
        exit 1
    fi
fi

LINUX_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"
LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux"

PATCHES_REPO="https://github.com/ps5-linux/ps5-linux-patches.git"
PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches"

if [ "$DISTRO" = "ubuntu2404" ]; then
    # The exact profile stores only Git objects on the host and materializes
    # its checkout on a Linux volume. Keep those caches separate so ordinary
    # distro profiles never mistake an object-only directory for a checkout.
    LINUX_DEFAULT_DIR="$SCRIPT_DIR/work/linux-ubuntu2404-objects"
    PATCHES_DIR="$SCRIPT_DIR/work/ps5-linux-patches-ubuntu2404"
fi

if [ -z "$KERNEL_SRC" ]; then
    KERNEL_SRC="$LINUX_DEFAULT_DIR"
fi

KERNEL_OUT="$SCRIPT_DIR/linux-bin"
OUTPUT_DIR="$SCRIPT_DIR/output"
CHROOT_DIR="$SCRIPT_DIR/work/chroot"
CACHE_DIR="$SCRIPT_DIR/work/cache"
CCACHE_DIR="${CCACHE_DIR:-$SCRIPT_DIR/ccache}"

if [ "$DISTRO" = "ubuntu2404" ]; then
    KERNEL_OUT="$SCRIPT_DIR/linux-bin/ubuntu2404"
    CHROOT_DIR="$SCRIPT_DIR/work/chroot-ubuntu2404"
    CACHE_DIR="$SCRIPT_DIR/work/cache-ubuntu2404"
fi

LOG_FILE="$SCRIPT_DIR/build.log"
DOCKER_NAME="ps5-build-$$"



if [ "$DISTRO" = "all" ] && [ "$IMG_SIZE" = "12000" ]; then
    IMG_SIZE=32000
fi

# Bazzite assembles the OCI rootfs + an embedded /sysroot/ostree/repo/objects
# (a deduplicated second copy of the same content) + the linux-ps5 kernel —
# 12 GB is not enough headroom. Bump the default for any bazzite* target.
# Batocera unsquashes to ~6 GB; 12 GB is tight once kernel + initrd +
# /userdata defaults are added. Bump to 16 GB.
case "$DISTRO" in
    ubuntu2404)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=16000
        fi
        ;;
    bazzite*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=24000
        fi
        ;;
    batocera*)
        if [ "$IMG_SIZE" = "12000" ]; then
            IMG_SIZE=16000
        fi
        ;;
esac

if [ "$DISTRO" = "ubuntu2404" ] && [ "$IMG_SIZE" != "16000" ]; then
    echo "ERROR: ubuntu2404 requires --img-size 16000 for the tested GPT layout." >&2
    exit 1
fi

if [ -z "$FORMAT" ]; then
    case "$DISTRO" in
        arch|cachyos|steamos) FORMAT="arch" ;;
        fedora|bazzite*)     FORMAT="rpm"  ;;
        all)                 FORMAT="all"  ;;
        *)                   FORMAT="deb"  ;;
    esac
fi

if [ "$DISTRO" = "ubuntu2404" ] && [ "$FORMAT" != "deb" ]; then
    echo "ERROR: ubuntu2404 requires FORMAT=deb." >&2
    exit 1
fi

KERNEL_BUILDER_PLATFORM="linux/amd64"
case "$(uname -m)" in
    aarch64|arm64) KERNEL_BUILDER_PLATFORM="linux/arm64" ;;
esac

KERNEL_BUILDER_BUILD_ARGS=()
KERNEL_BUILDER_RUN_ARGS=()
if [ "$DISTRO" = "ubuntu2404" ]; then
    # Run 16 was reproduced in the native amd64 Debian environment identified
    # below. Other distributions retain the upstream host-native builder path.
    KERNEL_BUILDER_PLATFORM="linux/amd64"
    KERNEL_BUILDER_BUILD_ARGS+=(
        --build-arg
        KERNEL_BUILDER_BASE=debian@sha256:bcf83fd8af414eda0c0a99d25a4e61dedd88e7aac7f7bc519d04555ff0c40ec5
        --build-arg
        KERNEL_BUILDER_APT_SNAPSHOT=20261017T000000Z
    )
    KERNEL_BUILDER_RUN_ARGS+=(
        -e EXACT_RUN16_KERNEL=1
        -e CCACHE_DISABLE=1
        -e JOBS=12
    )
fi

# --- Signal trap: clean up docker containers and background jobs on exit ---
BUILD_PID=""
KERNEL_BUILD_VOLUME=""
IMAGE_CHROOT_VOLUME=""

cleanup() {
    trap - INT TERM EXIT
    echo ""
    echo "Cleaning up..."
    docker kill "$DOCKER_NAME" 2>/dev/null || true
    [ -n "$BUILD_PID" ] && kill "$BUILD_PID" 2>/dev/null || true
    wait "$BUILD_PID" 2>/dev/null || true
    if [ -n "$KERNEL_BUILD_VOLUME" ]; then
        if docker volume rm "$KERNEL_BUILD_VOLUME" >/dev/null 2>&1; then
            KERNEL_BUILD_VOLUME=""
        else
            echo "WARNING: could not remove Docker volume $KERNEL_BUILD_VOLUME" >&2
        fi
    fi
    if [ -n "$IMAGE_CHROOT_VOLUME" ]; then
        if docker volume rm "$IMAGE_CHROOT_VOLUME" >/dev/null 2>&1; then
            IMAGE_CHROOT_VOLUME=""
        else
            echo "WARNING: could not remove Docker volume $IMAGE_CHROOT_VOLUME" >&2
        fi
    fi
}
trap cleanup INT TERM EXIT

# --- Clean ---
if [ "$CLEAN" = true ]; then
    echo "Cleaning all build artifacts..."
    for dir in "$SCRIPT_DIR/work" "$KERNEL_OUT" "$SCRIPT_DIR/cache" \
               "$SCRIPT_DIR/ccache" "$OUTPUT_DIR"; do
        [ -d "$dir" ] && docker run --rm \
            -v "$(dirname "$dir")":/parent \
            alpine rm -rf "/parent/$(basename "$dir")"
    done
    echo "Done."
    [ "$CLEAN_EXIT" = true ] && exit 0
    echo ""
fi

# --- Auto-detect what can be skipped ---
SKIP_KERNEL=false
SKIP_CHROOT=false

case "$FORMAT" in
    arch) ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    rpm)  ls "$KERNEL_OUT"/*.rpm 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    all)  ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && \
          ls "$KERNEL_OUT"/*.pkg.tar.zst 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
    *)    ls "$KERNEL_OUT"/*.deb 1>/dev/null 2>&1 && SKIP_KERNEL=true ;;
esac

if [ "$DISTRO" = "ubuntu2404" ] && [ "$SKIP_KERNEL" = true ]; then
    if validate_ubuntu2404_kernel_cache; then
        printf "  ✓ %-60s\n" "Ubuntu 24.04 cached kernel package verified"
    else
        echo "Ignoring an incompatible cached kernel package for ubuntu2404."
        SKIP_KERNEL=false
    fi
fi

if [ "$DISTRO" = "all" ]; then
    SKIP_CHROOT=true
    for d in $MULTI_DISTROS; do
        [ -d "$SCRIPT_DIR/work/chroot-$d/bin" ] || SKIP_CHROOT=false
    done
else
    [ -d "$CHROOT_DIR/bin" ] && SKIP_CHROOT=true
fi

if [ "$DISTRO" = "ubuntu2404" ]; then
    # This profile is assembled on a disposable Linux-native Docker volume,
    # so a host-side root filesystem is never a compatible cache.
    SKIP_CHROOT=false
fi

# --- Build plan summary ---
echo ""
echo "PS5 Linux Image Builder"
echo "======================="
if [ "$KERNEL_ONLY" = true ]; then
    echo "  Mode:         kernel only"
    echo "  Format:       $FORMAT"
else
    echo "  Distro:       $DISTRO"
    [ "$DISTRO" = "all" ] && echo "                ($MULTI_DISTROS)"
    echo "  Image size:   ${IMG_SIZE}MB"
fi
if [ -f "$PATCHES_DIR/.config" ]; then
    LINUX_BRANCH="v$(sed -nE 's/^# Linux\/[^ ]+ ([0-9]+\.[0-9]+(\.[0-9]+)?) .*/\1/p' "$PATCHES_DIR/.config" | head -1)"
    echo "  Kernel:       $LINUX_BRANCH"
else
    echo "  Kernel:       (will fetch)"
fi
echo "  Kernel src:   $KERNEL_SRC"
echo ""
echo "Stages:"
if [ "$SKIP_KERNEL" = true ]; then
    echo "  1. Kernel            cached"
elif [ -d "$KERNEL_SRC/.git" ]; then
    echo "  1. Kernel            build (source cached)"
else
    echo "  1. Kernel            clone + build"
fi
if [ "$KERNEL_ONLY" = false ]; then
    if [ "$SKIP_CHROOT" = true ]; then
        echo "  2. Root filesystem   cached"
    else
        echo "  2. Root filesystem   build"
    fi
    echo "  3. Disk image        build"
fi
echo ""
echo "Logs: $LOG_FILE"
echo ""

# --- Logging + stage runner ---
: > "$LOG_FILE"

SPIN_CHARS='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

run_stage() {
    local name="$1"
    shift

    if [ "${CI:-}" = "true" ]; then
        echo "::group::$name"
        local rc=0
        "$@" || rc=$?
        echo "::endgroup::"
        if [ $rc -ne 0 ]; then
            echo "::error::Build failed at: $name"
            exit $rc
        fi
        return
    fi

    local status_msg="$name"
    local spin_i=0

    # Record log position so we only scan new lines for status updates
    local log_start
    log_start=$(wc -l < "$LOG_FILE")

    # Run command in background
    "$@" >> "$LOG_FILE" 2>&1 &
    BUILD_PID=$!

    # Spinner loop — pick up === status lines from the log
    while kill -0 "$BUILD_PID" 2>/dev/null; do
        if (( spin_i % 10 == 0 )); then
            local new
            new=$(tail -n +$((log_start + 1)) "$LOG_FILE" 2>/dev/null \
                | sed -nE 's/^=== (.*) ===$/\1/p' | tail -1)
            [ -n "$new" ] && status_msg="$new"
        fi
        printf "\r  %s %-60s" "${SPIN_CHARS:spin_i%${#SPIN_CHARS}:1}" "$status_msg"
        spin_i=$((spin_i + 1))
        sleep 0.1
    done

    local rc=0
    wait "$BUILD_PID" || rc=$?
    BUILD_PID=""

    if [ $rc -eq 0 ]; then
        printf "\r  ✓ %-60s\n" "$name"
    else
        printf "\r  ✗ %-60s\n" "$status_msg"
        echo ""
        echo "Build failed at: $status_msg"
        echo "Logs: $LOG_FILE"
        echo "Try running with --clean to start fresh."
        exit 1
    fi
}

# --- Setup directories ---
mkdir -p "$KERNEL_OUT" "$OUTPUT_DIR" "$CHROOT_DIR" "$CACHE_DIR" "$CCACHE_DIR"
if [ "$DISTRO" = "all" ]; then
    for d in $MULTI_DISTROS; do
        mkdir -p "$SCRIPT_DIR/work/chroot-$d"
    done
fi

# --- Step 1: Kernel ---
if [ "$SKIP_KERNEL" = true ]; then
    printf "  ✓ %-60s\n" "Kernel packages (cached)"
else
    if [ "$DISTRO" = "ubuntu2404" ]; then
        # The exact profile never trusts a prior source checkout. In
        # particular, a checkout on case-insensitive macOS cannot represent
        # all case-colliding Linux paths. Remove only builder-managed trees;
        # external --kernel paths are rejected above.
        for dir in "$LINUX_DEFAULT_DIR" "${LINUX_DEFAULT_DIR}.tmp" "$PATCHES_DIR"; do
            [ -d "$dir" ] && docker run --rm \
                -v "$(dirname "$dir")":/parent \
                alpine rm -rf "/parent/$(basename "$dir")"
        done
        KERNEL_SRC="$LINUX_DEFAULT_DIR"
    fi

    if [ ! -d "$KERNEL_SRC/.git" ]; then
        REPO_URL="$PATCHES_REPO"
        [ -n "$PATCHES_TOKEN" ] && REPO_URL="${PATCHES_REPO/https:\/\//https:\/\/${PATCHES_TOKEN}@}"


        mkdir -p "$PATCHES_DIR"
        run_stage "Fetch ps5-linux-patches ($PATCHES_REF)" bash -c '
            cd "'"$PATCHES_DIR"'"
            [ ! -d .git ] && git init && git remote add origin "'"$REPO_URL"'"
            git fetch --depth 1 origin "'"$PATCHES_REF"'" || git fetch origin "'"$PATCHES_REF"'"
            git reset --hard FETCH_HEAD
        '
        if [ "$DISTRO" = "ubuntu2404" ]; then
            if [ "$(git -C "$PATCHES_DIR" rev-parse HEAD)" != \
                56922cf9af91142cdcf7d54cbcfb3d46bdfb397a ]; then
                echo "ERROR: ubuntu2404 requires patch-set commit 56922cf9af91142cdcf7d54cbcfb3d46bdfb397a" >&2
                exit 1
            fi
            printf "  ✓ %-60s\n" "Ubuntu 24.04 patch-set commit"
        fi
        LINUX_TMP_DIR="${LINUX_DEFAULT_DIR}.tmp"
        for dir in "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"; do
            [ -d "$dir" ] && docker run --rm \
                -v "$(dirname "$dir")":/parent \
                alpine rm -rf "/parent/$(basename "$dir")"
        done
        LINUX_BRANCH="v$(sed -nE 's/^# Linux\/[^ ]+ ([0-9]+\.[0-9]+(\.[0-9]+)?) .*/\1/p' "$PATCHES_DIR/.config" | head -1)"

        if [ "$DISTRO" = "ubuntu2404" ]; then
            # Keep only Git objects on the host. The checked-out source is
            # materialized later on Docker's case-sensitive Linux volume.
            run_stage "Fetch kernel objects $LINUX_BRANCH" \
                git clone --no-checkout --branch "$LINUX_BRANCH" --depth 1 \
                    "$LINUX_REPO" "$LINUX_TMP_DIR"
            if [ "$(git -C "$LINUX_TMP_DIR" rev-parse HEAD)" != \
                c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6 ]; then
                echo "ERROR: ubuntu2404 requires Linux commit c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6" >&2
                exit 1
            fi
        else
            run_stage "Clone kernel $LINUX_BRANCH" \
                git clone --branch "$LINUX_BRANCH" --depth 1 \
                    "$LINUX_REPO" "$LINUX_TMP_DIR"

            run_stage "Apply patches" bash -c '
                set -e; shopt -s nullglob
                patches=("'"$PATCHES_DIR"'"/*.patch)
                [ ${#patches[@]} -eq 0 ] && { echo "No .patch files found in '"$PATCHES_DIR"'"; exit 1; }
                for p in "${patches[@]}"; do
                    echo "Applying $p"
                    git -C "'"$LINUX_TMP_DIR"'" apply --exclude=Makefile "$p"
                done'

            run_stage "Copy kernel config" \
                cp "$PATCHES_DIR/.config" "$LINUX_TMP_DIR/.config"
        fi

        mv "$LINUX_TMP_DIR" "$LINUX_DEFAULT_DIR"
        KERNEL_SRC="$LINUX_DEFAULT_DIR"
    else
        printf "  ✓ %-60s\n" "Kernel source (cached)"
    fi

    KERNEL_SRC="$(cd "$KERNEL_SRC" && pwd)"

    rm -f "$KERNEL_OUT"/*.deb "$KERNEL_OUT"/*.pkg.tar.zst "$KERNEL_OUT"/*.rpm

    run_stage "Build kernel builder image" \
        docker build --platform "$KERNEL_BUILDER_PLATFORM" \
            "${KERNEL_BUILDER_BUILD_ARGS[@]}" -t ps5-kernel-builder \
            -f "$SCRIPT_DIR/docker/kernel-builder/Dockerfile" "$SCRIPT_DIR"

    KERNEL_SOURCE_ARGS=(-v "$KERNEL_SRC:/src")
    if [ "$DISTRO" = "ubuntu2404" ]; then
        # Materialize Git objects directly on Docker's case-sensitive Linux
        # filesystem. A macOS checkout collapses 13 case-colliding Linux path
        # pairs, and shared-filesystem semantics also break CONFIG_IKHEADERS.
        KERNEL_BUILD_VOLUME="ps5-kernel-source-$$-$RANDOM"
        if docker volume inspect "$KERNEL_BUILD_VOLUME" >/dev/null 2>&1; then
            echo "ERROR: refusing to reuse Docker volume $KERNEL_BUILD_VOLUME" >&2
            exit 1
        fi
        docker volume create "$KERNEL_BUILD_VOLUME" >/dev/null
        run_stage "Stage kernel source on Linux filesystem" \
            docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" \
                --name "$DOCKER_NAME" --entrypoint /bin/bash \
                -v "$KERNEL_SRC/.git":/linux.git:ro \
                -v "$PATCHES_DIR":/patches:ro \
                -v "$KERNEL_BUILD_VOLUME":/src \
                ps5-kernel-builder -euo pipefail -c '
                    cd /src
                    test -z "$(find . -mindepth 1 -maxdepth 1 -print -quit)"
                    git --git-dir=/linux.git archive HEAD | tar -xf - -C /src
                    test "$(git --git-dir=/linux.git rev-parse HEAD)" = \
                        c7ba9d6de43e9d9bd755b1f3c19501a38898c6b6

                    collision_paths=/tmp/ps5-case-collision-paths
                    git --git-dir=/linux.git ls-tree -r --name-only HEAD \
                        | LC_ALL=C awk '\''{
                            key=tolower($0)
                            if (key in seen && seen[key] != $0) {
                                print seen[key]
                                print $0
                            } else {
                                seen[key]=$0
                            }
                        }'\'' | LC_ALL=C sort -u > "$collision_paths"
                    test "$(wc -l < "$collision_paths")" -eq 26
                    while IFS= read -r path; do
                        expected=$(git --git-dir=/linux.git rev-parse "HEAD:$path")
                        actual=$(git hash-object "/src/$path")
                        test "$actual" = "$expected" || {
                            echo "Case-colliding source path mismatch: $path" >&2
                            exit 1
                        }
                    done < "$collision_paths"

                    git init -q
                    shopt -s nullglob
                    patches=(/patches/*.patch)
                    test "${#patches[@]}" -gt 0
                    for patch in "${patches[@]}"; do
                        git apply --exclude=Makefile "$patch"
                    done
                    cp /patches/.config .config
                    test "$(sha256sum .config | awk '\''{print $1}'\'')" = \
                        4d6fa3652262a0e123b3add343bcdacd75976e158f35471b348b12b8ae2219b6
                    rm -rf .git
                '
        KERNEL_SOURCE_ARGS=(-v "$KERNEL_BUILD_VOLUME:/src")
    fi

    run_stage "Compile kernel" \
        docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
            "${KERNEL_BUILDER_RUN_ARGS[@]}" \
            "${KERNEL_SOURCE_ARGS[@]}" \
            -v "$KERNEL_OUT":/out \
            -v "$CCACHE_DIR":/ccache \
            ps5-kernel-builder

    kernel_versions=()
    while IFS= read -r kernel_version; do
        kernel_versions+=("$kernel_version")
    done < <(
        find "$KERNEL_OUT/staging/lib/modules" -mindepth 1 -maxdepth 1 \
            -type d -print | LC_ALL=C sort
    )
    if [ "${#kernel_versions[@]}" -ne 1 ]; then
        echo "ERROR: expected exactly one staged kernel module directory" >&2
        printf '  %s\n' "${kernel_versions[@]}" >&2
        exit 1
    fi
    basename "${kernel_versions[0]}" > "$KERNEL_OUT/VERSION"

    case "$FORMAT" in deb|all)
        run_stage "Package kernel (.deb)" \
            docker run --rm --platform "$KERNEL_BUILDER_PLATFORM" --name "$DOCKER_NAME" \
                "${KERNEL_BUILDER_RUN_ARGS[@]}" \
                "${KERNEL_SOURCE_ARGS[@]}" \
                -v "$KERNEL_OUT":/out \
                -v "$CCACHE_DIR":/ccache \
                ps5-kernel-builder \
                /package-deb.sh
    esac

    if [ "$DISTRO" = "ubuntu2404" ]; then
        if ! validate_ubuntu2404_kernel_cache; then
            echo "ERROR: freshly built Ubuntu 24.04 kernel package failed validation" >&2
            exit 1
        fi
        printf "  ✓ %-60s\n" "Ubuntu 24.04 fresh kernel package verified"
        if [ -n "$KERNEL_BUILD_VOLUME" ]; then
            docker volume rm "$KERNEL_BUILD_VOLUME" >/dev/null
            KERNEL_BUILD_VOLUME=""
        fi
    fi

    case "$FORMAT" in arch|all)
        run_stage "Build arch packager image" \
            docker build -t ps5-kernel-packager-arch \
                -f "$SCRIPT_DIR/docker/kernel-builder-arch/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.pkg.tar.zst)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-arch
    esac

    case "$FORMAT" in rpm)
        run_stage "Build rpm packager image" \
            docker build -t ps5-kernel-packager-rpm \
                -f "$SCRIPT_DIR/docker/kernel-builder-rpm/Dockerfile" "$SCRIPT_DIR"
        run_stage "Package kernel (.rpm)" \
            docker run --rm --name "$DOCKER_NAME" \
                -v "$KERNEL_OUT":/out \
                ps5-kernel-packager-rpm
    esac
fi

if [ "$KERNEL_ONLY" = true ]; then
    KVER=$(cat "$KERNEL_OUT/VERSION" 2>/dev/null || echo "unknown")
    echo ""
    echo "Done! Kernel $KVER packages in $KERNEL_OUT/"
    exit 0
fi

# --- Step 2: Build distribution image ---
if ! docker buildx version >/dev/null 2>&1; then
    echo "ERROR: Docker Buildx is required to build the distribution image." >&2
    echo "Install the Docker Buildx plugin, then run this command again." >&2
    exit 1
fi

run_stage "Build image builder image" \
    docker buildx build --load --pull --no-cache \
        --platform "$KERNEL_BUILDER_PLATFORM" \
        -t ps5-image-builder -f "$SCRIPT_DIR/docker/image-builder/Dockerfile" "$SCRIPT_DIR"

if [ "$DISTRO" = "all" ]; then
    DOCKER_ARGS=(
        docker run --rm --privileged --platform "$KERNEL_BUILDER_PLATFORM"
        --name "$DOCKER_NAME"
        --entrypoint /entrypoint-multi.sh
        -v "$SCRIPT_DIR":/repo:ro
        -v "$KERNEL_OUT":/kernel-debs:ro
        -v "$OUTPUT_DIR":/output
        -v "$CACHE_DIR":/build/cache
        -e IMG_SIZE="$IMG_SIZE"
        -e SKIP_CHROOT="$SKIP_CHROOT"
        -e "DISTROS=$MULTI_DISTROS"
    )
    for d in $MULTI_DISTROS; do
        DOCKER_ARGS+=(-v "$SCRIPT_DIR/work/chroot-$d:/build/chroot-$d")
    done
    DOCKER_ARGS+=(ps5-image-builder)

    run_stage "Build multi-distro image (${IMG_SIZE}MB)" "${DOCKER_ARGS[@]}"

    IMG_PATH="$OUTPUT_DIR/ps5-multi.img"
else
    IMAGE_PROFILE_ARGS=()
    IMAGE_CHROOT_ARGS=(-v "$CHROOT_DIR:/build/chroot")
    if [ "$DISTRO" = "ubuntu2404" ]; then
        IMAGE_PROFILE_ARGS+=(
            -e "UBUNTU2404_PROFILE_ID=$UBUNTU2404_PROFILE_ID"
        )
        # A root filesystem must preserve Linux ownership, modes, symlinks,
        # device nodes, and case semantics. Desktop bind mounts do not always
        # provide those guarantees, so assemble this profile on a disposable
        # Linux-native Docker volume and export only the finished disk image.
        SKIP_CHROOT=false
        IMAGE_CHROOT_VOLUME="ps5-image-chroot-$$-$RANDOM"
        if docker volume inspect "$IMAGE_CHROOT_VOLUME" >/dev/null 2>&1; then
            echo "ERROR: refusing to reuse Docker volume $IMAGE_CHROOT_VOLUME" >&2
            exit 1
        fi
        docker volume create "$IMAGE_CHROOT_VOLUME" >/dev/null
        IMAGE_CHROOT_ARGS=(-v "$IMAGE_CHROOT_VOLUME:/build/chroot")
    fi
    run_stage "Build $DISTRO image (${IMG_SIZE}MB)" \
        docker run --rm --privileged --platform "$KERNEL_BUILDER_PLATFORM" \
            --name "$DOCKER_NAME" \
            -v "$SCRIPT_DIR":/repo:ro \
            -v "$KERNEL_OUT":/kernel-debs:ro \
            -v "$OUTPUT_DIR":/output \
            "${IMAGE_CHROOT_ARGS[@]}" \
            -v "$CACHE_DIR":/build/cache \
            -e DISTRO="$DISTRO" \
            -e IMG_SIZE="$IMG_SIZE" \
            -e SKIP_CHROOT="$SKIP_CHROOT" \
            "${IMAGE_PROFILE_ARGS[@]}" \
            ps5-image-builder

    IMG_PATH="$OUTPUT_DIR/ps5-${DISTRO}.img"
fi

echo ""
echo "Done! Image: $IMG_PATH"
echo "Flash: sudo dd if=$IMG_PATH of=/dev/sdX bs=4M status=progress"
