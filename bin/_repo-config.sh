# shellcheck shell=bash
# Shared workspace/config helpers. Sourced, not executed.

if [[ "${_AISB_REPO_CONFIG_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AISB_REPO_CONFIG_LOADED=1

aisb_sha1_10() {
  printf '%s' "$1" | { sha1sum 2>/dev/null || shasum -a 1; } | awk '{print $1}' | cut -c1-10
}

aisb_workspace_base() {
  local root="$1"
  local base
  base="$(basename "$root")"
  base="${base//[^A-Za-z0-9._-]/_}"
  base="${base:0:48}"
  printf '%s' "${base:-repo}"
}

aisb_strip_quotes() {
  local value="$1"
  if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

aisb_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

aisb_load_repo_env() {
  local root="$1"
  local env_file="$root/.aisb.env"
  AISB_REPO_BASE_IMAGE=""

  [[ -f "$env_file" ]] || return 0

  local line key value line_no
  line_no=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="$(aisb_trim "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" != *=* ]]; then
      echo "warn: ignoring malformed $env_file:$line_no" >&2
      continue
    fi

    key="$(aisb_trim "${line%%=*}")"
    value="$(aisb_trim "${line#*=}")"
    value="$(aisb_strip_quotes "$value")"

    case "$key" in
      AISB_BASE_IMAGE)
        AISB_REPO_BASE_IMAGE="$value"
        ;;
      *)
        echo "warn: ignoring unsupported $env_file key '$key'" >&2
        ;;
    esac
  done < "$env_file"
}

aisb_tool_default_image() {
  case "$1" in
    sb)     printf '%s\n' "localhost/aisb-base:latest" ;;
    claude) printf '%s\n' "aisb-claude:latest" ;;
    codex)  printf '%s\n' "aisb-codex:latest" ;;
    pi)     printf '%s\n' "aisb-pi:latest" ;;
    *)
      echo "error: unknown tool '$1'" >&2
      return 2
      ;;
  esac
}

aisb_tool_image_env_var() {
  case "$1" in
    sb)     printf '%s\n' "SB_IMAGE" ;;
    claude) printf '%s\n' "CLAUDE_IMAGE" ;;
    codex)  printf '%s\n' "CODEX_IMAGE" ;;
    pi)     printf '%s\n' "PI_IMAGE" ;;
    *)
      echo "error: unknown tool '$1'" >&2
      return 2
      ;;
  esac
}

aisb_derived_tool_image() {
  local tool="$1"
  local hash="$2"
  printf 'localhost/aisb-%s-%s:latest\n' "$tool" "$hash"
}

aisb_resolve_tool_image() {
  local tool="$1"
  local hash="$2"
  local env_var
  env_var="$(aisb_tool_image_env_var "$tool")"

  if [[ -n "${!env_var:-}" ]]; then
    printf '%s\n' "${!env_var}"
  elif [[ -n "${AISB_REPO_BASE_IMAGE:-}" ]]; then
    if [[ "$tool" == "sb" ]]; then
      printf '%s\n' "$AISB_REPO_BASE_IMAGE"
    else
      aisb_derived_tool_image "$tool" "$hash"
    fi
  else
    aisb_tool_default_image "$tool"
  fi
}

aisb_build_command_hint() {
  local script_dir="$1"
  local root="$2"
  local flavor="$3"
  printf 'AISB_WORKSPACE=%q %q %q\n' "$root" "$script_dir/build-containers" "$flavor"
}
