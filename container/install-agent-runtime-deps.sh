#!/bin/sh
set -eu

if command -v microdnf >/dev/null 2>&1; then
  microdnf install -y --setopt=install_weak_deps=0 \
    ca-certificates curl git openssh-clients bash which \
    ripgrep less jq \
    unzip zip tar xz gzip \
    patch diffutils findutils coreutils \
    procps-ng iproute \
  && microdnf clean all \
  && rm -rf /var/cache/dnf /var/cache/yum
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y --setopt=install_weak_deps=0 \
    ca-certificates curl git openssh-clients bash which \
    ripgrep less jq \
    unzip zip tar xz gzip \
    patch diffutils findutils coreutils \
    procps-ng iproute \
  && dnf clean all \
  && rm -rf /var/cache/dnf /var/cache/yum
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates curl git openssh-client bash \
    ripgrep less jq \
    unzip zip tar xz-utils gzip \
    patch diffutils findutils coreutils \
    procps iproute2 \
  && rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache \
    ca-certificates curl git openssh-client bash which \
    ripgrep less jq \
    unzip zip tar xz gzip \
    patch diffutils findutils coreutils \
    procps iproute2
else
  echo "error: no supported package manager found for agent runtime dependencies" >&2
  exit 127
fi
