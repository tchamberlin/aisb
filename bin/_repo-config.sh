# shellcheck shell=bash
# Shared workspace/config helpers. Sourced, not executed.

if [[ "${_AISB_REPO_CONFIG_LOADED:-0}" == "1" ]]; then
  return 0
fi
_AISB_REPO_CONFIG_LOADED=1

aisb_sha1_10() {
  printf '%s' "$1" | { sha1sum 2>/dev/null || shasum -a 1; } | awk '{print $1}' | cut -c1-10
}

aisb_sha1() {
  printf '%s' "$1" | { sha1sum 2>/dev/null || shasum -a 1; } | awk '{print $1}'
}

aisb_hash_files() {
  local file digest=""
  for file in "$@"; do
    if [[ ! -f "$file" ]]; then
      echo "error: fingerprint input file not found: $file" >&2
      return 1
    fi
    digest+="$file"$'\t'"$({ sha1sum 2>/dev/null || shasum -a 1; } < "$file" | awk '{print $1}')"${IFS}
  done
  aisb_sha1 "$digest"
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

# Split a value into whitespace-separated tokens, honoring single and double
# quotes so an individual token may contain spaces (e.g. a mount path under a
# volume named "T7 Shield"). Quote characters group the enclosed text but are
# not kept in the token. Results are returned in the global array
# AISB_SPLIT_TOKENS. Returns non-zero on an unterminated quote.
aisb_split_quoted() {
  local value="$1"
  AISB_SPLIT_TOKENS=()
  local n=${#value}
  local i=0 ch token="" in_token=0 quote=""
  while (( i < n )); do
    ch="${value:i:1}"
    if [[ -n "$quote" ]]; then
      if [[ "$ch" == "$quote" ]]; then
        quote=""
      else
        token+="$ch"
      fi
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      \'|\")
        quote="$ch"
        in_token=1
        ;;
      ' '|$'\t')
        if (( in_token )); then
          AISB_SPLIT_TOKENS+=("$token")
          token=""
          in_token=0
        fi
        ;;
      *)
        token+="$ch"
        in_token=1
        ;;
    esac
    i=$((i + 1))
  done
  [[ -z "$quote" ]] || return 1
  (( in_token )) && AISB_SPLIT_TOKENS+=("$token")
  return 0
}

