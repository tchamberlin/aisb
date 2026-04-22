# Prevent wrappers from running in dangerous workspace roots

## Problem

The run wrappers currently derive the workspace root with:

```bash
if git rev-parse --show-toplevel >/dev/null 2>&1; then
  ROOT="$(git rev-parse --show-toplevel)"
else
  ROOT="$PWD"
fi
ROOT="$(realpath "$ROOT")"
```

They previously bind-mounted `ROOT` into the container with SELinux relabeling:

```bash
-v "${ROOT}:${ROOT}:${REPO_MODE},nosuid,nodev,z"
```

For normal project directories this is acceptable. If invoked from `$HOME`,
`/`, or another broad system directory outside a git repository, the wrapper
can mount and relabel far too much host state. On SELinux hosts, `:z` can make
Podman recursively relabel the mounted tree as container-accessible content.

## Goals

- Fail before any `podman run` when the computed workspace root is dangerous.
- Do not relabel the workspace mount by default.
- Protect both code paths:
  - `bin/_run-common.sh` for `run-claude`, `run-codex`, and `run-pi`
  - `bin/run-sb`
- Keep normal behavior for git repositories.
- Require git repositories for agent wrappers by default.
- Keep non-git project directories usable for `run-sb` when they are narrow and
  explicit.
- Provide an override for intentional advanced use.
- Print a clear error that explains why the wrapper refused to run.

## Non-goals

- Do not remove SELinux labels from wrapper-owned state/cache mounts in this
  change.
- Do not change the auth-mount model.
- Do not refactor `run-sb` into `_run-common.sh` as part of this fix.
- Do not attempt to detect every unsafe path on every distro. Block the common
  high-risk roots first.

## Proposed behavior

After computing and canonicalizing `ROOT`, call a guard before deriving
`BASE`, `HASH`, creating state directories, or assembling Podman args.

The guard rejects:

- `/`
- the invoking user's home directory, after `realpath`
- known broad home-like parents:
  - `/home`
  - `/Users`
- common system directories:
  - `/bin`
  - `/boot`
  - `/dev`
  - `/etc`
  - `/lib`
  - `/lib64`
  - `/opt`
  - `/proc`
  - `/root`
  - `/run`
  - `/sbin`
  - `/srv`
  - `/sys`
  - `/tmp`
  - `/usr`
  - `/var`
- XDG container storage and its descendants:
  - `${XDG_DATA_HOME:-$HOME/.local/share}/containers`

The guard allows:

- any git repository root that is not one of the rejected paths
- for `run-sb`, narrow non-git directories such as `$HOME/src/scratch` or
  `/tmp/project` only if not covered by a rejected exact path
- for agent wrappers, non-git directories only when
  `AISB_ALLOW_NON_GIT_WORKSPACE=1` is set

Question to settle during implementation: should `/tmp` be rejected exactly
while `/tmp/project` is allowed? The current recommendation is yes. Rejecting
all descendants of `/tmp` would make scratch-project usage worse without
addressing the root relabeling risk.

## Overrides

Add:

```bash
AISB_ALLOW_NON_GIT_WORKSPACE=1
```

When set, `run-claude`, `run-codex`, and `run-pi` may use a non-git `$PWD` as
the workspace root. `run-sb` does not require this flag.

Add:

```bash
AISB_ALLOW_DANGEROUS_ROOT=1
```

When set, the guard prints a warning and allows the run.

Add:

```bash
AISB_RELABEL_WORKSPACE=1
```

When unset, the workspace bind mount omits `:z` and SELinux may deny access
without mutating host labels. When set, the workspace mount gets `:z`, but the
dangerous-root guard still applies unless `AISB_ALLOW_DANGEROUS_ROOT=1` is also
set.

Suggested warning:

```text
warn: AISB_ALLOW_DANGEROUS_ROOT=1; allowing workspace root '$ROOT'
```

Suggested refusal:

```text
Error: refusing to run <tool> with dangerous workspace root: <root>

This wrapper bind-mounts the workspace with SELinux relabeling (:z).
Run it from a project directory or git repository instead.
To override intentionally, set AISB_ALLOW_DANGEROUS_ROOT=1.
```

## Implementation plan

1. In `bin/_run-common.sh`, require `git rev-parse --show-toplevel` unless
   `AISB_ALLOW_NON_GIT_WORKSPACE=1` is set.
2. Add `common_check_workspace_root` to `bin/_run-common.sh`.
3. Call it immediately after:

   ```bash
   ROOT="$(realpath "$ROOT")"
   ```

4. Keep the check side-effect free except for error/warning output.
5. Build workspace mount options without `:z` by default.
6. Append `,z` only when `AISB_RELABEL_WORKSPACE=1`.
7. Add equivalent dangerous-root helper logic to `bin/run-sb`.
8. Document `AISB_ALLOW_NON_GIT_WORKSPACE=1`,
   `AISB_ALLOW_DANGEROUS_ROOT=1`, and `AISB_RELABEL_WORKSPACE=1` in the README
   environment table.
9. Add a short note near the wrapper behavior docs that workspace relabeling is
   opt-in because it changes host SELinux labels.

## Suggested helper shape

```bash
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
```

For `run-sb`, either duplicate the minimal helper or first extract the root
guard into a tiny shared file. Duplicating is acceptable for this targeted fix;
the later `run-sb` common-library refactor can remove it.

## Test plan

Use a temporary fake `podman` earlier in `PATH` so tests can verify refusal
without launching containers.

Manual checks:

```bash
tmpbin="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho podman "$@"\n' > "$tmpbin/podman"
chmod +x "$tmpbin/podman"
```

Expected failures:

```bash
(cd "$HOME" && PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-sb true)
(cd / && PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-sb true)
(cd "$HOME" && PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-codex --version)
(mkdir -p "$HOME/tmp-aisb-non-git" && cd "$HOME/tmp-aisb-non-git" && PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-codex --version)
```

Expected success:

```bash
(cd /path/to/aisb && PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-sb true)
mkdir -p "$HOME/tmp-aisb-non-git"
(cd "$HOME/tmp-aisb-non-git" && PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-sb true)
(cd "$HOME/tmp-aisb-non-git" && AISB_ALLOW_NON_GIT_WORKSPACE=1 PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-codex --version)
```

Expected override:

```bash
(cd "$HOME" && AISB_ALLOW_DANGEROUS_ROOT=1 PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-sb true)
```

Expected relabel opt-in for a normal repo:

```bash
(cd /path/to/aisb && AISB_RELABEL_WORKSPACE=1 PATH="$tmpbin:$PATH" /path/to/aisb/bin/run-sb true)
```

Also run ShellCheck if available:

```bash
shellcheck bin/_run-common.sh bin/run-sb bin/run-claude bin/run-codex bin/run-pi
```

## Recovery note for users who already ran from `$HOME`

On SELinux systems, users can restore labels with:

```bash
restorecon -Rv -e "$HOME/.local/share/containers" "$HOME"
```

Then inspect remaining container labels outside rootless Podman storage:

```bash
find "$HOME" \
  -path "$HOME/.local/share/containers" -prune -o \
  -context '*container_file_t*' \
  -print 2>/dev/null | head -100
```
