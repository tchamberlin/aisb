# Refactor `bin/run-sb` onto `bin/_run-common.sh`

Follow-up to `refactor-run-wrappers.md`. Fold `run-sb` into the shared
library where it overlaps, leave genuinely different bits inline.

## Goal

Cut `run-sb`'s duplicated helpers (memory warning, seccomp, GH passthrough,
TTY check, venv prune, repo-id derivation) and reuse `_run-common.sh`,
while preserving `run-sb`'s distinct posture: base image, generic label
namespace, network toggle, no auth semantics, `/tmp`-rooted XDG, writable
tmpfs mode.

## Scope of fixes folded in

### 1. Pick up fix #6 (both-TTY check)

`run-sb` currently passes `-t` when `-t 0` alone. Switch to
`common_build_tty_flags` so `-t` is added only when both stdin and stdout
are TTYs.

**Behavior change:** `run-sb foo | tee log` previously got `-it`; now gets
`-i` only. Matches the other three wrappers. Acceptable.

### 2. Pick up fix #2 (per-tool venv scoping)

Move state from:

- `${STATE_BASE}/uv-python/${HASH}`
- `${STATE_BASE}/venvs/${HASH}/${STAMP}-$$`

to:

- `${STATE_BASE}/sb/${HASH}/uv-python`
- `${STATE_BASE}/sb/${HASH}/venvs/${STAMP}-$$`

Shared uv download cache stays at `${CACHE_BASE}/uv/${HASH}` (cross-tool
compatible, no collision).

Orphans old `${STATE_BASE}/uv-python/${HASH}` and `${STATE_BASE}/venvs`
dirs. Same migration concern as fix #2 in the first plan — acceptable.

### 3. Pick up fix #4 (image preflight)

Call `common_check_image` after `common_init` so a missing base image
produces the `bin/build-containers` hint instead of podman's raw error.

## Intentionally not changed

- **Image:** still `${SB_IMAGE:-localhost/aisb-base:latest}`.
- **Label namespace:** `io.aisb.*` (run-sb is generic, not tool-scoped).
- **AISB_NO_NETWORK:** still honored — `run-sb` is the only wrapper that
  toggles network off.
- **tmpfs mode=1777:** kept (run-sb's generic sandbox is used for
  untrusted code that may want a world-writable tmp).
- **XDG targets at `/tmp/xdg-*`:** kept — run-sb has no per-repo config
  state to persist.
