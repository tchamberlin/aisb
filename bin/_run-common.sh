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
#   WORKSPACE_TMP_DIR, WORKSPACE_REPO_VENV_PATH, WORKSPACE_REPO_VENV_MASK_DIR
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
  if (( ${#WORKSPACE_REPO_VENV_MASK_ARGS[@]} > 0 )); then
    echo "[aisb:${TOOL}:debug] mask repo .venv: $WORKSPACE_REPO_VENV_MASK_DIR -> $WORKSPACE_REPO_VENV_PATH (bind rw,nosuid,nodev)" >&2
  else
    echo "[aisb:${TOOL}:debug] mask repo .venv: not present" >&2
  fi
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

common_tool_package_name() {
  case "$1" in
    claude) printf '%s\n' "@anthropic-ai/claude-code" ;;
    codex)  printf '%s\n' "@openai/codex" ;;
    pi)     printf '%s\n' "@mariozechner/pi-coding-agent" ;;
    *) return 1 ;;
  esac
}

common_cache_file_is_fresh() {
  local path="$1"
  local ttl="$2"
  local now mtime

  [[ -s "$path" ]] || return 1
  now="$(date +%s)"
  mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
  (( now - mtime < ttl ))
}

common_latest_npm_version_cached() {
  local package="$1"
  local cache_dir cache_file ttl latest

  ttl="${AISB_UPDATE_CHECK_TTL_SECONDS:-86400}"
  cache_dir="${CACHE_BASE}/update-checks"
  cache_file="${cache_dir}/${package//@/_}.version"
  cache_file="${cache_file//\//_}"

  if common_cache_file_is_fresh "$cache_file" "$ttl"; then
    sed -n '1p' "$cache_file"
    return 0
  fi

  mkdir -p "$cache_dir"
  if command -v timeout >/dev/null 2>&1; then
    latest="$(NPM_CONFIG_FUND=false NPM_CONFIG_UPDATE_NOTIFIER=false timeout 5s npm view "$package" version 2>/dev/null || true)"
  else
    latest="$(NPM_CONFIG_FUND=false NPM_CONFIG_UPDATE_NOTIFIER=false npm view "$package" version 2>/dev/null || true)"
  fi
  latest="$(printf '%s' "$latest" | awk 'NF { print $1; exit }')"
  [[ -n "$latest" ]] || return 1

  printf '%s\n' "$latest" > "$cache_file"
  printf '%s\n' "$latest"
}

common_maybe_warn_tool_update() {
  local package current latest flavor hint

  [[ "${AISB_QUIET:-0}" == "1" ]] && return 0
  [[ "${AISB_UPDATE_CHECK:-1}" == "0" ]] && return 0
  case "$TOOL" in
    claude|codex|pi) ;;
    *) return 0 ;;
  esac

  package="$(common_tool_package_name "$TOOL")" || return 0
  current="$(common_image_label "$IMAGE" "io.aisb.tool.version")"
  [[ -n "$current" && "$current" != "<no value>" && "$current" != "unknown" ]] || return 0

  latest="$(common_latest_npm_version_cached "$package" || true)"
  [[ -n "$latest" && "$latest" != "$current" ]] || return 0

  flavor="$(aisb_managed_image_build_flavor "$TOOL")"
  hint="$(aisb_build_command_hint "$_AISB_COMMON_DIR" "$ROOT" "$flavor")"
  echo "[aisb:${TOOL}] update available: ${package} ${current} -> ${latest}" >&2
  echo "[aisb:${TOOL}] rebuild the managed image with:" >&2
  echo "  ${hint}" >&2
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
  WORKSPACE_REPO_VENV_PATH="${ROOT}/.venv"
  WORKSPACE_REPO_VENV_MASK_DIR="${STATE_BASE}/${TOOL}/${HASH}/repo-venv-masks/${STAMP}-$$"
  WORKSPACE_REPO_VENV_MASK_ARGS=()

  common_check_workspace_bind_paths
  common_setup_workspace_venv_mask

  mkdir -p \
    "$WORKSPACE_CACHE_DIR" \
    "$WORKSPACE_STATE_DIR" \
    "$WORKSPACE_UV_CACHE_DIR" \
    "$WORKSPACE_UV_PYTHON_DIR" \
    "$WORKSPACE_VENV_DIR" \
    "$WORKSPACE_PYTEST_CACHE_DIR" \
    "$WORKSPACE_TMP_DIR" \
    "$WORKSPACE_REPO_VENV_MASK_DIR"
  chmod 1777 "$WORKSPACE_TMP_DIR"

  common_prune_old_dirs "${STATE_BASE}/${TOOL}/${HASH}/venvs" "$STATE_BASE" -mtime +7
  common_prune_old_dirs "${STATE_BASE}/${TOOL}/${HASH}/repo-venv-masks" "$STATE_BASE" -mtime +7
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

  common_maybe_prompt_workspace_container_readable

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
    -e "NPM_CONFIG_CACHE=/tmp/npm-cache"
    -e "NPM_CONFIG_FUND=false"
    -e "NPM_CONFIG_UPDATE_NOTIFIER=false"
    -e "XDG_CACHE_HOME=/aisb-${TOOL}/cache"
    -e "XDG_STATE_HOME=/aisb-${TOOL}/state"
    -e "UV_CACHE_DIR=/aisb-${TOOL}/uv-cache"
    -e "UV_PYTHON_INSTALL_DIR=/aisb-${TOOL}/uv-python"
    -e "UV_PROJECT_ENVIRONMENT=/aisb-${TOOL}/venv"
    -e "PYTEST_ADDOPTS=${PYTEST_ADDOPTS:-} -o cache_dir=/aisb-${TOOL}/pytest"
    -v "${ROOT}:${ROOT}:${WORKSPACE_MOUNT_OPTS}"
    "${WORKSPACE_REPO_VENV_MASK_ARGS[@]}"
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

