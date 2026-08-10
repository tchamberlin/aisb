#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1"
  local expected="$2"
  grep -Fqx -- "$expected" "$file" \
    || fail "$file does not contain: $expected"
}

mkdir -p "$TEST_TMP/bin"

cat > "$TEST_TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "$url" in
  https://pypi.org/pypi/ruff/json) printf '%s\n' '{"info":{"version":"9.8.1"}}' ;;
  https://pypi.org/pypi/ty/json) printf '%s\n' '{"info":{"version":"8.7.2"}}' ;;
  https://pypi.org/pypi/prek/json) printf '%s\n' '{"info":{"version":"7.6.3"}}' ;;
  *) echo "unexpected curl URL: $url" >&2; exit 1 ;;
esac
EOF

cat > "$TEST_TMP/bin/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "view @anthropic-ai/claude-code version" ]]; then
  printf '%s\n' '6.5.4'
else
  echo "unexpected npm arguments: $*" >&2
  exit 1
fi
EOF

cat > "$TEST_TMP/bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  image)
    case "${2:-}" in
      exists) exit 0 ;;
      inspect)
        if [[ "$*" == *'{{.Id}}'* ]]; then
          printf '%s\n' 'sha256:test-base'
        fi
        exit 0
        ;;
    esac
    ;;
  build)
    printf '%s\n' "${@:2}" > "$AISB_TEST_PODMAN_LOG"
    exit 0
    ;;
esac
echo "unexpected podman arguments: $*" >&2
exit 1
EOF

chmod +x "$TEST_TMP/bin/curl" "$TEST_TMP/bin/npm" "$TEST_TMP/bin/podman"

export PATH="$TEST_TMP/bin:$PATH"
export AISB_WORKSPACE="$ROOT"

for flavor in base claude; do
  log="$TEST_TMP/podman-$flavor.log"
  export AISB_TEST_PODMAN_LOG="$log"
  "$ROOT/bin/build-containers" "$flavor" > "$TEST_TMP/build-$flavor.out" 2>&1
  assert_contains "$log" "RUFF_VERSION=9.8.1"
  assert_contains "$log" "TY_VERSION=8.7.2"
  assert_contains "$log" "PREK_VERSION=7.6.3"
done

for flavor in base claude codex pi herdr; do
  containerfile="$ROOT/Containerfile.$flavor"
  install_line="$(grep -n 'aisb-install-agent-python-tools.*ruff==' "$containerfile" | cut -d: -f1)"
  [[ -n "$install_line" ]] || fail "$containerfile does not install pinned Python tools"

  for arg in RUFF_VERSION TY_VERSION PREK_VERSION; do
    arg_line="$(grep -n "^ARG $arg=" "$containerfile" | cut -d: -f1)"
    [[ -n "$arg_line" ]] || fail "$containerfile does not declare $arg"
    (( arg_line < install_line )) \
      || fail "$containerfile declares $arg after the Python tool install layer"
  done
done

echo "PASS: Python tool versions are pinned build inputs"
