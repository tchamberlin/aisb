# aisb

**A**I **s**and**b**ox — run coding agents (Claude Code, Codex, pi, or a plain
shell) inside a hardened rootless [podman] container. Each invocation gets a
fresh container; only the current repo and per-agent auth are mounted.

## What's here

| File                   | What it is                                                               |
| ---------------------- | ------------------------------------------------------------------------ |
| `Containerfile.base`   | Fedora-minimal base: coreutils, Node 24, uv, Python 3.14, build tools.   |
| `Containerfile.claude` | `claude` CLI on top of base (`claude-uv:latest`).                        |
| `Containerfile.codex`  | OpenAI `codex` CLI on top of base (`codex-uv:latest`).                   |
| `Containerfile.pi`     | `pi-coding-agent` CLI on top of base (`pi-uv:latest`).                   |
| `bin/build-containers` | Build one or all images. Parallelizes the flavor builds.                 |
| `bin/run-claude`       | Run Claude Code against the current repo.                                |
| `bin/run-codex`        | Run Codex against the current repo.                                      |
| `bin/run-pi`           | Run pi against the current repo.                                         |
| `bin/run-sb`           | Generic sandboxed shell / command runner on the base image.              |
| `install.sh`           | Symlink `claude`/`codex`/`pi`/`sb` into `~/.local/bin`.                  |
| `seccomp-strict.json`  | Optional seccomp profile (default + extra denies). Enable via env var.   |
| `.envrc.example`       | Sample [direnv] hook that pulls API keys via [pass]. Copy to `.envrc`.   |

## Install

```sh
./install.sh                    # symlinks ~/.local/bin/{claude,codex,pi,sb}
bin/build-containers all        # base + three flavors (parallel)
```

Requires: `podman`, `bash`, `npm` (for version-pin lookups in `build-containers`).

Add `~/.local/bin` to your `PATH` if it isn't already.

## Use

From inside any repo:

```sh
claude                          # interactive Claude Code
codex                           # interactive Codex
pi                              # interactive pi
sb                              # interactive bash in the sandbox
sb uv run script.py             # one-shot command in the sandbox
```

The wrappers:

- mount the current repo (git root or `$PWD`) read-write at its real path
- forward API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
  `TOGETHER_API_KEY`, …) and `gh` auth
- mount Claude's host auth files (`~/.claude/.credentials.json`,
  `~/.claude.json`) read-write for Claude Code compatibility, while keeping the
  rest of Claude runtime state per-repo. Codex auth/config and `gh` config are
  mounted **read-only** in normal runs. To refresh tokens or run a first-time
  `login`, use `AISB_AUTH_WRITE=1` (or wrapper-specific `CODEX_AUTH_WRITE=1`).
  Auth-write mode also mounts the repo read-only to shrink blast radius — set
  `AISB_AUTH_WRITE_KEEP_REPO_RW=1` to override.
- keep durable per-repo runtime state (Claude/Codex dotdirs, logs, sessions,
  venvs, uv caches) under `$XDG_STATE_HOME/claude-podman/` and
  `$XDG_CACHE_HOME/claude-podman/` — survives container removal and image
  rebuilds

## Hardening

### Host protection

Every container runs with:

- `--userns=keep-id` (no root-in-container)
- `--cap-drop=all` + `--security-opt no-new-privileges`
- `--read-only` rootfs with tmpfs for `/tmp`, `/home/<user>`, `/uv-bin`, `/uv-tools`
- Mounts tagged `nosuid,nodev`
- One container per invocation (`--rm`), unique `--name` per session
- Resource caps: `--memory`, `--cpus`, `--pids-limit` (overridable via
  `AISB_MEMORY`, `AISB_CPUS`, `AISB_PIDS`)

The container is the sandbox, so agent-internal approval prompts are bypassed
(`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox`
for Codex). Set `CLAUDE_SAFE_MODE=1` / `CODEX_SAFE_MODE=1` to keep them enabled.

### What this does not protect against

