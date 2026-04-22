# shellcheck shell=bash
# Shared helpers for bin/run-{claude,codex,pi}. Sourced, not executed.
#
# Callers must set these before calling common_init:
#   TOOL       — "claude" | "codex" | "pi" (used in paths + labels)
#   USER_NAME  — container user login name (e.g. "sb", "codex")
#   USER_HOME  — absolute home path inside the container
#   IMAGE      — container image reference
#
# Optional caller input:
#   USER_GECOS — GECOS (display name) field in passwd-entry. Defaults to USER_NAME.
#
# After common_init the following are available to the caller:
#   ROOT, BASE, HASH, STAMP, NAME
#   CACHE_BASE, STATE_BASE
#   WORKSPACE_CACHE_DIR, WORKSPACE_STATE_DIR, WORKSPACE_UV_CACHE_DIR,
#   WORKSPACE_UV_PYTHON_DIR, WORKSPACE_VENV_DIR, WORKSPACE_PYTEST_CACHE_DIR
#   AUTH_MODE, REPO_MODE
#   COMMON_PODMAN_ARGS (all shared podman flags: base hardening, tty, gh
#                       auth passthrough, optional strict seccomp)

if [[ "${_RUN_COMMON_LOADED:-0}" == "1" ]]; then
  return 0
fi
_RUN_COMMON_LOADED=1

