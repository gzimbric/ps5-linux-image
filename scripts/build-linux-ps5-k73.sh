#!/usr/bin/env bash
# Build the Linux 7.3.0 kernel and the IW620 Wi-Fi modules for the CachyOS
# 7.3 image for PS5 firmware 11.60.
#
# Fetches every source at a pinned commit, builds the kernel in the Debian
# gcc 14.2 kernel-builder image (docker/kernel-builder/build-k73.sh), then
# builds mlan.ko and moal.ko against the same tree without network access
# (docker/kernel-builder/build-iw620-k73.sh). scripts/package-linux-ps5-k73.sh
# then turns the result into the linux-ps5 pacman package.
#
# The kernel patch set is the 7.3 port with the PS5 CPU and GPU frequency
# drivers by rmux, rmuxnet/ps5-linux-patches-1, fetched at
# the pinned commit. The builder then applies the exact, hash-pinned IW620
# Bluetooth source patch published with ps5-bazzite-deck v1.0.3.
#
# Needs git and Docker. Runs on Linux or macOS; GitHub Actions uses an x86_64
# runner and the linux/amd64 builder.
set -euo pipefail
export LC_ALL=C

LINUX_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
LINUX_TAG=v7.3
LINUX_TAG_OBJECT=091b06388b117fefdcb63336ac09956a4914b961
LINUX_COMMIT=c03c1a14507dfaf8b856c2608f9ac216021fc222
PATCHES_REPO=https://github.com/rmuxnet/ps5-linux-patches-1.git
PATCHES_COMMIT=36f173f39e5e76c00c4e366a7b909f33bc665ad5
PS5_MWIFIEX_REPO=https://github.com/ps5-linux/ps5-linux-mwifiex.git
PS5_MWIFIEX_COMMIT=4bce848dd098bf74fbafd0078463da3d9f0d7f80
NXP_MWIFIEX_REPO=https://github.com/nxp-imx/mwifiex.git
NXP_MWIFIEX_COMMIT=a5fe4e194bf99315e349d81d77d6dfacec70757a

# The Debian trixie image (debian:trixie-20261005) and package snapshot the
# Ubuntu 24.04 kernel was reproduced with. CI uses the amd64 image; the arm64
# image of the same release is only for local cross builds, where
# x86_64-linux-gnu-gcc is the same Debian 14.2.0-19 cross compiler.
BUILDER_BASE_AMD64=debian@sha256:bcf83fd8af414eda0c0a99d25a4e61dedd88e7aac7f7bc519d04555ff0c40ec5
BUILDER_BASE_ARM64=debian@sha256:b55910b579d6eb05ebd79fbc8468b974fa39bb0610d52e1f1390bb2177ab7614
BUILDER_APT_SNAPSHOT=20261017T000000Z

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

usage() {
  cat <<EOF
Usage: $0 [--out DIR] [--work DIR] [--platform linux/amd64|linux/arm64]
          [--linux-repo URL] [--patches-repo URL] [--jobs N] [--keep-volume]

  --out DIR        output directory (default: linux-bin/cachyos1160-k73). It
                   has to be on a case-sensitive filesystem: the kernel
                   headers have file names that differ only in case. On
                   macOS, use a case-sensitive APFS disk image.
  --work DIR       source downloads (default: work/k73)
  --platform P     kernel-builder platform (default: linux/amd64). Use
                   linux/arm64 on an arm64 host for a local cross build.
  --linux-repo URL fetch v7.3 from this repository instead of $LINUX_REPO
                   (for example a local clone); the tag must still point at
                   $LINUX_COMMIT
  --patches-repo URL
                   fetch the 7.3 patch set from this repository instead of
                   $PATCHES_REPO
                   (for example a mirror); it must still have commit
                   $PATCHES_COMMIT, and linux.patch,
                   .config and ps5_vcn.bin are still checked by SHA-256
  --jobs N         parallel build jobs (default: all CPUs in the container)
  --keep-volume    keep the Docker volume with the built kernel tree
EOF
}

