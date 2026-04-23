#!/bin/sh
set -eu

tool="${1:?tool name required}"
shift

missing=""
for cmd in "$@"; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing="$missing $cmd"
  fi
done

if [ -z "$missing" ]; then
  exit 0
fi

echo "error: base image is missing prerequisites for $tool:$missing" >&2
echo "Use an AISB base image or install these tools in the repo base Containerfile." >&2
exit 127