aisb_load_repo_env() {
  local root="$1"
  local env_file="$root/.aisb.env"
  local containerfile="$root/Containerfile"
  local containerfile_is_symlink=0
  AISB_REPO_BASE_IMAGE=""
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_ENV_FILE="$env_file"
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_ENV_HAS_BASE_IMAGE=0
  AISB_REPO_CONTAINERFILE=""
  AISB_REPO_AUTO_BASE_IMAGE=""
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_EXTRA_MOUNTS=()
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_ALLOW_NON_GIT_WORKSPACE=""
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_NPM_PACKAGES=()
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_PYTHON_TOOLS=()
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_GENERATED_BASE=0
  # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
  AISB_REPO_PACKAGE_SPEC=""

  if [[ -L "$env_file" ]]; then
    echo "error: refusing symlinked repo config file: $env_file" >&2
    return 1
  fi

  if [[ -L "$containerfile" ]]; then
    containerfile_is_symlink=1
  elif [[ -f "$containerfile" ]]; then
    AISB_REPO_CONTAINERFILE="$containerfile"
    AISB_REPO_AUTO_BASE_IMAGE="$(aisb_auto_base_image "$root")"
  fi

  if [[ ! -f "$env_file" ]]; then
    if (( containerfile_is_symlink )); then
      echo "error: refusing symlinked repo Containerfile as base image source: $containerfile" >&2
      return 1
    fi
    if [[ -n "$AISB_REPO_CONTAINERFILE" ]]; then
      AISB_REPO_BASE_IMAGE="$AISB_REPO_AUTO_BASE_IMAGE"
    fi
    return 0
  fi

  local line key value raw_value line_no
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
    raw_value="$(aisb_trim "${line#*=}")"
    value="$(aisb_strip_quotes "$raw_value")"

    case "$key" in
      AISB_BASE_IMAGE)
        AISB_REPO_BASE_IMAGE="$value"
        # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
        AISB_REPO_ENV_HAS_BASE_IMAGE=1
        ;;
      AISB_EXTRA_MOUNTS)
        # Whitespace separates entries, but single/double quotes group spaces
        # so a mount path may live under a volume name like "T7 Shield".
        if aisb_split_quoted "$raw_value"; then
          local _token
          for _token in "${AISB_SPLIT_TOKENS[@]}"; do
            [[ -n "$_token" ]] && AISB_REPO_EXTRA_MOUNTS+=("$_token")
          done
        else
          echo "warn: ignoring AISB_EXTRA_MOUNTS with unbalanced quotes in $env_file:$line_no" >&2
        fi
        ;;
      AISB_NPM_PACKAGES)
        local _token
        # Word-split on whitespace; each token is one npm package spec.
        # shellcheck disable=SC2206
        for _token in $value; do
          [[ -n "$_token" ]] || continue
          if aisb_is_valid_package_token "$_token"; then
            AISB_REPO_NPM_PACKAGES+=("$_token")
          else
            echo "warn: ignoring invalid npm package '$_token' in $env_file:$line_no" >&2
          fi
        done
        ;;
      AISB_PYTHON_TOOLS)
        local _token
        # Word-split on whitespace; each token is one Python tool spec.
        # shellcheck disable=SC2206
        for _token in $value; do
          [[ -n "$_token" ]] || continue
          if aisb_is_valid_package_token "$_token"; then
            AISB_REPO_PYTHON_TOOLS+=("$_token")
          else
            echo "warn: ignoring invalid Python tool '$_token' in $env_file:$line_no" >&2
          fi
        done
        ;;
      AISB_ALLOW_NON_GIT_WORKSPACE)
        # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
        AISB_REPO_ALLOW_NON_GIT_WORKSPACE="$value"
        ;;
      *)
        echo "warn: ignoring unsupported $env_file key '$key'" >&2
        ;;
    esac
  done < "$env_file"

  local have_packages=0
  if (( ${#AISB_REPO_NPM_PACKAGES[@]} + ${#AISB_REPO_PYTHON_TOOLS[@]} > 0 )); then
    have_packages=1
  fi

  if [[ "$AISB_REPO_ENV_HAS_BASE_IMAGE" == "1" ]]; then
    # An explicit base image takes the repo's runtime fully under user control,
    # so declarative package keys are ignored to avoid silently layering on top.
    if (( have_packages )); then
      echo "warn: ignoring AISB_NPM_PACKAGES/AISB_PYTHON_TOOLS in $env_file because AISB_BASE_IMAGE is set" >&2
      AISB_REPO_NPM_PACKAGES=()
      AISB_REPO_PYTHON_TOOLS=()
    fi
  elif [[ -n "$AISB_REPO_CONTAINERFILE" ]]; then
    AISB_REPO_BASE_IMAGE="$AISB_REPO_AUTO_BASE_IMAGE"
    if (( have_packages )); then
      echo "warn: ignoring AISB_NPM_PACKAGES/AISB_PYTHON_TOOLS in $env_file because $containerfile is present" >&2
      AISB_REPO_NPM_PACKAGES=()
      AISB_REPO_PYTHON_TOOLS=()
    fi
  elif (( have_packages )); then
    # Declarative packages compile into a generated base image layered on the
    # default base, so the repo gets its tools without hand-writing a Containerfile.
    AISB_REPO_AUTO_BASE_IMAGE="$(aisb_auto_base_image "$root")"
    AISB_REPO_BASE_IMAGE="$AISB_REPO_AUTO_BASE_IMAGE"
    # shellcheck disable=SC2034 # Consumed by scripts that source this helper.
    AISB_REPO_GENERATED_BASE=1
    AISB_REPO_PACKAGE_SPEC="$(aisb_package_spec)"
  elif [[ "$containerfile_is_symlink" == "1" ]]; then
    echo "error: refusing symlinked repo Containerfile as base image source: $containerfile" >&2
    return 1
  fi
}

# Token charset accepted in AISB_NPM_PACKAGES / AISB_PYTHON_TOOLS. Each token is
# emitted single-quoted into a generated Containerfile RUN line and passed as a
# distinct argv element to npm/uv, so the only shell-injection escape to block is
# a literal single quote. We also reject leading '-' (option injection),
# backslashes (Containerfile line continuation), and embedded whitespace.
aisb_is_valid_package_token() {
  local t="$1"
  [[ -n "$t" ]] || return 1
  [[ "$t" != -* ]] || return 1
  case "$t" in
    *\'*) return 1 ;;
    *\\*) return 1 ;;
    *[[:space:]]*) return 1 ;;
  esac
  return 0
}

