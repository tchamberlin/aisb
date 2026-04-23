# shellcheck shell=bash
# Shared helpers for bin/run-{claude,codex,pi}. Sourced, not executed.
#
# Callers must set these before calling common_init:
#   TOOL       — "claude" | "codex" | "pi" (used in paths + labels)
#   USER_NAME  — container user login name (e.g. "sb", "codex")
#   USER_HOME  — absolute home path inside the container
#
# After common_init the following are available to the caller:
#   ROOT, BASE, HASH, STAMP, NAME
#   CACHE_BASE, STATE_BASE
#   WORKSPACE_CACHE_DIR, WORKSPACE_STATE_DIR, WORKSPACE_UV_CACHE_DIR,
#   WORKSPACE_UV_PYTHON_DIR, WORKSPACE_VENV_DIR, WORKSPACE_PYTEST_CACHE_DIR,
#   WORKSPACE_TMP_DIR
#   AUTH_MODE, REPO_MODE
#   COMMON_PODMAN_ARGS (all shared podman flags: base hardening, tty, gh
#                       auth passthrough, optional strict seccomp)

if [[ "${_RUN_COMMON_LOADED:-0}" == "1" ]]; then
  return 0
fi
_RUN_COMMON_LOADED=1

_AISB_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/_repo-config.sh
source "$_AISB_COMMON_DIR/_repo-config.sh"

# shellcheck disable=SC2153 # TOOL is set by wrappers before common_init.
common_log_startup() {
  [[ "${AISB_QUIET:-0}" == "1" ]] && return 0

  echo "[aisb:${TOOL}] workspace: $ROOT (hash=$HASH)" >&2
  echo "[aisb:${TOOL}] repo config: $(aisb_repo_config_summary)" >&2
  echo "[aisb:${TOOL}] image: $IMAGE ($(aisb_tool_image_source_summary "$TOOL"))" >&2
  echo "[aisb:${TOOL}] limits: memory=$AISB_MEMORY cpus=$AISB_CPUS pids=$AISB_PIDS" >&2

  [[ "${AISB_DEBUG:-0}" == "1" ]] || return 0

  echo "[aisb:${TOOL}:debug] container name: $NAME" >&2
  echo "[aisb:${TOOL}:debug] workspace mount: $ROOT -> $ROOT ($WORKSPACE_MOUNT_OPTS)" >&2
  echo "[aisb:${TOOL}:debug] auth/repo mode: auth=$AUTH_MODE repo=$REPO_MODE" >&2
  echo "[aisb:${TOOL}:debug] mount /tmp: $WORKSPACE_TMP_DIR -> /tmp (bind rw,nosuid,nodev; host filesystem limit)" >&2
  echo "[aisb:${TOOL}:debug] mount ${USER_HOME}: tmpfs size=256m rw,nosuid,nodev" >&2
  echo "[aisb:${TOOL}:debug] mount /uv-bin: tmpfs size=128m rw,nosuid,nodev" >&2
  echo "[aisb:${TOOL}:debug] mount /uv-tools: tmpfs size=256m rw,nosuid,nodev" >&2
  echo "[aisb:${TOOL}:debug] mount cache: $WORKSPACE_CACHE_DIR -> /aisb-${TOOL}/cache (bind rw,nosuid,nodev)" >&2
  echo "[aisb:${TOOL}:debug] mount state: $WORKSPACE_STATE_DIR -> /aisb-${TOOL}/state (bind rw,nosuid,nodev)" >&2
  echo "[aisb:${TOOL}:debug] mount uv cache: $WORKSPACE_UV_CACHE_DIR -> /aisb-${TOOL}/uv-cache (bind rw,nosuid,nodev)" >&2
  echo "[aisb:${TOOL}:debug] mount uv python: $WORKSPACE_UV_PYTHON_DIR -> /aisb-${TOOL}/uv-python (bind rw,nosuid,nodev)" >&2
  echo "[aisb:${TOOL}:debug] mount venv: $WORKSPACE_VENV_DIR -> /aisb-${TOOL}/venv (bind rw,nosuid,nodev)" >&2
  echo "[aisb:${TOOL}:debug] mount pytest cache: $WORKSPACE_PYTEST_CACHE_DIR -> /aisb-${TOOL}/pytest (bind rw,nosuid,nodev)" >&2

  if [[ "${AISB_RELABEL_WORKSPACE:-0}" == "1" ]]; then
    echo "[aisb:${TOOL}:debug] workspace relabel: enabled" >&2
  else
    echo "[aisb:${TOOL}:debug] workspace relabel: disabled" >&2
  fi

  echo "[aisb:${TOOL}:debug] seccomp: ${COMMON_SECCOMP_SUMMARY:-podman default}" >&2

  if [[ -n "${GH_TOKEN:-}" ]]; then
    echo "[aisb:${TOOL}:debug] gh auth: GH_TOKEN env" >&2
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "[aisb:${TOOL}:debug] gh auth: GITHUB_TOKEN env" >&2
  elif [[ -d "${XDG_CONFIG_HOME:-$HOME/.config}/gh" ]]; then
    echo "[aisb:${TOOL}:debug] gh auth: mounted ${XDG_CONFIG_HOME:-$HOME/.config}/gh" >&2
  else
    echo "[aisb:${TOOL}:debug] gh auth: none detected" >&2
  fi
}