log() { printf '\n== %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

out=$REPO/linux-bin/cachyos1160-k73
work=$REPO/work/k73
platform=linux/amd64
jobs=
keep_volume=0
while (($#)); do
  case $1 in
    --out) (($# >= 2)) || die "--out needs a directory"; out=$2; shift 2 ;;
    --work) (($# >= 2)) || die "--work needs a directory"; work=$2; shift 2 ;;
    --platform) (($# >= 2)) || die "--platform needs a value"; platform=$2; shift 2 ;;
    --linux-repo) (($# >= 2)) || die "--linux-repo needs a URL"; LINUX_REPO=$2; shift 2 ;;
    --patches-repo) (($# >= 2)) || die "--patches-repo needs a URL"; PATCHES_REPO=$2; shift 2 ;;
    --jobs) (($# >= 2)) || die "--jobs needs a number"; jobs=$2; shift 2 ;;
    --keep-volume) keep_volume=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

case $platform in
  linux/amd64) builder_base=$BUILDER_BASE_AMD64 ;;
  linux/arm64) builder_base=$BUILDER_BASE_ARM64 ;;
  *) die "unsupported platform $platform" ;;
esac
[[ -z $jobs || $jobs =~ ^[1-9][0-9]*$ ]] || die "--jobs must be a positive number"
for cmd in docker git tar; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

mkdir -p -- "$out" "$work"
out=$(cd -- "$out" && pwd)
work=$(cd -- "$work" && pwd)
probe=$(mktemp -d "$out/.case.XXXXXX")
touch "$probe/a"
if [[ -e $probe/A ]]; then
  rm -rf -- "$probe"
  die "$out is on a case-insensitive filesystem; the kernel headers need a case-sensitive one"
fi
rm -rf -- "$probe"
builder=ps5-kernel-builder-k73:${platform#linux/}
volume=ps5-k73-src-$$-$RANDOM
container=ps5-k73-build-$$

cleanup() {
  local rc=$?
  trap - EXIT
  docker kill "$container" >/dev/null 2>&1 || true
  if ((keep_volume)); then
    echo "Kept Docker volume $volume"
  else
    docker volume rm "$volume" >/dev/null 2>&1 || true
  fi
  ((rc == 0)) || echo "Kernel build failed (exit $rc)" >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Fetch one ref into a bare repository and check what it points at.
fetch_pinned() { # dir url ref expected-commit
  local dir=$1 url=$2 ref=$3 commit=$4 got
  rm -rf -- "$dir"
  git init -q --bare "$dir"
  git -C "$dir" fetch -q --depth 1 --no-tags "$url" "$ref"
  got=$(git -C "$dir" rev-parse 'FETCH_HEAD^{commit}')
  [[ $got == "$commit" ]] || die "$url $ref is $got, expected $commit"
  git -C "$dir" update-ref refs/heads/pinned "$commit"
  git -C "$dir" symbolic-ref HEAD refs/heads/pinned
  echo "ok  $commit  $url $ref"
}

log "Sources"
fetch_pinned "$work/linux.git" "$LINUX_REPO" "refs/tags/$LINUX_TAG" "$LINUX_COMMIT"
[[ $(git -C "$work/linux.git" rev-parse FETCH_HEAD) == "$LINUX_TAG_OBJECT" ]] ||
  die "tag $LINUX_TAG is not the tag object $LINUX_TAG_OBJECT"
fetch_pinned "$work/ps5-linux-patches.git" "$PATCHES_REPO" "$PATCHES_COMMIT" "$PATCHES_COMMIT"
fetch_pinned "$work/iw620/ps5-linux-mwifiex" "$PS5_MWIFIEX_REPO" "$PS5_MWIFIEX_COMMIT" "$PS5_MWIFIEX_COMMIT"
fetch_pinned "$work/iw620/nxp-mwifiex" "$NXP_MWIFIEX_REPO" "$NXP_MWIFIEX_COMMIT" "$NXP_MWIFIEX_COMMIT"
rm -rf -- "$work/ps5-linux-patches"
mkdir -p -- "$work/ps5-linux-patches"
git -C "$work/ps5-linux-patches.git" archive "$PATCHES_COMMIT" linux.patch .config firmware |
  tar -xf - -C "$work/ps5-linux-patches"

log "Kernel builder ($platform)"
docker build --platform "$platform" \
  --build-arg "KERNEL_BUILDER_BASE=$builder_base" \
  --build-arg "KERNEL_BUILDER_APT_SNAPSHOT=$BUILDER_APT_SNAPSHOT" \
  -t "$builder" -f "$REPO/docker/kernel-builder/Dockerfile" "$REPO"

run_args=(--rm --platform "$platform" --name "$container"
  -v "$REPO:/repo:ro" -v "$volume:/src" -v "$out:/out")
[[ -z $jobs ]] || run_args+=(-e "JOBS=$jobs")

log "Kernel"
docker volume create "$volume" >/dev/null
docker run "${run_args[@]}" \
  -v "$work/linux.git:/in/linux.git:ro" \
  -v "$work/ps5-linux-patches:/ps5-linux-patches:ro" \
  --entrypoint /bin/bash "$builder" /repo/docker/kernel-builder/build-k73.sh

log "IW620 Wi-Fi modules"
docker run "${run_args[@]}" --network none \
  -v "$work/iw620:/in:ro" \
  --entrypoint /bin/bash "$builder" /repo/docker/kernel-builder/build-iw620-k73.sh

log "Done"
cat "$out/kernel/kernel-build-info.txt"
echo
echo "IW620 modules:"
cat "$out/ps5-iw620/SHA256SUMS"
echo
echo "Staged kernel: $out/staging"
echo "Next: sudo scripts/package-linux-ps5-k73.sh --kernel-dir $out"
