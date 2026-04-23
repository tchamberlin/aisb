# aisb

**This repository is in an alpha state. I make no guarantees as to its correctness or utility. I will make breaking changes without notice**

**A**I **s**and**b**ox — run coding agents (Claude Code, Codex, pi, or a plain
shell) inside a hardened rootless [podman] container. Each invocation gets a
fresh container; only the current repo and per-agent auth are mounted.

## What's here

| File                   | What it is                                                               |
| ---------------------- | ------------------------------------------------------------------------ |
| `Containerfile.base`   | Fedora-minimal base: coreutils, Node 24, uv, Python 3.14, build tools.   |
| `Containerfile.claude` | `claude` CLI on top of base (`aisb-claude:latest`).                        |
| `Containerfile.codex`  | OpenAI `codex` CLI on top of base (`aisb-codex:latest`).                   |
| `Containerfile.pi`     | `pi-coding-agent` CLI on top of base (`aisb-pi:latest`).                   |
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
bin/build-containers --no-cache # rebuild without the podman layer cache
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

- mount the current repo read-write at its real path. Agent wrappers
  (`claude`, `codex`, `pi`) require a git repository by default; `sb` may use a
  narrow non-git `$PWD`. All wrappers refuse broad roots such as `/` and
  `$HOME`. Set `AISB_WORKSPACE_READONLY=1` for audit/review/exploration runs
  where the agent should not mutate the repo.