- **`MPLCONFIGDIR=/tmp/mpl`:** kept (matplotlib convenience).
- **Extra env vars** (`GROQ_API_KEY`, `HF_TOKEN`, `QWEN_MODEL`): kept.
- **No `/aisb-sb/*` layout:** run-sb doesn't have the XDG persistence
  pattern the three wrappers adopted (fix #3). If it ever needs one,
  that's a separate change.
- **No `noexec` on `/venv` or `/uv-python`:** venvs hold executable
  console-script wrappers and Python binaries. Fix #5 doesn't cleanly
  apply.
- **No `AUTH_MODE` semantics:** GH config stays `ro`.

## Library changes

Small internal refactor so `run-sb` can use the helpers without paying
for the three-wrapper-specific `common_init`:

1. Split out `common_compute_repo_id` from `common_init` — populates
   `ROOT`, `BASE`, `HASH`, `STAMP`, `NAME` using `$TOOL` as the name
   prefix. `common_init` then calls it as its first step.
2. Promote `_common_warn_memory` → `common_warn_memory` (public; no
   behavior change, just the underscore).
3. `common_build_gh_opts` already uses `$USER_HOME` and `$AUTH_MODE` —
   no change. `run-sb` sets `USER_HOME=/home/sb` and `AUTH_MODE=ro`
   before calling it.

No change to `common_check_image`, `common_build_tty_flags`,
`common_build_seccomp_opts`, or `COMMON_PODMAN_ARGS`.

## Wrapper shape after refactor

Target: ~70 lines (from 155). Skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TOOL="sb"
USER_NAME="sb"
USER_HOME="/home/sb"
AUTH_MODE="ro"   # no auth files; only used by common_build_gh_opts
IMAGE="${SB_IMAGE:-localhost/aisb-base:latest}"

source "$SCRIPT_DIR/_run-common.sh"
common_compute_repo_id
common_check_image

# Per-tool state (fix #2 parity)
UV_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-podman/uv/${HASH}"
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-podman"
UV_PYTHON_DIR="${STATE_BASE}/sb/${HASH}/uv-python"
VENV_DIR="${STATE_BASE}/sb/${HASH}/venvs/${STAMP}-$$"
mkdir -p "$UV_CACHE" "$UV_PYTHON_DIR" "$VENV_DIR"
find "${STATE_BASE}/sb/${HASH}/venvs" -mindepth 1 -maxdepth 1 -type d \
  -mtime +7 -exec rm -rf {} + 2>/dev/null || true

: "${AISB_MEMORY:=8g}"; : "${AISB_CPUS:=4}"; : "${AISB_PIDS:=1024}"
common_warn_memory

NET_OPTS=()
[[ "${AISB_NO_NETWORK:-0}" == "1" ]] && NET_OPTS+=(--network=none)

ENV_OPTS=()
for var in ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_API_KEY \
           OPENROUTER_API_KEY TOGETHER_API_KEY GROQ_API_KEY \
           HF_TOKEN QWEN_MODEL VISUAL EDITOR; do
  [[ -n "${!var:-}" ]] && ENV_OPTS+=(-e "${var}=${!var}")
done

GH_OPTS=();      common_build_gh_opts GH_OPTS
TTY_FLAGS=();    common_build_tty_flags TTY_FLAGS
SECCOMP_OPTS=(); common_build_seccomp_opts SECCOMP_OPTS

(( $# == 0 )) && set -- bash

exec podman run --rm "${TTY_FLAGS[@]}" --pull=never \
  --name "$NAME" --userns=keep-id \
  --passwd-entry "sb:x:\$UID:\$GID:sb:/home/sb:/bin/bash" \
  --cap-drop=all --security-opt no-new-privileges --read-only \
  --memory="$AISB_MEMORY" --cpus="$AISB_CPUS" --pids-limit="$AISB_PIDS" \
  "${NET_OPTS[@]}" "${SECCOMP_OPTS[@]}" \
  --tmpfs /tmp:rw,nosuid,nodev,size=512m,mode=1777 \
  --tmpfs /home/sb:rw,nosuid,nodev,size=256m,mode=1777 \
  --tmpfs /uv-bin:rw,nosuid,nodev,size=128m,mode=1777 \
  --tmpfs /uv-tools:rw,nosuid,nodev,size=256m,mode=1777 \
  --label "io.aisb.repo=$ROOT" \
  --label "io.aisb.repo_hash=$HASH" \
  --label "io.aisb.session=$STAMP-$$" \
  -e HOME=/home/sb -e TERM="${TERM:-xterm-256color}" \
  -e COLORTERM="${COLORTERM:-truecolor}" \
  -e UV_CACHE_DIR=/uv-cache -e UV_PYTHON_INSTALL_DIR=/uv-python \
  -e UV_PROJECT_ENVIRONMENT=/venv \
  -e MPLCONFIGDIR=/tmp/mpl \
  -e XDG_CONFIG_HOME=/tmp/xdg-config -e XDG_CACHE_HOME=/tmp/xdg-cache \
  "${ENV_OPTS[@]}" "${GH_OPTS[@]}" \
  -v "$ROOT":"$ROOT":rw,nosuid,nodev,z \
  -v "$UV_CACHE":/uv-cache:rw,nosuid,nodev,z \
  -v "$UV_PYTHON_DIR":/uv-python:rw,nosuid,nodev,z \
  -v "$VENV_DIR":/venv:rw,nosuid,nodev,Z \
  -w "$ROOT" "$IMAGE" "$@"
```

`run-sb` deliberately does **not** use `COMMON_PODMAN_ARGS` — its flag
set diverges enough (tmpfs mode, label namespace, XDG targets, network
toggle, lack of `/aisb-<tool>/*` layout) that assembling inline is
clearer than parameterizing the common array.

## Implementation order

1. Library refactor: split `common_compute_repo_id` out of `common_init`;
   rename `_common_warn_memory` → `common_warn_memory`. Verify the three
   existing wrappers still work (no behavior change expected).
2. Rewrite `run-sb`. Smoke test:
   - `run-sb echo hi` — arg-less and arg-ful invocations.
   - `echo hi | run-sb cat` — verifies fix #6.
   - `AISB_NO_NETWORK=1 run-sb curl -m 2 https://example.com` — should
     fail to resolve.
   - `AISB_STRICT_SECCOMP=1 run-sb uv --version` — verifies profile
     mount.

## Risks

- **Existing `${STATE_BASE}/uv-python` / `${STATE_BASE}/venvs` dirs
  become orphaned.** One-time data loss. Document in commit.
- **`-t` no longer granted when only stdout is piped.** Callers that
  depend on TTY detection for stdin-driven commands are fine; those that
  wanted a PTY for colored output piped to a pager lose it. Acceptable —
  matches the other three wrappers.
- **Splitting `common_init` risks breaking the three existing wrappers.**
  Mitigated by step 1 being a pure extraction (no behavior change).

## Files touched

- `bin/_run-common.sh` (extract `common_compute_repo_id`, rename memory
  helper)
- `bin/run-sb` (rewrite)

No changes to `run-claude`, `run-codex`, `run-pi` (they keep calling
`common_init`, which now delegates to the extracted helper).