common_setup_workspace_venv_mask() {
  WORKSPACE_REPO_VENV_MASK_ARGS=()

  if [[ -L "$WORKSPACE_REPO_VENV_PATH" ]]; then
    echo "Error: refusing to run with symlinked repo .venv: $WORKSPACE_REPO_VENV_PATH" >&2
    echo "The container cannot safely mask a symlinked .venv without risking access to the symlink target." >&2
    exit 1
  fi

  if [[ -e "$WORKSPACE_REPO_VENV_PATH" && ! -d "$WORKSPACE_REPO_VENV_PATH" ]]; then
    echo "Error: refusing to run with non-directory repo .venv: $WORKSPACE_REPO_VENV_PATH" >&2
    exit 1
  fi

  if [[ -d "$WORKSPACE_REPO_VENV_PATH" ]]; then
    WORKSPACE_REPO_VENV_MASK_ARGS=(
      -v "${WORKSPACE_REPO_VENV_MASK_DIR}:${WORKSPACE_REPO_VENV_PATH}:rw,nosuid,nodev,Z"
    )
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

common_workspace_container_readable_marker() {
  printf '%s\n' "${STATE_BASE}/workspaces/${HASH}/container-readable"
}

common_remember_workspace_container_readable() {
  local marker
  marker="$(common_workspace_container_readable_marker)"
  mkdir -p "$(dirname "$marker")"
  : > "$marker"
}

common_maybe_prompt_workspace_container_readable() {
  local context marker answer

  common_selinux_enabled || return 0
  [[ "${AISB_RELABEL_WORKSPACE:-0}" == "1" ]] && return 0

  context="$(common_selinux_context "$ROOT")"
  if common_selinux_context_is_container "$context"; then
    common_remember_workspace_container_readable
    return 0
  fi

  marker="$(common_workspace_container_readable_marker)"
  if [[ -e "$marker" ]]; then
    AISB_RELABEL_WORKSPACE=1
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "Error: SELinux may prevent the container from reading the workspace: $ROOT" >&2
    echo "Current label: ${context:-unknown}" >&2
    echo "Run once interactively to approve workspace relabeling, or rerun with AISB_RELABEL_WORKSPACE=1." >&2
    exit 1
  fi

  common_check_workspace_relabel "$ROOT"

  echo "SELinux may prevent the container from reading the workspace:" >&2
  echo "  $ROOT" >&2
  echo "Current label: ${context:-unknown}" >&2
  echo "AISB can mark this repo as container-readable by mounting it with Podman's :z relabel option." >&2
  read -r -p "Mark this repo container-readable for future AISB runs? [y/N] " answer
  case "$answer" in
    y|Y|yes|Yes|YES)
      common_remember_workspace_container_readable
      AISB_RELABEL_WORKSPACE=1
      ;;
    *)
      echo "Error: refusing to run until the workspace is readable by the container." >&2
      echo "Rerun and approve the prompt, or set AISB_RELABEL_WORKSPACE=1 intentionally." >&2
      exit 1
      ;;
  esac
}

common_maybe_repair_workspace_relabel() {
  local root="$1"
  local context

  common_selinux_enabled || return 0
  [[ "${AISB_RELABEL_WORKSPACE:-0}" == "1" ]] && return 0

  context="$(common_selinux_context "$root")"
  if ! common_selinux_context_is_container "$context"; then
    return 0
  fi

  [[ "${AISB_DEBUG:-0}" == "1" ]] || return 0

  if ! command -v restorecon >/dev/null 2>&1; then
    echo "[aisb:${TOOL}:debug] workspace root appears SELinux-relabeled for containers: $root" >&2
    echo "[aisb:${TOOL}:debug] current label: ${context:-unknown}" >&2
    echo "[aisb:${TOOL}:debug] install or run \`restorecon -Rv '$root'\` manually to restore host labels" >&2
    return 0
  fi

  echo "[aisb:${TOOL}:debug] workspace root appears SELinux-relabeled for containers: $root" >&2
  echo "[aisb:${TOOL}:debug] current label: ${context:-unknown}" >&2
  echo "[aisb:${TOOL}:debug] restore defaults with: restorecon -Rv '$root'" >&2
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
  common_require_mount_path "$WORKSPACE_REPO_VENV_PATH" "repo .venv destination path"
  common_require_mount_path "$WORKSPACE_REPO_VENV_MASK_DIR" "repo .venv mask source path"
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
    common_handle_missing_image
  fi

  common_maybe_prompt_rebuild_stale_image
  common_maybe_repair_workspace_relabel "$ROOT"
}

