#!/usr/bin/env bash
set -euo pipefail

# Install host-side aliases for the containerized agents.
# Creates symlinks in ~/.local/bin so `claude`, `codex`, `pi`, and `sb` on the
# host transparently invoke the run-* wrappers in bin/.

REPO="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/.local/bin"

mkdir -p "$BIN_DIR"

AGENTS=(claude codex pi sb)

for agent in "${AGENTS[@]}"; do
  target="$REPO/bin/run-$agent"
  link="$BIN_DIR/$agent"

  if [[ ! -x "$target" ]]; then
    echo "warn: $target is missing or not executable; skipping $agent" >&2
    continue
  fi

  if [[ -e "$link" && ! -L "$link" ]]; then
    echo "refuse: $link exists and is not a symlink; skipping $agent" >&2
    continue
  fi

  ln -sfn "$target" "$link"
  echo "linked: $link -> $target"
done

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
