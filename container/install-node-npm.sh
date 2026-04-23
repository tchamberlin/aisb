#!/bin/sh
set -eu

if command -v npm >/dev/null 2>&1; then
  exit 0
fi

node_version="${NODE_VERSION:-24.13.1}"
arch="$(uname -m)"

if [ "$node_version" != "24.13.1" ]; then
  echo "error: unsupported NODE_VERSION for pinned installer: $node_version" >&2
  exit 1
fi

case "$arch" in
  x86_64|amd64)
    node_arch="linux-x64"
    node_sha256="30215f90ea3cd04dfbc06e762c021393fa173a1d392974298bbc871a8e461089"
    ;;
  *)
    echo "error: no pinned Node.js tarball checksum for architecture: $arch" >&2
    exit 1
    ;;
esac

ensure_download_tools() {
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
    return 0
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
    echo "error: npm not found and no supported package manager is available to install download tools" >&2
    echo "missing tools:$missing" >&2
    exit 127
  fi
}

ensure_download_tools

tarball="node-v${node_version}-${node_arch}.tar.xz"
url="https://nodejs.org/dist/v${node_version}/${tarball}"

curl -fsSLO "$url"
echo "${node_sha256}  ${tarball}" | sha256sum -c -
tar -xJ --strip-components=1 -C /usr/local -f "$tarball"
rm "$tarball"

command -v npm >/dev/null 2>&1
