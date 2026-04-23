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

if command -v aisb-install-download-tools >/dev/null 2>&1; then
  aisb-install-download-tools
elif [ -x /usr/local/bin/aisb-install-download-tools ]; then
  /usr/local/bin/aisb-install-download-tools
else
  echo "error: aisb-install-download-tools is required to install Node.js" >&2
  exit 127
fi

tarball="node-v${node_version}-${node_arch}.tar.xz"
url="https://nodejs.org/dist/v${node_version}/${tarball}"

curl -fsSLO "$url"
echo "${node_sha256}  ${tarball}" | sha256sum -c -
tar -xJ --strip-components=1 -C /usr/local -f "$tarball"
rm "$tarball"

command -v npm >/dev/null 2>&1
