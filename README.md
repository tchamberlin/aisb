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
| `.envrc`               | [direnv] hook: pulls API keys via [pass] into the shell.                 |

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
- bind-mount per-agent auth from the host (`~/.claude`, `~/.codex`, `~/.pi`)
- use per-repo `uv` caches + a fresh venv per invocation under
  `$XDG_STATE_HOME/claude-podman/`

## Hardening

Every container runs with:

- `--userns=keep-id` (no root-in-container)
- `--cap-drop=all` + `--security-opt no-new-privileges`
- `--read-only` rootfs with tmpfs for `/tmp`, `/home/<user>`, `/uv-bin`, `/uv-tools`
- Mounts tagged `nosuid,nodev`
- One container per invocation (`--rm`), unique `--name` per session

The container is the sandbox, so agent-internal approval prompts are bypassed
(`--dangerously-skip-permissions` for Claude, `--dangerously-bypass-approvals-and-sandbox`
for Codex). Set `CLAUDE_SAFE_MODE=1` / `CODEX_SAFE_MODE=1` to keep them enabled.

## Environment

`.envrc` expects [pass] entries at `api/openai`, `api/anthropic`, `api/together`,
`api/openrouter`. Adjust or replace to taste — any mechanism that exports the
API key env vars before invoking a wrapper will work.

Per-wrapper overrides:

| Var                   | Effect                                   |
| --------------------- | ---------------------------------------- |
| `CLAUDE_IMAGE`        | Override image tag for `run-claude`.     |
| `CODEX_IMAGE`         | Override image tag for `run-codex`.      |
| `PI_IMAGE`            | Override image tag for `run-pi`.         |
| `SB_IMAGE`            | Override image tag for `run-sb`.         |
| `CLAUDE_SAFE_MODE=1`  | Keep Claude's built-in permission prompts. |
| `CODEX_SAFE_MODE=1`   | Keep Codex's built-in approvals + sandbox. |
| `CLAUDE_NO_CACHE=1`   | Pass `--no-cache` to `podman build`.     |
| `BASE_IMAGE`          | Override base image tag at build time.   |

[podman]: https://podman.io
[direnv]: https://direnv.net
[pass]: https://www.passwordstore.org