- forward API keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`,
  `TOGETHER_API_KEY`, …) and `gh` auth
- mount Claude's host config directory (`~/.claude`) and Codex's host config
  directory (`~/.codex`) read-write so login, token refresh, and atomic config
  writes persist normally. `~/.claude.json` remains repo-scoped. `gh` config is
  mounted **read-only** in normal runs. On SELinux hosts, wrappers ask before
  relabeling the specific auth/config paths needed for container access.
- keep durable per-repo runtime state (repo-scoped config, logs, sessions,
  venvs, uv caches) under `$XDG_STATE_HOME/claude-podman/` and
  `$XDG_CACHE_HOME/claude-podman/` — survives container removal and image
  rebuilds
- run tools with container-local homes (`/home/aisb-claude`,
  `/home/aisb-codex`, `/home/aisb-pi`). Host files still come from your own
  `$HOME`; startup logs show the host path and the container destination for
  each auth/config mount.
- mount a per-invocation `/tmp` from `$XDG_STATE_HOME/claude-podman/` so
  scratch data stays outside the repo without being capped by a small tmpfs.
  Old tmp dirs are pruned on later wrapper starts.
- print a short startup summary to stderr with the workspace, repo config,
  selected image, and resource caps. Set `AISB_DEBUG=1` to include detailed
  mount/auth/hardening diagnostics, or `AISB_QUIET=1` to suppress startup logs.
- do not relabel the workspace mount by default; on SELinux hosts this may
  fail closed with permission denied instead of changing host labels. Set
  `AISB_RELABEL_WORKSPACE=1` only for a narrow project directory that you
  intentionally want Podman to relabel. `AISB_ALLOW_DANGEROUS_ROOT=1` does not
  allow relabeling a broad root; that requires the separate
  `AISB_ALLOW_DANGEROUS_RELABEL=1` escape hatch.

## Hardening

### Host protection

Every container runs with:

- `--userns=keep-id` (no root-in-container)
- `--cap-drop=all` + `--security-opt no-new-privileges`
- `--read-only` rootfs with host-backed per-invocation `/tmp` and tmpfs for
  `/home/<user>`, `/uv-bin`, `/uv-tools`
- Mounts tagged `nosuid,nodev`
- One container per invocation (`--rm`), unique `--name` per session
- Resource caps: `--memory`, `--cpus`, `--pids-limit` (overridable via
  `AISB_MEMORY`, `AISB_CPUS`, `AISB_PIDS`)

The container is the sandbox, so agent-internal approval prompts are bypassed
(`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox`
for Codex). Set `CLAUDE_SAFE_MODE=1` / `CODEX_SAFE_MODE=1` to keep them enabled.

### Host mutation guardrails

The wrappers fail closed for several host-mutation hazards:

- broad workspace roots such as `/`, `/home`, `/tmp`, `$HOME`, the passwd
  database home for the current UID, and rootless container storage paths are
  refused unless `AISB_ALLOW_DANGEROUS_ROOT=1` is set
- SELinux relabeling of broad roots is refused even with
  `AISB_ALLOW_DANGEROUS_ROOT=1`, unless
  `AISB_ALLOW_DANGEROUS_RELABEL=1` is also set
- repo-controlled `.aisb.env`, repo `Containerfile`, and repo pi
  `.pi/agent/models.json` symlinks are refused
- bind mount source or destination paths containing `:` are refused because
  Podman `-v` parsing would be ambiguous
- `AISB_WORKSPACE_READONLY=1` mounts the workspace `ro,nosuid,nodev` for runs
  that should inspect rather than edit files

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
  `AISB_WORKSPACE_READONLY=1` makes the repo mount read-only for review-style
  runs, but normal coding sessions keep it writable so agents can edit files.
- **Strict seccomp is not deletion prevention.** `AISB_STRICT_SECCOMP=1` adds
  syscall denies on top of Podman's default profile, but it cannot block normal
  write, unlink, rename, or truncate operations while the repo mount is
  writable; those are required for ordinary editing workflows.
- **SELinux relabeling is opt-in for the repo.** The wrappers still use
  relabeling for wrapper-owned state/cache directories. They also ask before
  relabeling individual auth/config paths in `$HOME` unless
  `AISB_RELABEL_AUTH=1` is set. The workspace mount is not relabeled unless
  `AISB_RELABEL_WORKSPACE=1` is set. If a previous run accidentally relabeled
  broader `$HOME` content, restore defaults with:

  ```sh
  restorecon -Rv -e "$HOME/.local/share/containers" "$HOME"
  ```

- **Agent-level safety is bypassed.** `--dangerously-skip-permissions` /
  `--dangerously-bypass-approvals-and-sandbox` delegate all behavioral
  boundaries to model alignment. If the model is jailbroken or
  prompt-injected, no in-container check will stop it.

Claude and Codex config directories are writable in normal runs because the
tools may rewrite credentials, settings, and acknowledgements during startup.
`gh` config remains read-only in normal runs. This does not prevent
exfiltration of credentials that the current session can read.

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
| `CLAUDE_NO_CACHE=1`        | Pass `--no-cache` to `podman build` (or use `bin/build-containers --no-cache`). |
| `BASE_IMAGE`               | Override base image tag at build time.                                |
| `AISB_AUTH_WRITE=1`        | Mount the repo read-only during auth-oriented runs.                   |
| `CODEX_AUTH_WRITE=1`       | As above, for `run-codex` only.                                       |
| `PI_AUTH_WRITE=1`          | As above, for `run-pi` only.                                         |
| `AISB_AUTH_WRITE_KEEP_REPO_RW=1` | In auth-write mode, keep the repo writable.                     |
| `AISB_ALLOW_NON_GIT_WORKSPACE=1` | Allow agent wrappers from a non-git `$PWD`.                    |
| `AISB_ALLOW_DANGEROUS_ROOT=1` | Allow broad workspace roots like `$HOME` or `/` intentionally. Does not permit relabeling. |
| `AISB_ALLOW_DANGEROUS_RELABEL=1` | With `AISB_RELABEL_WORKSPACE=1`, allow SELinux relabeling of a dangerous root. |
| `AISB_WORKSPACE_READONLY=1` | Mount the workspace `ro,nosuid,nodev` for audit/review/exploration runs. |
| `AISB_DEBUG=1`             | Include detailed mount/auth/hardening diagnostics in startup logs. |
| `AISB_QUIET=1`             | Suppress wrapper startup summary logs.                            |
| `AISB_RELABEL_AUTH=1`      | Allow wrappers to relabel specific auth/config paths without prompting on SELinux hosts. |
| `AISB_RELABEL_WORKSPACE=1` | Add `:z` to the workspace mount for SELinux relabeling.               |
| `AISB_MEMORY`              | `--memory` cap (default `8g`).                                        |
| `AISB_CPUS`                | `--cpus` cap (default `4`).                                           |
| `AISB_PIDS`                | `--pids-limit` cap (default `1024`).                                  |
| `AISB_NO_NETWORK=1`        | `run-sb` only: disable all networking (`--network=none`).             |
| `AISB_STRICT_SECCOMP=1`    | Apply `seccomp-strict.json` (extra denies on top of podman default).  |
| `AISB_SECCOMP_PROFILE`     | Path to custom seccomp profile (overrides `seccomp-strict.json`).     |

For a first-time Codex OAuth login, run:

```sh
codex login --device-auth
```

### Repo-specific base images

A project can opt into its own sandbox base image by adding a `Containerfile`
at the repo root. When `bin/build-containers` is run from that project, or with
`AISB_WORKSPACE=/path/to/project`, it builds `./Containerfile` as a deterministic
repo-scoped base image:

```sh
localhost/aisb-<repo-name>-<repo-hash>:latest
```

If `.aisb.env` does not already name a base image, interactive builds prompt to
create or update it with that generated tag:

```sh
AISB_BASE_IMAGE=localhost/aisb-<repo-name>-<repo-hash>:latest
```

You can also choose your own existing base image by adding `.aisb.env` manually
at the repo root:

```sh
AISB_BASE_IMAGE=localhost/my-project-aisb-base:latest
```

The file is parsed as data, not sourced as shell. Blank lines and comments are
allowed; currently only `AISB_BASE_IMAGE` is recognized.

When a repo-specific base image is active:

- `sb` runs that image directly unless `SB_IMAGE` is set.
- `claude`, `codex`, and `pi` use repo-scoped derived images built from that
  base, such as `localhost/aisb-codex-<repo-hash>:latest`, unless their
  per-wrapper image override is set.
- `bin/build-containers` builds `./Containerfile` into the generated base tag
  when that file is the source of the repo base image. For manually configured
  `AISB_BASE_IMAGE` values, it expects that image to already exist.
- `bin/build-containers` uses the repo base as the `BASE_IMAGE` build arg for
  derived tool images and tags those images with the same repo-scoped names the
  wrappers expect.

Derived tool images install a shared agent toolbox on top of the repo base,
without changing the repo base image itself. The `codex` and `pi` images also
install Node.js/npm in their own image before installing their CLI packages.
This requires the repo base to have one supported package manager: `microdnf`,
`dnf`, `apt-get`, or `apk`.

Build repo-specific tool images from inside the project repo, or point the build
script at the project explicitly:

```sh
AISB_WORKSPACE=/path/to/project /path/to/aisb/bin/build-containers all
```

Explicit environment overrides keep precedence: `SB_IMAGE`, `CLAUDE_IMAGE`,
`CODEX_IMAGE`, and `PI_IMAGE` override wrapper selection; `BASE_IMAGE` overrides
the base image used by `bin/build-containers`.

[podman]: https://podman.io
[direnv]: https://direnv.net
[pass]: https://www.passwordstore.org
