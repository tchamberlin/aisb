#!/usr/bin/env bash
set -euo pipefail

# Install host-side commands for AISB.
# Creates symlinks in ~/.local/bin so the host transparently invokes the
# wrappers and maintenance commands in bin/.

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

install_link() {
  local name="$1"
  local target="$2"
  local link="$BIN_DIR/$name"

  if [[ ! -x "$target" ]]; then
    echo "warn: $target is missing or not executable; skipping $name" >&2
    return 0
  fi

  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "refuse: $link exists and is not a symlink; skipping $name" >&2
    return 0
  fi

  ln -sfn "$target" "$link"
  echo "linked: $link -> $target"
}

AGENTS=(claude codex pi sb)

for agent in "${AGENTS[@]}"; do
  install_link "$agent" "$REPO/bin/run-$agent"
done

install_link aisb-build "$REPO/bin/build-containers"

case ":$PATH:" in
  *":$BIN_DIR:"*)
    ;;
  *)
    echo
    echo "note: $BIN_DIR is not on your PATH."
    echo "      add this to your shell rc:"
    echo "          export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac
