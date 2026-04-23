#!/bin/sh
set -eu

if [ "$#" -eq 0 ]; then
  echo "error: expected at least one Python tool name" >&2
  exit 2
fi

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh \
    | env UV_INSTALL_DIR=/usr/local/bin UV_UNMANAGED_INSTALL=1 sh
fi

export UV_TOOL_DIR=/opt/uv-tools
export UV_TOOL_BIN_DIR=/usr/local/bin
export UV_CACHE_DIR=/tmp/uv-cache

mkdir -p "$UV_TOOL_DIR"

for tool in "$@"; do
  uv tool install "$tool"
done

rm -rf "$UV_CACHE_DIR"
