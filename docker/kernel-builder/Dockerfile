ARG KERNEL_BUILDER_BASE=debian:trixie
FROM ${KERNEL_BUILDER_BASE}

ARG KERNEL_BUILDER_APT_SNAPSHOT=
ENV DEBIAN_FRONTEND=noninteractive

RUN if [ -n "$KERNEL_BUILDER_APT_SNAPSHOT" ]; then \
        sed -i \
            -e "s|^URIs: http://deb.debian.org/debian$|URIs: http://snapshot.debian.org/archive/debian/$KERNEL_BUILDER_APT_SNAPSHOT|" \
            -e "s|^URIs: http://deb.debian.org/debian-security$|URIs: http://snapshot.debian.org/archive/debian-security/$KERNEL_BUILDER_APT_SNAPSHOT|" \
            /etc/apt/sources.list.d/debian.sources; \
        printf '%s\n' \
            'Acquire::Check-Valid-Until "false";' \
            'Acquire::Retries "5";' \
            > /etc/apt/apt.conf.d/99snapshot; \
    fi \
    && dpkg --add-architecture amd64 \
    && apt-get update && apt-get install -y --no-install-recommends \
    build-essential bc bison dwarves flex kmod cpio gawk pkg-config \
    libdw-dev libelf-dev libssl-dev zlib1g-dev \
    libdw-dev:amd64 libelf-dev:amd64 zlib1g-dev:amd64 \
    python3 rsync dpkg-dev debhelper zstd \
    perl git ca-certificates xz-utils ccache \
    crossbuild-essential-amd64 \
    && rm -rf /var/lib/apt/lists/*

ENV ARCH=x86_64
ENV CROSS_COMPILE=x86_64-linux-gnu-
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/ccache

WORKDIR /src

# Kernel source is mounted at /src. The exact Ubuntu 24.04 build stages it on
# Docker's Linux filesystem to avoid host file-sharing and clock-skew races.
# Build artifacts are staged to /out/staging

COPY docker/kernel-builder/build.sh /build.sh
COPY docker/kernel-builder/build-iw620.sh /build-iw620.sh
COPY docker/kernel-builder/package-deb.sh /package-deb.sh
COPY docker/kernel-builder/repro-date /run16-repro-bin/date
RUN chmod +x /build.sh /build-iw620.sh /package-deb.sh /run16-repro-bin/date

CMD ["/build.sh"]
