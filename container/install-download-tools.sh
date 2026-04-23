#!/bin/sh
set -eu

missing=""
for cmd in curl sha256sum tar xz; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing="$missing $cmd"
  fi
done
if [ ! -e /etc/ssl/certs/ca-certificates.crt ] && [ ! -d /etc/ssl/certs ]; then
  missing="$missing ca-certificates"
fi

if [ -z "$missing" ]; then
  exit 0
fi

if command -v microdnf >/dev/null 2>&1; then
  microdnf install -y --setopt=install_weak_deps=0 ca-certificates curl coreutils tar xz \
    && microdnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y --setopt=install_weak_deps=0 ca-certificates curl coreutils tar xz \
    && dnf clean all \
    && rm -rf /var/cache/dnf /var/cache/yum
elif command -v apt-get >/dev/null 2>&1; then
  apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl coreutils tar xz-utils \
    && rm -rf /var/lib/apt/lists/*
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache ca-certificates curl coreutils tar xz
else
  echo "error: missing download tools and no supported package manager is available" >&2
  echo "missing tools:$missing" >&2
  exit 127
fi
