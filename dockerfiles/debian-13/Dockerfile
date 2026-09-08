ARG BASE_IMAGE=debian:13
FROM ${BASE_IMAGE} AS build

RUN printf 'deb http://deb.debian.org/debian trixie-backports main\n' > /etc/apt/sources.list.d/trixie-backports.list \
 && printf 'Package: *\nPin: release a=trixie-backports\nPin-Priority: 990\n' > /etc/apt/preferences.d/trixie-backports

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        bash \
        build-essential \
        ca-certificates \
        asciidoctor \
        ccache \
        clang \
        cmake \
        elfutils \
        gcc \
        libhiredis-dev \
        libzstd-dev \
        pandoc \
        python3 \
        redis-server \
        redis-tools \
 && apt-get dist-upgrade -y \
 && rm -rf /var/lib/apt/lists/*

# Redirect all compilers to ccache.
RUN for t in gcc g++ cc c++ clang clang++; do ln -vs /usr/bin/ccache /usr/local/bin/$t; done