common_init() {
  : "${TOOL:?TOOL must be set before common_init}"
  : "${USER_NAME:?USER_NAME must be set before common_init}"
  : "${USER_HOME:?USER_HOME must be set before common_init}"
  : "${IMAGE:?IMAGE must be set before common_init}"
  : "${USER_GECOS:=$USER_NAME}"

  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    ROOT="$(git rev-parse --show-toplevel)"
  else
    if [[ "${AISB_ALLOW_NON_GIT_WORKSPACE:-0}" != "1" ]]; then
      echo "Error: ${TOOL} must be run from inside a git repository." >&2
      echo >&2
      echo "Agent wrappers mount the workspace read-write; refusing non-git parent directories." >&2
      echo "Run from a project repository, or set AISB_ALLOW_NON_GIT_WORKSPACE=1 intentionally." >&2
      exit 1
    fi
    ROOT="$PWD"
  fi
  ROOT="$(realpath "$ROOT")"
  common_check_workspace_root "$ROOT"

  BASE="$(basename "$ROOT")"
  BASE="${BASE//[^A-Za-z0-9._-]/_}"
  BASE="${BASE:0:48}"
  BASE="${BASE:-repo}"
  HASH="$(printf '%s' "$ROOT" | { sha1sum 2>/dev/null || shasum -a 1; } | awk '{print $1}' | cut -c1-10)"

  STAMP="$(date +%Y%m%d-%H%M%S)"
  NAME="${TOOL}-${BASE}-${HASH}-${STAMP}-$$"

  CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-podman"
  STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/claude-podman"

  WORKSPACE_CACHE_DIR="${STATE_BASE}/${TOOL}/${HASH}/cache"
  WORKSPACE_STATE_DIR="${STATE_BASE}/${TOOL}/${HASH}/state"
  WORKSPACE_UV_CACHE_DIR="${CACHE_BASE}/uv/${HASH}"
  WORKSPACE_UV_PYTHON_DIR="${STATE_BASE}/${TOOL}/${HASH}/uv-python"
  WORKSPACE_VENV_DIR="${STATE_BASE}/${TOOL}/${HASH}/venvs/${STAMP}-$$"
  WORKSPACE_PYTEST_CACHE_DIR="${STATE_BASE}/${TOOL}/${HASH}/pytest"

  mkdir -p \
    "$WORKSPACE_CACHE_DIR" \
    "$WORKSPACE_STATE_DIR" \
    "$WORKSPACE_UV_CACHE_DIR" \
    "$WORKSPACE_UV_PYTHON_DIR" \
    "$WORKSPACE_VENV_DIR" \
    "$WORKSPACE_PYTEST_CACHE_DIR"

  # Prune per-invocation venv dirs older than 7 days, scoped per tool so
  # tools don't blow away each other's caches.
  find "${STATE_BASE}/${TOOL}/${HASH}/venvs" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true

  local tool_upper tool_auth_var
  tool_upper="${TOOL^^}"
  tool_auth_var="${tool_upper}_AUTH_WRITE"
  if [[ "${AISB_AUTH_WRITE:-0}" == "1" || "${!tool_auth_var:-0}" == "1" ]]; then
    AUTH_MODE="rw"
    REPO_MODE="rw"
    if [[ "${AISB_AUTH_WRITE_KEEP_REPO_RW:-0}" != "1" ]]; then
      REPO_MODE="ro"
    fi
    echo "${TOOL}: auth-write mode (auth=rw, repo=$REPO_MODE)" >&2
  else
    AUTH_MODE="ro"
    REPO_MODE="rw"
  fi

  WORKSPACE_MOUNT_OPTS="${REPO_MODE},nosuid,nodev"
  if [[ "${AISB_RELABEL_WORKSPACE:-0}" == "1" ]]; then
    WORKSPACE_MOUNT_OPTS+=",z"
    echo "${TOOL}: workspace SELinux relabel enabled for $ROOT" >&2
  fi

  : "${AISB_MEMORY:=8g}"
  : "${AISB_CPUS:=4}"
  : "${AISB_PIDS:=1024}"

  _common_warn_memory

  local host_git_name host_git_email
  host_git_name="$(git config --get user.name 2>/dev/null || true)"
  host_git_email="$(git config --get user.email 2>/dev/null || true)"

  COMMON_PODMAN_ARGS=(
    --rm
    --pull=never
    --name "$NAME"
    --userns=keep-id
    --passwd-entry "${USER_NAME}:x:\$UID:\$GID:${USER_GECOS}:${USER_HOME}:/bin/bash"
    --cap-drop=all
    --security-opt no-new-privileges
    --read-only
    --memory="$AISB_MEMORY"
    --cpus="$AISB_CPUS"
    --pids-limit="$AISB_PIDS"
    --tmpfs "/tmp:rw,nosuid,nodev,size=512m"
    --tmpfs "${USER_HOME}:rw,nosuid,nodev,size=256m"
    --tmpfs "/uv-bin:rw,nosuid,nodev,size=128m"
    --tmpfs "/uv-tools:rw,nosuid,nodev,size=256m"
    --label "io.${TOOL}.repo=$ROOT"
    --label "io.${TOOL}.repo_hash=$HASH"
    --label "io.${TOOL}.session=$STAMP-$$"
    -e "HOME=${USER_HOME}"
    -e "TERM=${TERM:-xterm-256color}"
    -e "COLORTERM=${COLORTERM:-truecolor}"
    -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-$host_git_name}"
    -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-$host_git_email}"
    -e "GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$host_git_name}"
    -e "GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$host_git_email}"
    -e "XDG_CACHE_HOME=/aisb-${TOOL}/cache"
    -e "XDG_STATE_HOME=/aisb-${TOOL}/state"
    -e "UV_CACHE_DIR=/aisb-${TOOL}/uv-cache"
    -e "UV_PYTHON_INSTALL_DIR=/aisb-${TOOL}/uv-python"
    -e "UV_PROJECT_ENVIRONMENT=/aisb-${TOOL}/venv"
    -e "PYTEST_ADDOPTS=${PYTEST_ADDOPTS:-} -o cache_dir=/aisb-${TOOL}/pytest"
    -v "${ROOT}:${ROOT}:${WORKSPACE_MOUNT_OPTS}"
    -v "${WORKSPACE_CACHE_DIR}:/aisb-${TOOL}/cache:rw,nosuid,nodev,z"
    -v "${WORKSPACE_STATE_DIR}:/aisb-${TOOL}/state:rw,nosuid,nodev,z"
    -v "${WORKSPACE_UV_CACHE_DIR}:/aisb-${TOOL}/uv-cache:rw,nosuid,nodev,z"
    -v "${WORKSPACE_UV_PYTHON_DIR}:/aisb-${TOOL}/uv-python:rw,nosuid,nodev,z"
    -v "${WORKSPACE_VENV_DIR}:/aisb-${TOOL}/venv:rw,nosuid,nodev,Z"
    -v "${WORKSPACE_PYTEST_CACHE_DIR}:/aisb-${TOOL}/pytest:rw,nosuid,nodev,z"
    -w "$ROOT"
  )

  _common_append_tty
  _common_append_gh
  _common_append_seccomp
}