common_handle_missing_image() {
  local build_flavor build_cmd reply env_var

  env_var="$(aisb_tool_image_env_var "$TOOL")"
  if ! aisb_tool_uses_managed_image "$TOOL"; then
    echo "Error: Image '$IMAGE' not found." >&2
    if [[ -n "${!env_var:-}" ]]; then
      echo "The image comes from ${env_var}; build or pull it, then retry." >&2
    elif [[ "$TOOL" == "sb" && -n "${AISB_REPO_BASE_IMAGE:-}" ]]; then
      echo "Build or pull the repo-provided base image, then retry." >&2
    else
      echo "Build or pull the image, then retry." >&2
    fi
    exit 1
  fi

  build_flavor="$(aisb_managed_image_build_flavor "$TOOL")"
  build_cmd="$(aisb_build_command_hint "$_AISB_COMMON_DIR" "$ROOT" "$build_flavor")"

  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Error: Image '$IMAGE' not found. Build it first with:" >&2
    echo "  $build_cmd" >&2
    exit 1
  fi

  echo "Image '$IMAGE' not found." >&2
  printf "Build it now with \`%s\`? [Y/n] " "$build_cmd" >&2
  read -r reply || reply=""
  case "$reply" in
    ""|y|Y|yes|Yes|YES)
      if ! eval "$build_cmd"; then
        echo "Error: build failed; refusing to continue without image '$IMAGE'" >&2
        exit 1
      fi
      ;;
    *)
      echo "Error: image '$IMAGE' is required to continue." >&2
      echo "Build it later with: $build_cmd" >&2
      exit 1
      ;;
  esac

  if ! podman image exists "$IMAGE" 2>/dev/null; then
    echo "Error: build completed but image '$IMAGE' is still missing." >&2
    exit 1
  fi
}

common_image_label() {
  local image="$1"
  local label="$2"
  podman image inspect --format "{{if .Config.Labels}}{{index .Config.Labels \"$label\"}}{{end}}" "$image" 2>/dev/null || true
}

common_image_id() {
  local image="$1"
  podman image inspect --format '{{.Id}}' "$image" 2>/dev/null || true
}

common_maybe_prompt_rebuild_stale_image() {
  local aisb_root expected_recipe actual_recipe actual_base_id expected_base_id
  local build_flavor rebuild_cmd reason reply

  if ! aisb_tool_uses_managed_image "$TOOL"; then
    return 0
  fi

  aisb_root="$(dirname "$_AISB_COMMON_DIR")"
  actual_recipe="$(common_image_label "$IMAGE" "io.aisb.recipe_fingerprint")"
  expected_recipe="$(aisb_expected_recipe_fingerprint "$aisb_root" "$ROOT" "$TOOL")"
  reason=""

  if [[ -z "$actual_recipe" ]]; then
    reason="image predates AISB freshness metadata"
  elif [[ "$actual_recipe" != "$expected_recipe" ]]; then
    reason="AISB build recipe changed"
  fi

  expected_base_id=""
  if [[ -z "$reason" && "$TOOL" != "sb" ]]; then
    expected_base_id="$(aisb_expected_base_image_for_tool "$TOOL")"
    if [[ -n "$expected_base_id" ]] && podman image exists "$expected_base_id" 2>/dev/null; then
      expected_base_id="$(common_image_id "$expected_base_id")"
      actual_base_id="$(common_image_label "$IMAGE" "io.aisb.base_image_id")"
      if [[ -n "$actual_base_id" && -n "$expected_base_id" && "$actual_base_id" != "$expected_base_id" ]]; then
        reason="base image changed"
      fi
    fi
  fi

  [[ -n "$reason" ]] || return 0

  build_flavor="$(aisb_managed_image_build_flavor "$TOOL")"
  rebuild_cmd="$(aisb_build_command_hint "$_AISB_COMMON_DIR" "$ROOT" "$build_flavor")"

  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "warn: image '$IMAGE' may be stale: $reason" >&2
    echo "warn: rebuild with: $rebuild_cmd" >&2
    return 0
  fi

  echo "Image '$IMAGE' may be stale: $reason" >&2
  printf 'Rebuild it now with `%s`? [y/N] ' "$rebuild_cmd" >&2
  read -r reply || reply=""
  case "$reply" in
    y|Y|yes|Yes|YES)
      if ! eval "$rebuild_cmd"; then
        echo "Error: rebuild failed; refusing to continue with stale image '$IMAGE'" >&2
        exit 1
      fi
      ;;
    *)
      echo "Continuing with existing image: $IMAGE" >&2
      ;;
  esac
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
