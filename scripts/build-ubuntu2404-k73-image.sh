#!/usr/bin/env bash
# Build the Ubuntu 24.04 image on Linux 7.3.0 (distros/ubuntu2404-k73) for
# regular PS5 consoles on firmware 11.xx and 13.xx.
#
# Inputs are the linux-ps5 .deb from scripts/package-linux-ps5-k73-deb.sh and
# the k73 kernel bundle it was made from (for the IW620 modules). The build
# runs docker/image-builder/entrypoint.sh unchanged with
# DISTRO=ubuntu2404-k73: distrobuilder makes the root filesystem from
# distros/ubuntu2404-k73/image.yaml on a throwaway Docker volume, then the
# entrypoint makes the GPT image (FAT boot partition 1-500 MiB, ext4 root
# LABEL=ubuntu2404-k73 after it), moves /boot/efi to the FAT partition and
# adds cmdline.txt, vram.txt and kexec.sh.
#
# Usage: sudo scripts/build-ubuntu2404-k73-image.sh --deb DEB
#          [--kernel-dir DIR] [--out-dir DIR] [--img-size MIB]
#
# The image is OUT-DIR/ps5-ubuntu2404-k73.img (default output/). Check it
# with scripts/verify-ubuntu2404-k73-image.sh. Needs Linux with Docker and
# the docker buildx plugin; GitHub Actions uses an x86_64 runner.
set -euo pipefail
export LC_ALL=C

DISTRO=ubuntu2404-k73
DEB_VERSION=7.3.0-7
DEFAULT_IMG_SIZE=12000

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n== %s\n' "$*"; }
usage() {
  echo "Usage: sudo $0 --deb DEB [--kernel-dir DIR] [--out-dir DIR] [--img-size MIB]"
}

deb=
kernel_dir=$REPO/linux-bin/cachyos1160-k73
out_dir=$REPO/output
img_size=$DEFAULT_IMG_SIZE
while (($#)); do
  case $1 in
    --deb) (($# >= 2)) || die "--deb needs a file"; deb=$2; shift 2 ;;
    --kernel-dir) (($# >= 2)) || die "--kernel-dir needs a directory"; kernel_dir=$2; shift 2 ;;
    --out-dir) (($# >= 2)) || die "--out-dir needs a directory"; out_dir=$2; shift 2 ;;
    --img-size) (($# >= 2)) || die "--img-size needs a size in MiB"; img_size=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ -n $deb ]] || { usage >&2; exit 2; }
((EUID == 0)) || die "run as root (the image is assembled in a privileged container)"
[[ $img_size =~ ^[1-9][0-9]{3,5}$ ]] || die "--img-size must be a size in MiB"
for cmd in docker dpkg-deb sha256sum; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

deb=$(realpath -e -- "$deb")
kernel_dir=$(realpath -e -- "$kernel_dir")
[[ $(dpkg-deb -f "$deb" Package) == linux-ps5 ]] || die "$deb is not linux-ps5"
[[ $(dpkg-deb -f "$deb" Version) == "$DEB_VERSION" ]] || die "$deb is not version $DEB_VERSION"
if [[ -f $deb.sha256 ]]; then
  (cd -- "${deb%/*}" && sha256sum -c --status -- "${deb##*/}.sha256") ||
    die "$deb does not match ${deb##*/}.sha256"
fi
iw620=$kernel_dir/ps5-iw620
(cd -- "$iw620" && sha256sum -c SHA256SUMS) || die "$iw620 does not match its SHA256SUMS"
[[ -f $iw620/mlan.ko && -f $iw620/moal.ko ]] || die "$iw620 has no mlan.ko or moal.ko"
for f in image.yaml setup-rootfs.sh cmdline.txt nm-dns.conf grow-rootfs grow-rootfs.service; do
  [[ -f $REPO/distros/$DISTRO/$f ]] || die "distros/$DISTRO/$f is missing"
done
mkdir -p -- "$out_dir"
out_dir=$(realpath -e -- "$out_dir")
image=$out_dir/ps5-$DISTRO.img
rm -f -- "$image" "$out_dir/.ps5-$DISTRO.img.tmp"

# Only these files go into the container: the one .deb, and the two modules
# with their checksums.
stage=$(mktemp -d)
volume=ps5-image-chroot-$DISTRO-$$-$RANDOM
container=ps5-image-$DISTRO-$$
cleanup() {
  local rc=$?
  trap - EXIT
  docker kill "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
  rm -rf -- "$stage"
  ((rc == 0)) || echo "Image build failed (exit $rc)" >&2
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$stage/debs" "$stage/ps5-iw620"
cp -- "$deb" "$stage/debs/"
cp -- "$iw620/mlan.ko" "$iw620/moal.ko" "$iw620/SHA256SUMS" "$stage/ps5-iw620/"
cache_dir=$REPO/work/cache-$DISTRO
mkdir -p -- "$cache_dir"

log "Image builder"
docker build --platform linux/amd64 --pull \
  -t ps5-image-builder -f "$REPO/docker/image-builder/Dockerfile" "$REPO"

log "Root filesystem and image (${img_size} MiB)"
# The root filesystem has to keep Linux owners, modes, links and device
# nodes, so it is put together on a Docker volume, not a host folder.
docker volume inspect "$volume" >/dev/null 2>&1 && die "Docker volume $volume already exists"
docker volume create "$volume" >/dev/null
docker run --rm --privileged --platform linux/amd64 --name "$container" \
  -v "$REPO:/repo:ro" \
  -v "$stage/debs:/kernel-debs:ro" \
  -v "$stage/ps5-iw620:/ps5-iw620:ro" \
  -v "$out_dir:/output" \
  -v "$volume:/build/chroot" \
  -v "$cache_dir:/build/cache" \
  -e DISTRO="$DISTRO" \
  -e IMG_SIZE="$img_size" \
  -e SKIP_CHROOT=false \
  ps5-image-builder

[[ -f $image ]] || die "the build did not produce $image"
size=$(stat -c %s -- "$image")
((size == img_size * 1024 * 1024)) || die "$image is $size bytes, expected $((img_size * 1024 * 1024))"
log "Done"
echo "$image: $size bytes"
echo "Next: sudo scripts/verify-ubuntu2404-k73-image.sh --image $image --kernel-dir $kernel_dir --deb $deb"