common_die_dangerous_root() {
  local root="$1"
  echo "Error: refusing to run ${TOOL} with dangerous workspace root: $root" >&2
  echo >&2
  echo "This wrapper bind-mounts the workspace into an agent container." >&2
  echo "Run it from a project directory or git repository instead." >&2
  echo "To override intentionally, set AISB_ALLOW_DANGEROUS_ROOT=1." >&2
  exit 1
}

common_check_workspace_root() {
  local root="$1"
  local home_real xdg_data containers_real dangerous
  dangerous=0

  home_real="$(realpath "$HOME" 2>/dev/null || printf '%s' "$HOME")"
  xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  containers_real="$(realpath "$xdg_data/containers" 2>/dev/null || true)"

  case "$root" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/Users)
      dangerous=1
      ;;
  esac

  if [[ "$root" == "$home_real" ]]; then
    dangerous=1
  fi

  if [[ -n "$containers_real" && ( "$root" == "$containers_real" || "$root" == "$containers_real"/* ) ]]; then
    dangerous=1
  fi

  if (( dangerous )); then
    if [[ "${AISB_ALLOW_DANGEROUS_ROOT:-0}" == "1" ]]; then
      echo "warn: AISB_ALLOW_DANGEROUS_ROOT=1; allowing workspace root '$root'" >&2
      return 0
    fi
    common_die_dangerous_root "$root"
  fi
}

_common_warn_memory() {
  [[ -r /proc/meminfo ]] || return 0
  [[ "$AISB_MEMORY" =~ ^([0-9]+)([bBkKmMgG]?)$ ]] || return 0
  local n="${BASH_REMATCH[1]}"
  local req_mem=""
  case "${BASH_REMATCH[2],,}" in
    ""|b) req_mem="$n" ;;
    k)    req_mem=$((n * 1024)) ;;
    m)    req_mem=$((n * 1024 * 1024)) ;;
    g)    req_mem=$((n * 1024 * 1024 * 1024)) ;;
  esac
  local avail_mem
  avail_mem="$(awk '/^MemAvailable:/{print $2*1024; exit}' /proc/meminfo)"
  if [[ -n "$req_mem" && -n "$avail_mem" ]] && (( req_mem > avail_mem )); then
    echo "warn: AISB_MEMORY=$AISB_MEMORY exceeds host MemAvailable (~$((avail_mem/1024/1024)) MiB); container may OOM" >&2
  fi
}

common_check_image() {
  if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "Error: Image '$IMAGE' not found. Build it first with:" >&2
    echo "  bin/build-containers ${TOOL}" >&2
    exit 1
  fi
}

_common_append_gh() {
  if [[ -n "${GH_TOKEN:-}" ]]; then
    COMMON_PODMAN_ARGS+=(-e "GH_TOKEN=$GH_TOKEN")
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    COMMON_PODMAN_ARGS+=(-e "GITHUB_TOKEN=$GITHUB_TOKEN")
  fi
  local gh_host_config="${XDG_CONFIG_HOME:-$HOME/.config}/gh"
  if [[ -d "$gh_host_config" ]]; then
    COMMON_PODMAN_ARGS+=(-v "${gh_host_config}:${USER_HOME}/.config/gh:${AUTH_MODE},nosuid,nodev,noexec,z")
  fi
}

_common_append_tty() {
  COMMON_PODMAN_ARGS+=(-i)
  if [[ -t 0 && -t 1 ]]; then
    COMMON_PODMAN_ARGS+=(-t)
  fi
}

_common_append_seccomp() {
  [[ "${AISB_STRICT_SECCOMP:-0}" == "1" ]] || return 0
  local lib_dir repo_root seccomp_profile
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  repo_root="$(dirname "$lib_dir")"
  seccomp_profile="${AISB_SECCOMP_PROFILE:-$repo_root/seccomp-strict.json}"
  if [[ -r "$seccomp_profile" ]]; then
    COMMON_PODMAN_ARGS+=(--security-opt "seccomp=$seccomp_profile")
  else
    echo "warn: AISB_STRICT_SECCOMP=1 but $seccomp_profile is not readable; using default" >&2
  fi
}