common_init() {
  : "${TOOL:?TOOL must be set before common_init}"
  : "${USER_NAME:?USER_NAME must be set before common_init}"
  : "${USER_HOME:?USER_HOME must be set before common_init}"

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

  BASE="$(aisb_workspace_base "$ROOT")"
  HASH="$(aisb_sha1_10 "$ROOT")"
  aisb_load_repo_env "$ROOT"
  IMAGE="$(aisb_resolve_tool_image "$TOOL" "$HASH")"

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
  WORKSPACE_TMP_DIR="${STATE_BASE}/${TOOL}/${HASH}/tmp/${STAMP}-$$"

  common_check_workspace_bind_paths

  mkdir -p \
    "$WORKSPACE_CACHE_DIR" \
    "$WORKSPACE_STATE_DIR" \
    "$WORKSPACE_UV_CACHE_DIR" \
    "$WORKSPACE_UV_PYTHON_DIR" \
    "$WORKSPACE_VENV_DIR" \
    "$WORKSPACE_PYTEST_CACHE_DIR" \
    "$WORKSPACE_TMP_DIR"
  chmod 1777 "$WORKSPACE_TMP_DIR"

  common_prune_old_dirs "${STATE_BASE}/${TOOL}/${HASH}/venvs" "$STATE_BASE" -mtime +7
  common_prune_old_dirs "${STATE_BASE}/${TOOL}/${HASH}/tmp" "$STATE_BASE" -mmin +1440

  local tool_upper tool_auth_var
  tool_upper="${TOOL^^}"
  tool_auth_var="${tool_upper}_AUTH_WRITE"
  if [[ "${AISB_AUTH_WRITE:-0}" == "1" || "${!tool_auth_var:-0}" == "1" ]]; then
    AUTH_MODE="rw"
    REPO_MODE="rw"
    if [[ "${AISB_AUTH_WRITE_KEEP_REPO_RW:-0}" != "1" ]]; then
      REPO_MODE="ro"
    fi
  else
    AUTH_MODE="ro"
    REPO_MODE="rw"
  fi
  if [[ "${AISB_WORKSPACE_READONLY:-0}" == "1" ]]; then
    REPO_MODE="ro"
  fi

  WORKSPACE_MOUNT_OPTS="${REPO_MODE},nosuid,nodev"
  if [[ "${AISB_RELABEL_WORKSPACE:-0}" == "1" ]]; then
    common_check_workspace_relabel "$ROOT"
    WORKSPACE_MOUNT_OPTS+=",z"
  fi

  : "${AISB_MEMORY:=8g}"
  : "${AISB_CPUS:=4}"
  : "${AISB_PIDS:=1024}"
  COMMON_SECCOMP_SUMMARY="podman default"

  _common_warn_memory

  local host_git_name host_git_email
  host_git_name="$(git config --get user.name 2>/dev/null || true)"
  host_git_email="$(git config --get user.email 2>/dev/null || true)"

  COMMON_PODMAN_ARGS=(
    --rm
    --pull=never
    --name "$NAME"
    --userns=keep-id
    --passwd-entry "${USER_NAME}:x:\$UID:\$GID:${USER_NAME}:${USER_HOME}:/bin/bash"
    --cap-drop=all
    --security-opt no-new-privileges
    --read-only
    --memory="$AISB_MEMORY"
    --cpus="$AISB_CPUS"
    --pids-limit="$AISB_PIDS"
    --tmpfs "${USER_HOME}:rw,nosuid,nodev,size=256m"
    --tmpfs "/uv-bin:rw,nosuid,nodev,size=128m"
    --tmpfs "/uv-tools:rw,nosuid,nodev,size=256m"
    --label "io.${TOOL}.repo=$ROOT"
    --label "io.${TOOL}.repo_hash=$HASH"
    --label "io.${TOOL}.session=$STAMP-$$"
    -e "HOME=${USER_HOME}"
    -e "PATH=${USER_HOME}/.local/bin:/uv-bin:/usr/local/bin:/usr/bin:/bin"
    -e "TERM=${TERM:-xterm-256color}"
    -e "COLORTERM=${COLORTERM:-truecolor}"
    -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME:-$host_git_name}"
    -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL:-$host_git_email}"
    -e "GIT_COMMITTER_NAME=${GIT_COMMITTER_NAME:-$host_git_name}"
    -e "GIT_COMMITTER_EMAIL=${GIT_COMMITTER_EMAIL:-$host_git_email}"
    -e "TMPDIR=/tmp"
    -e "TMP=/tmp"
    -e "TEMP=/tmp"
    -e "XDG_CACHE_HOME=/aisb-${TOOL}/cache"
    -e "XDG_STATE_HOME=/aisb-${TOOL}/state"
    -e "UV_CACHE_DIR=/aisb-${TOOL}/uv-cache"
    -e "UV_PYTHON_INSTALL_DIR=/aisb-${TOOL}/uv-python"
    -e "UV_PROJECT_ENVIRONMENT=/aisb-${TOOL}/venv"
    -e "PYTEST_ADDOPTS=${PYTEST_ADDOPTS:-} -o cache_dir=/aisb-${TOOL}/pytest"
    -v "${ROOT}:${ROOT}:${WORKSPACE_MOUNT_OPTS}"
    -v "${WORKSPACE_TMP_DIR}:/tmp:rw,nosuid,nodev,Z"
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
  common_log_startup
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