# Deterministic description of the declared packages, folded into the generated
# base image's recipe fingerprint so edits to the package list trigger a rebuild.
aisb_package_spec() {
  local p
  for p in "${AISB_REPO_NPM_PACKAGES[@]}"; do
    printf 'npm:%s\n' "$p"
  done
  for p in "${AISB_REPO_PYTHON_TOOLS[@]}"; do
    printf 'py:%s\n' "$p"
  done
}

aisb_append_repo_base_image() {
  local root="$1"
  local image="$2"
  local env_file="$root/.aisb.env"
  local root_real env_real env_dir

  root_real="$(realpath "$root")"
  env_real="$(realpath -m "$env_file")"

  if [[ "$env_real" != "$root_real/.aisb.env" ]]; then
    echo "error: refusing to write repo config outside workspace: $env_file" >&2
    return 1
  fi

  if [[ -L "$env_file" ]]; then
    echo "error: refusing to write symlinked repo config file: $env_file" >&2
    return 1
  fi

  if [[ -e "$env_file" && ! -f "$env_file" ]]; then
    echo "error: refusing to write repo config because path is not a regular file: $env_file" >&2
    return 1
  fi

  env_dir="$(dirname "$env_file")"
  if [[ "$(realpath "$env_dir")" != "$root_real" ]]; then
    echo "error: refusing to write repo config outside workspace: $env_file" >&2
    return 1
  fi

  if [[ -f "$env_file" && -s "$env_file" ]]; then
    printf '\n' >> "$env_file"
  fi
  printf 'AISB_BASE_IMAGE=%s\n' "$image" >> "$env_file"
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

aisb_auto_base_image() {
  local root="$1"
  local hash="${2:-}"
  local base
  if [[ -z "$hash" ]]; then
    hash="$(aisb_sha1_10 "$root")"
  fi
  base="$(aisb_workspace_base "$root")"
  printf 'localhost/aisb-%s-%s:latest\n' "$base" "$hash"
}

aisb_repo_base_is_local_containerfile() {
  [[ -n "${AISB_REPO_CONTAINERFILE:-}" \
    && -n "${AISB_REPO_AUTO_BASE_IMAGE:-}" \
    && "${AISB_REPO_BASE_IMAGE:-}" == "$AISB_REPO_AUTO_BASE_IMAGE" ]]
}

# True when the repo base image is generated by AISB from declarative package
# keys in .aisb.env (no hand-written Containerfile, no explicit AISB_BASE_IMAGE).
aisb_repo_base_is_generated() {
  [[ "${AISB_REPO_GENERATED_BASE:-0}" == "1" ]]
}

aisb_repo_config_summary() {
  if [[ "${AISB_REPO_ENV_HAS_BASE_IMAGE:-0}" == "1" ]]; then
    printf '%s sets AISB_BASE_IMAGE=%s\n' "$AISB_REPO_ENV_FILE" "$AISB_REPO_BASE_IMAGE"
  elif aisb_repo_base_is_generated; then
    printf '%s declares packages; using generated base %s\n' \
      "$AISB_REPO_ENV_FILE" "$AISB_REPO_BASE_IMAGE"
  elif aisb_repo_base_is_local_containerfile; then
    if [[ -f "${AISB_REPO_ENV_FILE:-}" ]]; then
      printf '%s has no AISB_BASE_IMAGE; using %s as generated base %s\n' \
        "$AISB_REPO_ENV_FILE" "$AISB_REPO_CONTAINERFILE" "$AISB_REPO_BASE_IMAGE"
    else
      printf 'no .aisb.env; using %s as generated base %s\n' \
        "$AISB_REPO_CONTAINERFILE" "$AISB_REPO_BASE_IMAGE"
    fi
  elif [[ -f "${AISB_REPO_ENV_FILE:-}" ]]; then
    printf '%s has no AISB_BASE_IMAGE\n' "$AISB_REPO_ENV_FILE"
  else
    printf 'no .aisb.env or project Containerfile\n'
  fi
}

aisb_tool_image_source_summary() {
  local tool="$1"
  local env_var
  env_var="$(aisb_tool_image_env_var "$tool")"

  if [[ -n "${!env_var:-}" ]]; then
    printf '%s override\n' "$env_var"
  elif [[ -n "${AISB_REPO_BASE_IMAGE:-}" ]]; then
    if [[ "$tool" == "sb" ]]; then
      if aisb_repo_base_is_generated; then
        printf 'generated base from declared packages\n'
      elif aisb_repo_base_is_local_containerfile; then
        printf 'generated from project Containerfile\n'
      else
        printf 'repo base image\n'
      fi
    else
      if aisb_repo_base_is_generated; then
        printf 'repo-derived tool image from generated base %s\n' "$AISB_REPO_BASE_IMAGE"
      elif aisb_repo_base_is_local_containerfile; then
        printf 'repo-derived tool image from generated base %s\n' "$AISB_REPO_BASE_IMAGE"
      else
        printf 'repo-derived tool image from base %s\n' "$AISB_REPO_BASE_IMAGE"
      fi
    fi
  else
    printf 'default image\n'
  fi
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

# Recipe fingerprint for the default localhost/aisb-base:latest image. Kept as a
# named helper so the generated-base path and the plain-base path agree exactly.
aisb_default_base_recipe_fingerprint() {
  local aisb_root="$1"
  aisb_hash_files \
    "$aisb_root/Containerfile.base" \
    "$aisb_root/container/install-agent-python-tools.sh" \
    "$aisb_root/container/install-node-npm.sh"
}

aisb_expected_recipe_fingerprint() {
  local aisb_root="$1"
  local workspace_root="$2"
  local tool="$3"

  case "$tool" in
    sb|base)
      if aisb_repo_base_is_local_containerfile; then
        aisb_hash_files "$workspace_root/Containerfile"
      elif aisb_repo_base_is_generated; then
        local base_fp
        base_fp="$(aisb_default_base_recipe_fingerprint "$aisb_root")" || return 1
        aisb_sha1 "${base_fp}"$'\n'"${AISB_REPO_PACKAGE_SPEC:-}"
      else
        aisb_default_base_recipe_fingerprint "$aisb_root"
      fi
      ;;
    claude)
      aisb_hash_files \
        "$aisb_root/Containerfile.claude" \
        "$aisb_root/container/install-agent-python-tools.sh" \
        "$aisb_root/container/install-agent-runtime-deps.sh"
      ;;
    codex)
      aisb_hash_files \
        "$aisb_root/Containerfile.codex" \
        "$aisb_root/container/install-agent-python-tools.sh" \
        "$aisb_root/container/install-agent-runtime-deps.sh" \
        "$aisb_root/container/install-node-npm.sh"
      ;;
    pi)
      aisb_hash_files \
        "$aisb_root/Containerfile.pi" \
        "$aisb_root/container/install-agent-python-tools.sh" \
        "$aisb_root/container/install-agent-runtime-deps.sh" \
        "$aisb_root/container/install-node-npm.sh"
      ;;
    *)
      echo "error: unknown tool '$tool' for recipe fingerprint" >&2
      return 2
      ;;
  esac
}