The host is isolated from the agent, but the agent still operates with
substantial trust *inside* the container. Understand these before trusting
the sandbox with sensitive material:

- **Live credentials inside the container.** Each run has access to API keys
  forwarded via env (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
  `TOGETHER_API_KEY`, …), per-agent auth files (`~/.claude/.credentials.json`,
  `~/.codex/auth.json`, `~/.pi/agent/*`), and optionally `GH_TOKEN` /
  `~/.config/gh`. A prompt-injection in repo content or tool output can, in
  one command, exfiltrate any of these.
- **Full network egress.** Containers have unrestricted outbound network. Any
  exfiltration path (DNS, HTTPS, anything else) is open. For one-shot
  `sb` runs you can set `AISB_NO_NETWORK=1` to drop all networking; agent
  wrappers need the network for API calls and do not support this.
- **The mounted repo is read-write.** An agent can modify files, commit, and
  (if `GH_TOKEN` or `gh` auth is present) push malicious commits upstream.
- **Agent-level safety is bypassed.** `--dangerously-skip-permissions` /
  `--dangerously-bypass-approvals-and-sandbox` delegate all behavioral
  boundaries to model alignment. If the model is jailbroken or
  prompt-injected, no in-container check will stop it.

Claude auth files are writable in normal runs because Claude Code may rewrite
them during startup. Codex credentials and `gh` config remain read-only in
normal runs (see `AISB_AUTH_WRITE=1` below for refresh mode). This does not
prevent exfiltration of credentials that the current session can read.

## Environment

Copy `.envrc.example` to `.envrc` and run `direnv allow`, or supply your own
mechanism. The example pulls from [pass] (`api/openai`, `api/anthropic`,
`api/together`, `api/openrouter`) — adjust or replace to taste. Any mechanism
that exports the API key env vars before invoking a wrapper will work.

Local `.envrc` is gitignored.

Per-wrapper overrides:

| Var                        | Effect                                                                |
| -------------------------- | --------------------------------------------------------------------- |
| `CLAUDE_IMAGE`             | Override image tag for `run-claude`.                                  |
| `CODEX_IMAGE`              | Override image tag for `run-codex`.                                   |
| `PI_IMAGE`                 | Override image tag for `run-pi`.                                      |
| `SB_IMAGE`                 | Override image tag for `run-sb`.                                      |
| `CLAUDE_SAFE_MODE=1`       | Keep Claude's built-in permission prompts.                            |
| `CODEX_SAFE_MODE=1`        | Keep Codex's built-in approvals + sandbox.                            |
| `CLAUDE_NO_CACHE=1`        | Pass `--no-cache` to `podman build`.                                  |
| `BASE_IMAGE`               | Override base image tag at build time.                                |
| `AISB_AUTH_WRITE=1`        | Flip auth mounts to rw and repo to ro (for `login` / token refresh).  |
| `CLAUDE_AUTH_WRITE=1`      | For `run-claude`, mount the repo ro while Claude auth stays writable. |
| `CODEX_AUTH_WRITE=1`       | As above, for `run-codex` only.                                       |
| `PI_AUTH_WRITE=1`          | As above, for `run-pi` only (no-op on auth but flips repo to ro).     |
| `AISB_AUTH_WRITE_KEEP_REPO_RW=1` | In auth-write mode, keep the repo writable.                     |
| `AISB_MEMORY`              | `--memory` cap (default `8g`).                                        |
| `AISB_CPUS`                | `--cpus` cap (default `4`).                                           |
| `AISB_PIDS`                | `--pids-limit` cap (default `1024`).                                  |
| `AISB_NO_NETWORK=1`        | `run-sb` only: disable all networking (`--network=none`).             |
| `AISB_STRICT_SECCOMP=1`    | Apply `seccomp-strict.json` (extra denies on top of podman default).  |
| `AISB_SECCOMP_PROFILE`     | Path to custom seccomp profile (overrides `seccomp-strict.json`).     |

[podman]: https://podman.io
[direnv]: https://direnv.net
[pass]: https://www.passwordstore.org