common_realpath() {
  realpath "$1" 2>/dev/null || printf '%s' "$1"
}

common_realpath_m() {
  realpath -m "$1" 2>/dev/null || common_realpath "$1"
}

common_passwd_home() {
  getent passwd "$(id -u)" 2>/dev/null | awk -F: '{print $6; exit}'
}

common_path_is_broad_or_home() {
  local root="$1"
  local home_real passwd_home passwd_home_real

  root="$(common_realpath_m "$root")"

  home_real="$(common_realpath_m "$HOME")"
  passwd_home="$(common_passwd_home || true)"
  passwd_home_real=""
  if [[ -n "$passwd_home" ]]; then
    passwd_home_real="$(common_realpath_m "$passwd_home")"
  fi

  case "$root" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var|/Users)
      return 0
      ;;
  esac

  if [[ "$root" == "$home_real" ]]; then
    return 0
  fi

  if [[ -n "$passwd_home_real" && "$root" == "$passwd_home_real" ]]; then
    return 0
  fi

  return 1
}

common_workspace_root_is_dangerous() {
  local root="$1"
  local xdg_data containers_real passwd_home passwd_containers_real

  root="$(common_realpath_m "$root")"

  if common_path_is_broad_or_home "$root"; then
    return 0
  fi

  xdg_data="${XDG_DATA_HOME:-$HOME/.local/share}"
  containers_real="$(common_realpath_m "$xdg_data/containers")"
  if [[ -n "$containers_real" && ( "$root" == "$containers_real" || "$root" == "$containers_real"/* ) ]]; then
    return 0
  fi

  passwd_home="$(common_passwd_home || true)"
  if [[ -n "$passwd_home" ]]; then
    passwd_containers_real="$(common_realpath_m "$passwd_home/.local/share/containers")"
    if [[ "$root" == "$passwd_containers_real" || "$root" == "$passwd_containers_real"/* ]]; then
      return 0
    fi
  fi

  return 1
}

common_check_workspace_root() {
  local root="$1"

  if common_workspace_root_is_dangerous "$root"; then
    if [[ "${AISB_ALLOW_DANGEROUS_ROOT:-0}" == "1" ]]; then
      echo "warn: AISB_ALLOW_DANGEROUS_ROOT=1; allowing workspace root '$root'" >&2
      return 0
    fi
    common_die_dangerous_root "$root"
  fi
}

common_check_workspace_relabel() {
  local root="$1"

  if common_workspace_root_is_dangerous "$root"; then
    if [[ "${AISB_ALLOW_DANGEROUS_RELABEL:-0}" == "1" ]]; then
      echo "warn: AISB_ALLOW_DANGEROUS_RELABEL=1; allowing SELinux relabel of dangerous workspace root '$root'" >&2
      return 0
    fi
    echo "Error: refusing to relabel dangerous workspace root: $root" >&2
    echo >&2
    echo "AISB_ALLOW_DANGEROUS_ROOT=1 allows the bind mount, but does not permit broad SELinux relabeling." >&2
    echo "Run from a narrow project directory, unset AISB_RELABEL_WORKSPACE, or set AISB_ALLOW_DANGEROUS_RELABEL=1 intentionally." >&2
    exit 1
  fi
}

common_require_mount_path() {
  local path="$1"
  local description="$2"

  if [[ "$path" == *:* ]]; then
    echo "Error: refusing bind mount with ':' in $description: $path" >&2
    echo "Podman -v uses ':' to separate source, destination, and options; paths containing ':' are ambiguous." >&2
    exit 1
  fi
}

common_ensure_json_object_file() {
  local path="$1"
  local description="$2"

  if [[ -e "$path" && ! -f "$path" ]]; then
    echo "Error: $description exists but is not a regular file: $path" >&2
    exit 1
  fi

  if [[ ! -s "$path" ]] || ! grep -q '[^[:space:]]' "$path"; then
    ( umask 077; printf '{}\n' > "$path" )
  fi
}

common_selinux_enabled() {
  command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled
}

common_selinux_context() {
  stat -c '%C' "$1" 2>/dev/null || true
}

common_selinux_context_is_container() {
  local context="$1"
  [[ "$context" == *:container_file_t:* || "$context" == *:container_ro_file_t:* ]]
}

common_maybe_relabel_auth_file() {
  local path="$1"
  local description="$2"
  local context answer

  common_selinux_enabled || return 0

  context="$(common_selinux_context "$path")"
  if common_selinux_context_is_container "$context"; then
    return 0
  fi

  if [[ "${AISB_RELABEL_AUTH:-0}" == "1" ]]; then
    chcon -t container_file_t "$path"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "Error: SELinux may prevent the container from reading $description: $path" >&2
    echo "Current label: ${context:-unknown}" >&2
    echo "Run this once, then retry:" >&2
    echo "  chcon -t container_file_t '$path'" >&2
    echo "Or rerun with AISB_RELABEL_AUTH=1 to allow this wrapper to relabel auth/config files." >&2
    exit 1
  fi

  echo "SELinux may prevent the container from reading $description:" >&2
  echo "  $path" >&2
  echo "Current label: ${context:-unknown}" >&2
  read -r -p "Relabel this file for container access with chcon -t container_file_t? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      chcon -t container_file_t "$path"
      ;;
    *)
      echo "Error: refusing to run until $description is readable by the container." >&2
      echo "Run this once, then retry:" >&2
      echo "  chcon -t container_file_t '$path'" >&2
      echo "Or rerun with AISB_RELABEL_AUTH=1 to allow this wrapper to relabel auth/config files." >&2
      exit 1
      ;;
  esac
}

common_check_workspace_bind_paths() {
  common_require_mount_path "$ROOT" "workspace source path"
  common_require_mount_path "$ROOT" "workspace destination path"
  common_require_mount_path "$WORKSPACE_TMP_DIR" "temporary directory source path"
  common_require_mount_path "/tmp" "temporary directory destination path"
  common_require_mount_path "$WORKSPACE_CACHE_DIR" "cache source path"
  common_require_mount_path "/aisb-${TOOL}/cache" "cache destination path"
  common_require_mount_path "$WORKSPACE_STATE_DIR" "state source path"
  common_require_mount_path "/aisb-${TOOL}/state" "state destination path"
  common_require_mount_path "$WORKSPACE_UV_CACHE_DIR" "uv cache source path"
  common_require_mount_path "/aisb-${TOOL}/uv-cache" "uv cache destination path"
  common_require_mount_path "$WORKSPACE_UV_PYTHON_DIR" "uv python source path"
  common_require_mount_path "/aisb-${TOOL}/uv-python" "uv python destination path"
  common_require_mount_path "$WORKSPACE_VENV_DIR" "venv source path"
  common_require_mount_path "/aisb-${TOOL}/venv" "venv destination path"
  common_require_mount_path "$WORKSPACE_PYTEST_CACHE_DIR" "pytest cache source path"
  common_require_mount_path "/aisb-${TOOL}/pytest" "pytest cache destination path"
}

common_validate_prune_root() {
  local prune_root="$1"
  local expected_state_base="$2"
  local prune_real state_real

  if [[ "$prune_root" != /* ]]; then
    echo "warn: skipping prune for non-absolute path: $prune_root" >&2
    return 1
  fi

  prune_real="$(common_realpath_m "$prune_root")"
  state_real="$(common_realpath_m "$expected_state_base")"

  if [[ "$prune_real" == "/" ]]; then
    echo "warn: skipping prune for root path: $prune_root" >&2
    return 1
  fi

  if common_path_is_broad_or_home "$prune_real"; then
    echo "warn: skipping prune for broad host path: $prune_root" >&2
    return 1
  fi

  if [[ "$(basename "$state_real")" != "claude-podman" ]]; then
    echo "warn: skipping prune outside expected claude-podman state base: $prune_root" >&2
    return 1
  fi

  if [[ "$prune_real" != "$state_real"/* ]]; then
    echo "warn: skipping prune outside state base $state_real: $prune_root" >&2
    return 1
  fi

  return 0
}

common_prune_old_dirs() {
  local prune_root="$1"
  local expected_state_base="$2"
  shift 2

  if common_validate_prune_root "$prune_root" "$expected_state_base"; then
    find "$prune_root" -mindepth 1 -maxdepth 1 -type d "$@" -exec rm -rf {} + 2>/dev/null || true
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
    echo "  $(aisb_build_command_hint "$_AISB_COMMON_DIR" "$ROOT" "$TOOL")" >&2
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
    common_require_mount_path "$gh_host_config" "GitHub CLI config source path"
    common_require_mount_path "${USER_HOME}/.config/gh" "GitHub CLI config destination path"
    COMMON_PODMAN_ARGS+=(-v "${gh_host_config}:${USER_HOME}/.config/gh:${AUTH_MODE},nosuid,nodev,noexec")
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
    COMMON_SECCOMP_SUMMARY="$seccomp_profile"
  else
    echo "warn: AISB_STRICT_SECCOMP=1 but $seccomp_profile is not readable; using default" >&2
  fi
}