aisb_managed_image_build_flavor() {
  case "$1" in
    sb)     printf '%s\n' "base" ;;
    claude) printf '%s\n' "claude" ;;
    codex)  printf '%s\n' "codex" ;;
    pi)     printf '%s\n' "pi" ;;
    *)
      echo "error: unknown tool '$1'" >&2
      return 2
      ;;
  esac
}

aisb_tool_uses_managed_image() {
  local tool="$1"
  local env_var

  env_var="$(aisb_tool_image_env_var "$tool")"
  if [[ -n "${!env_var:-}" ]]; then
    return 1
  fi

  if [[ "$tool" == "sb" ]]; then
    [[ -z "${AISB_REPO_BASE_IMAGE:-}" ]] \
      || aisb_repo_base_is_local_containerfile \
      || aisb_repo_base_is_generated
    return
  fi

  return 0
}

aisb_expected_base_image_for_tool() {
  local tool="$1"

  case "$tool" in
    claude|codex|pi)
      if [[ -n "${AISB_REPO_BASE_IMAGE:-}" ]]; then
        printf '%s\n' "$AISB_REPO_BASE_IMAGE"
      else
        printf '%s\n' "localhost/aisb-base:latest"
      fi
      ;;
    *)
      return 0
      ;;
  esac
}
