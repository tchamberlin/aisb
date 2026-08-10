# aisb

**This repository is in an alpha state. I make no guarantees as to its correctness or utility. I will make breaking changes without notice**

**A**I **s**and**b**ox — run coding agents (Claude Code, Codex, pi, the
[Herdr] agent multiplexer, or a plain shell) inside a hardened rootless
[podman] container. Each invocation gets a fresh container; only the current
repo and per-agent auth/config are mounted.

## What's here

| File                   | What it is                                                                 |
| ---------------------- | -------------------------------------------------------------------------- |
| `Containerfile.base`   | Fedora-minimal base: full CLI toolbox, Node 24, Python 3.14, uv, build tools. |
| `Containerfile.claude` | Derived Claude image: base + shared agent toolbox + Claude Code.           |
| `Containerfile.codex`  | Derived Codex image: base + shared agent toolbox + Node/npm + Codex.       |
| `Containerfile.pi`     | Derived pi image: base + shared agent toolbox + Node/npm + pi.             |
| `Containerfile.herdr`  | Derived Herdr image: base + shared agent toolbox + Herdr + the whole herd (Claude Code, Codex, pi). |
| `bin/build-containers` | Build one or all images. Parallelizes derived image builds by default.     |
| `bin/run-claude`       | Run Claude Code against the current repo.                                   |
| `bin/run-codex`        | Run Codex against the current repo.                                         |
| `bin/run-pi`           | Run pi against the current repo.                                            |
| `bin/run-herdr`        | Run Herdr (agent multiplexer) against the current repo.                     |
| `bin/run-sb`           | Generic sandboxed shell / command runner on the base image.                |
| `bin/_run-common.sh`   | Shared wrapper logic (hardening flags, mounts, guardrails, update checks). |
| `bin/_repo-config.sh`  | Repo config + image-resolution helpers (`.aisb.env`, repo bases).          |
| `container/`           | In-image install scripts (Node/npm, uv Python tools, agent runtime deps).  |
| `install.sh`           | Symlink `claude`/`codex`/`pi`/`herdr`/`sb`/`aisb-build` into `~/.local/bin`. |
| `seccomp-strict.json`  | Optional seccomp profile (default + extra denies). Enable via env var.      |
| `examples/playwright/` | Example repo `Containerfile` layering Playwright on the base.               |
| `.envrc.example`       | Sample [direnv] hook that pulls API keys via [pass]. Copy to `.envrc`.      |

### What's in the base image

`Containerfile.base` starts from a digest-pinned Fedora 43 minimal and installs a
batteries-included toolbox so agents rarely need to install anything at runtime:

- **Search / view:** ripgrep, fd-find, fzf, tree, less, jq, vim
- **Text / diff:** gawk, sed, patch, diffutils, findutils, ShellCheck, xxd
- **Archives:** unzip, zip, tar, xz, bzip2, gzip
- **PDF:** pdfgrep, poppler-utils
- **Process / debug:** procps-ng, psmisc, lsof, strace
- **Network:** iproute, bind-utils, nmap-ncat, openssl, curl, openssh-clients
- **Build toolchain:** make, gcc/g++, pkgconf, cmake, ninja-build, plus
  openssl/libffi/zlib headers, ncurses, glib2, ffmpeg
- **Git / GitHub:** git, `gh`
- **Languages:** Python 3.14 (+devel), Node.js 24 LTS (verified upstream tarball),
  uv (Astral)
- **Linters / formatters:** ruff, ty, prek (via `uv tool`), Biome (via npm)

Derived agent images layer a shared agent toolbox on top of whatever base is in
use (re-installing the core CLI tools, ruff/ty/prek, and — for Codex and pi —
Node/npm), then install the agent CLI itself.

## Install

```sh
./install.sh                # symlinks ~/.local/bin/{claude,codex,pi,herdr,sb,aisb-build}
aisb-build all              # ensure base exists, then build the flavors (parallel)
aisb-build --no-cache       # rebuild without the podman layer cache
AISB_BUILD_SEQUENTIAL=1 aisb-build all
```

Requires: `podman`, `bash`, `curl`, `node`, and `npm` (for version-pin lookups
in `build-containers`).

Add `~/.local/bin` to your `PATH` if it isn't already.

## Use

From inside any repo:

```sh
claude                          # interactive Claude Code
codex                           # interactive Codex
pi                              # interactive pi
herdr                           # Herdr multiplexer with claude/codex/pi inside
sb                              # interactive bash in the sandbox
sb uv run script.py             # one-shot command in the sandbox
```

The wrappers:

- **Mount the current repo read-write at its real path.** Agent wrappers
  (`claude`, `codex`, `pi`, `herdr`) require a git repository by default; `sb` may use a
  narrow non-git `$PWD`. All wrappers refuse broad roots such as `/` and
  `$HOME`. Set `AISB_WORKSPACE_READONLY=1` for audit/review/exploration runs
  where the agent should not mutate the repo.
- **Forward the API keys each tool understands** (not a single blanket set):
  - `claude` → `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`
  - `codex` → `OPENAI_API_KEY`
  - `pi` → `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`,
    `OPENROUTER_API_KEY`, `TOGETHER_API_KEY`, plus any vars named in its env
    file (see below) and `PI_*` tuning vars
  - `herdr` → `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY`,
    `GOOGLE_API_KEY`, `OPENROUTER_API_KEY`, `TOGETHER_API_KEY`, plus any vars
    named in pi's env file (see below) and `PI_*` tuning vars — the union of
    what its bundled agents understand
  - `sb` → `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GOOGLE_API_KEY`,
    `OPENROUTER_API_KEY`, `TOGETHER_API_KEY`, `GROQ_API_KEY`, `HF_TOKEN`,
    `QWEN_MODEL`

  All wrappers also forward `GH_TOKEN` (when set) for GitHub CLI auth, your
  `VISUAL`/`EDITOR` preference (defaulting `EDITOR=vim` when unset), and your
  host `git config user.name`/`user.email` as `GIT_AUTHOR_*`/`GIT_COMMITTER_*`
  so commits made in the container carry your identity.
- **Persist each agent's home read-write, shared across every repo.** Claude,
  Codex, pi, and Herdr each get one durable home directory (seeded from your host
  dotfiles on first use, then owned by AISB) mounted rw so login, token refresh,
  MCP changes, skills, and atomic config writes persist — a single login carries
  across all repos. On SELinux hosts, wrappers ask before relabeling the
  specific auth/config paths needed for container access.
- **Mount shared, read-only helper directories** into the agent home when they
  exist on the host: `~/.agents` (cross-agent config), and per-tool skills
  (`~/.claude/skills`, `~/.pi/skills`).
- **Keep durable runtime state** under `$XDG_STATE_HOME/claude-podman/` and
  `$XDG_CACHE_HOME/claude-podman/`. Agent homes (auth, settings, MCP, sessions)
  are shared across all repos; per-repo state (workspace caches, venvs, uv
  caches, logs) is scoped by repo hash. Both survive container removal and image
  rebuilds.
- **Mask an existing repo `.venv`** with an empty per-run mount so the container
  cannot read or mutate the host virtualenv. Python tooling should use the
  wrapper-managed uv environment (`/aisb-<tool>/venv` for agents, `/venv` for
  `sb`) instead. Symlinked or non-directory `.venv` paths fail closed.
- **Run tools with container-local homes** (`/home/aisb-claude`,
  `/home/aisb-codex`, `/home/aisb-pi`, `/home/aisb-herdr`, `/home/sb`). Startup logs show the host
  path and container destination for each auth/config mount.
- **Mount a per-invocation `/tmp`** from `$XDG_STATE_HOME/claude-podman/` so
  scratch data stays outside the repo without being capped by a small tmpfs.
  Old tmp dirs are pruned on later wrapper starts.
- **Print a short startup summary to stderr** with the workspace, repo config,
  selected image, and resource caps. Set `AISB_DEBUG=1` for detailed
  mount/auth/hardening diagnostics, or `AISB_QUIET=1` to suppress startup logs.
- **Refuse to start Codex unauthenticated.** If no `OPENAI_API_KEY` is set and
  the shared Codex auth file is empty, `run-codex` stops with instructions
  (except for `login`/`help`/`--version`-style commands).
- **Disable the agents' own self-update paths.** AISB-managed images are the
  update boundary: wrappers check upstream for newer agent versions (npm, or
  the herdr.dev release manifest for `herdr`) at most once per
  hour and, in interactive runs, prompt to rebuild the managed image before
  continuing. Declining continues with the current image and snoozes the check
  for the rest of the TTL window. Non-interactive runs just print the exact
  `bin/build-containers <tool>` command and continue.
- **Prompt to rebuild stale images.** Wrappers compare the current build recipe,
  repo `Containerfile`, and base-image id against the image's metadata; if the
  image looks older than the current AISB code, interactive runs offer a rebuild
  and non-interactive runs warn and continue.
- **Optionally publish container ports** at startup with `AISB_PUBLISH_PORTS`.
  For example, to make a Vite server listening on `0.0.0.0:5173` inside Codex
  reachable from the host only on loopback:

  ```sh
  AISB_PUBLISH_PORTS=127.0.0.1:5173:5173 codex
  ```

  Each field accepts an inclusive range (`start-end`) as well as a single port,
  so you can reserve a band up front and let the agent run a dev server on any
  port in it without knowing the exact port ahead of time:

  ```sh
  AISB_PUBLISH_PORTS=127.0.0.1:3000-3010:3000-3010 codex
  ```

  When both the host and container sides are ranges they must span the same
  number of ports. Once a loopback port is published, browsers and
  systemd-resolved resolve any `*.localhost` name to loopback, so you can reach
  it at e.g. `http://myrepo.localhost:3000` without editing `/etc/hosts`. Port
  publishing is a `podman run` option, so it cannot be added to an
  already-running container.
- **Optionally bridge the host clipboard** with `AISB_CLIPBOARD=1`. By default
  the container has no clipboard channel: TUIs "copy" into an app-internal
  buffer that never reaches the host, and image paste fails because the agent
  cannot read the host clipboard (plain text paste works — it is just terminal
  input). The bridge spawns a small host-side helper for the session that
  serves copy/paste over FIFOs under the per-run `/tmp` mount (FIFOs rather
  than a unix socket so SELinux-confined containers can use it), and puts
  `wl-copy`/`wl-paste`/`xclip` shims on the container `PATH`. Tools that shell
  out for clipboard access — Claude Code image paste (Ctrl+V), TUI copy —
  then work in both directions, for text and images, without the container ever
  seeing the compositor socket:

  ```sh
  AISB_CLIPBOARD=1 herdr
  ```

  This intentionally grants the agent read/write access to the host clipboard
  (see Hardening), so it is opt-in per run and only via the environment —
  `.aisb.env` cannot enable it. Both the clipboard and the middle-click
  primary selection are bridged (middle-click *paste into* container apps
  works even without the bridge — the terminal injects it as input; the
  bridge covers apps that set or read the primary selection themselves). Only
  `text/*` and `image/*` clipboard types are bridged, transfers are capped at
  32 MiB, and the helper exits with the session. Requires `wl-clipboard` (Wayland) or `xclip` (X11) on the host.
  Tools that speak the Wayland/X11 clipboard protocol natively instead of
  shelling out are not covered. The helper logs to
  `.aisb-clipboard/helper.log` under the per-run tmp dir (path shown with
  `AISB_DEBUG=1`); per-request logging with `AISB_DEBUG=1`.
- **Ask before marking a repo container-readable** the first time an agent
  wrapper runs there on SELinux hosts. Approval is remembered per repo under
  AISB state and future runs mount the workspace with Podman's `:z` relabel
  option. Set `AISB_RELABEL_WORKSPACE=1` to approve noninteractively for a narrow
  project directory. `AISB_ALLOW_DANGEROUS_ROOT=1` does not allow relabeling a
  broad root; that requires the separate `AISB_ALLOW_DANGEROUS_RELABEL=1`
  escape hatch.

### pi provider keys via a central env file

pi has no interactive login flow, so API keys are its only auth path. Besides the
provider vars listed above, `run-pi` optionally sources a user-owned env file at:

```sh
${XDG_CONFIG_HOME:-$HOME/.config}/aisb/pi.env
```

The file must be a non-symlink regular file with no group/other access
(`chmod 600`). Any `KEY=value` (or `export KEY=value`) assignments in it are
sourced and forwarded into the container — handy for provider keys, base-URL
overrides, or model overrides that AISB doesn't know about by name. This keeps
pi's keys available regardless of the calling shell.

## Hardening

### Host protection

Every container runs with:

- `--userns=keep-id` (no root-in-container)
- `--cap-drop=all` + `--security-opt no-new-privileges`
- `--read-only` rootfs with a host-backed per-invocation `/tmp`; `sb` also gets
  a tmpfs home for non-durable shell/config scratch
- Mounts tagged `nosuid,nodev` (shared read-only mounts also `noexec`)
- One container per invocation (`--rm`), unique `--name` per session
- `--pull=never` so a run never silently pulls a remote image
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
  `AISB_ALLOW_DANGEROUS_ROOT=1`, unless `AISB_ALLOW_DANGEROUS_RELABEL=1` is also
  set
- repo-controlled `.aisb.env`, repo `Containerfile`, and repo pi
  `.pi/agent/models.json` symlinks are refused
- bind mount source or destination paths containing `:` are refused because
  Podman `-v` parsing would be ambiguous
- `AISB_EXTRA_MOUNTS` entries from `.aisb.env` are validated before mounting:
  broad host paths, symlinks, missing sources, paths inside the workspace,
  reserved container paths, and unknown options are refused; mounts default to
  `ro` and always include `nosuid,nodev`
- `AISB_WORKSPACE_READONLY=1` mounts the workspace `ro,nosuid,nodev` for runs
  that should inspect rather than edit files
- an existing repo `.venv` directory is hidden behind an empty per-run mount;
  symlinked or non-directory `.venv` paths fail closed rather than entering the
  container
- state-directory pruning is confined to the `claude-podman` state base and
  refuses to touch broad or out-of-tree paths

### What this does not protect against

The host is isolated from the agent, but the agent still operates with
substantial trust *inside* the container. Understand these before trusting the
sandbox with sensitive material:

- **Live credentials inside the container.** Each run has access to the API keys
  forwarded via env, the per-agent auth files (`~/.claude/.credentials.json`,
  `~/.codex/auth.json`, `~/.pi/agent/*`), and optionally `GH_TOKEN`. A
  prompt-injection in repo content or tool output can, in one command,
  exfiltrate any of these.
- **Full network egress.** Containers have unrestricted outbound network. Any
  exfiltration path (DNS, HTTPS, anything else) is open. For one-shot `sb` runs
  you can set `AISB_NO_NETWORK=1` to drop all networking; agent wrappers need the
  network for API calls and do not support this.
- **Published ports are opt-in ingress.** `AISB_PUBLISH_PORTS` adds
  host-to-container access for new runs. Prefer loopback bindings such as
  `127.0.0.1:5173:5173`; binding to `0.0.0.0` can expose the service to other
  machines that can reach the host.
- **The clipboard bridge is opt-in clipboard exposure.** With `AISB_CLIPBOARD=1`
  the agent can read whatever you copy — or, via the primary selection, merely
  *select* — on the host while the session runs (passwords, tokens) and can
  replace clipboard contents you later paste into a host shell (clipboard
  poisoning). The bridge never exposes the compositor
  socket — only a text/image copy/paste protocol — but treat those two risks as
  the price of image paste. Leave it off for sessions touching untrusted repo
  content.
- **The mounted repo is read-write.** An agent can modify files, commit, and (if
  `GH_TOKEN` is present) push malicious commits upstream.
  `AISB_WORKSPACE_READONLY=1` makes the repo mount read-only for review-style
  runs, but normal coding sessions keep it writable so agents can edit files.
- **Strict seccomp is not deletion prevention.** `AISB_STRICT_SECCOMP=1` adds
  syscall denies on top of Podman's default profile, but it cannot block normal
  write, unlink, rename, or truncate operations while the repo mount is
  writable; those are required for ordinary editing workflows.
- **SELinux relabeling is opt-in for the repo.** The wrappers still use
  relabeling for wrapper-owned state/cache directories. They also ask before
  relabeling individual auth/config paths in `$HOME` unless `AISB_RELABEL_AUTH=1`
  is set. For workspaces, agent wrappers prompt once per repo before using
  Podman's `:z` relabel option and remember that approval under
  `$XDG_STATE_HOME/claude-podman/workspaces/`. If a previous run accidentally
  relabeled broader `$HOME` content, restore defaults with:

  ```sh
  restorecon -Rv -e "$HOME/.local/share/containers" "$HOME"
  ```

- **Agent-level safety is bypassed.** `--dangerously-skip-permissions` /
  `--dangerously-bypass-approvals-and-sandbox` delegate all behavioral
  boundaries to model alignment. If the model is jailbroken or prompt-injected,
  no in-container check will stop it.

Agent config directories are writable in normal runs because the tools may
rewrite credentials, settings, and acknowledgements during startup. This does
not prevent exfiltration of credentials the current session can read.

## Environment

Copy `.envrc.example` to `.envrc` and run `direnv allow`, or supply your own
mechanism. The example pulls from [pass] (`api/openai`, `api/anthropic`,
`api/together`, `api/openrouter`) — adjust or replace to taste. Any mechanism
that exports the API key env vars before invoking a wrapper will work. Local
`.envrc` is gitignored.

Per-wrapper and per-run overrides:

| Var                        | Effect                                                                |
| -------------------------- | --------------------------------------------------------------------- |
| `CLAUDE_IMAGE`             | Override image tag for `run-claude`.                                  |
| `CODEX_IMAGE`              | Override image tag for `run-codex`.                                  |
| `PI_IMAGE`                 | Override image tag for `run-pi`.                                     |
| `HERDR_IMAGE`              | Override image tag for `run-herdr`.                                  |
| `SB_IMAGE`                 | Override image tag for `run-sb`.                                     |
| `CLAUDE_SAFE_MODE=1`       | Keep Claude's built-in permission prompts.                          |
| `CODEX_SAFE_MODE=1`        | Keep Codex's built-in approvals + sandbox.                          |
| `CLAUDE_NO_CACHE=1`        | Pass `--no-cache` to `podman build` (or use `aisb-build --no-cache`). |
| `AISB_BUILD_SEQUENTIAL=1`  | Build `claude`, `codex`, `pi`, and `herdr` sequentially for `aisb-build all`; useful for debugging constrained repo bases. |
| `BASE_IMAGE`               | Override base image tag at build time.                              |
| `AISB_AUTH_WRITE=1`        | Auth-oriented run: mount the repo read-only by default (per-tool `CODEX_AUTH_WRITE`/`PI_AUTH_WRITE` also work). |
| `AISB_AUTH_WRITE_KEEP_REPO_RW=1` | In auth-write mode, keep the repo writable.                    |
| `AISB_ALLOW_NON_GIT_WORKSPACE=1` | Allow agent wrappers from a non-git `$PWD`.                    |
| `AISB_ALLOW_DANGEROUS_ROOT=1` | Allow broad workspace roots like `$HOME` or `/` intentionally. Does not permit relabeling. |
| `AISB_ALLOW_DANGEROUS_RELABEL=1` | With `AISB_RELABEL_WORKSPACE=1`, allow SELinux relabeling of a dangerous root. |
| `AISB_WORKSPACE_READONLY=1` | Mount the workspace `ro,nosuid,nodev` for audit/review/exploration runs. |
| `GH_TOKEN`                  | Forward this token for GitHub CLI auth. Host `gh` OAuth state and `GITHUB_TOKEN` are not forwarded. |
| `AISB_STARTUP='<cmd>'`     | Run a command inside the container before the agent starts, for base images that ship services (a database, a broker, `rpcbind`) which cannot start themselves because aisb replaces the image `ENTRYPOINT`. Runs as the agent user, in the workspace; a non-zero exit aborts the run. Environment-only, like `AISB_CLIPBOARD` and for a stronger reason: it executes a command, so honoring it from the agent-writable `.aisb.env` would let an agent choose what runs at the start of the next session. |
| `AISB_DEBUG=1`             | Include detailed mount/auth/hardening diagnostics in startup logs.  |
| `AISB_QUIET=1`             | Suppress wrapper startup summary logs.                             |
| `AISB_UPDATE_CHECK=0`      | Disable AISB-managed agent version checks on wrapper startup.       |
| `AISB_UPDATE_CHECK_TTL_SECONDS` | Cache TTL for npm latest-version checks and the rebuild prompt (default `3600`). |
| `AISB_RESET_HOME=1`        | Wipe the per-tool shared home dir (recovers from sub-uid-owned files podman left behind). |
| `AISB_RELABEL_AUTH=1`      | Allow wrappers to relabel specific auth/config paths without prompting on SELinux hosts. |
| `AISB_RELABEL_WORKSPACE=1` | Add `:z` to the workspace mount for SELinux relabeling without prompting. |
| `AISB_MEMORY`              | `--memory` cap (default `8g`).                                       |
| `AISB_CPUS`                | `--cpus` cap (default `4`).                                          |
| `AISB_PIDS`                | `--pids-limit` cap (default `1024`).                                 |
| `AISB_PUBLISH_PORTS`       | Whitespace-separated Podman `-p` specs for new runs, e.g. `127.0.0.1:5173:5173`. Each port field may be an inclusive range (`127.0.0.1:3000-3010:3000-3010`); host/container ranges must span equal counts. |
| `AISB_NO_NETWORK=1`        | `run-sb` only: disable all networking (`--network=none`).           |
| `AISB_STRICT_SECCOMP=1`    | Apply `seccomp-strict.json` (extra denies on top of podman default). |
| `AISB_SECCOMP_PROFILE`     | Path to custom seccomp profile (overrides `seccomp-strict.json`).    |
| `AISB_CLIPBOARD=1`         | Bridge the host clipboard into the container (text + images, both directions) via a per-session helper and `wl-copy`/`wl-paste`/`xclip` shims. Grants the agent host-clipboard read/write; environment-only (ignored in `.aisb.env`). Off by default. |
| `AISB_CLIPBOARD_BACKEND`   | Force the helper's host backend: `wayland`, `x11`, or `test` (auto-detected by default). |
| `AISB_GPU=1`               | Pass the host GPU through: `--device /dev/dri --group-add keep-groups`. Lets Chromium/Mesa use the iGPU for hardware WebGL (else llvmpipe/SwiftShader). Host user must be in the `render` group. Off by default. |
| `AISB_GPU_DEVICE`          | DRM device to expose when `AISB_GPU=1` (default `/dev/dri`).         |
| `AISB_GPU_DISABLE_LABEL=1` | With `AISB_GPU=1`, also add `--security-opt label=disable` for SELinux-enforcing hosts that block device access. Last resort — prefer `sudo setsebool -P container_use_devices 1`, which permits device access while keeping the container SELinux-confined. |

For a first-time Codex OAuth login, run:

```sh
codex login --device-auth
```

### Herdr notes

- The `herdr` flavor bundles Claude Code, Codex, and pi inside one image so
  Herdr has agents to multiplex; all four versions are pinned at image build
  time, and the wrapper's update check follows the Herdr binary via the
  herdr.dev release manifest.
- Herdr's durable home is separate from the per-tool homes used by
  `claude`/`codex`/`pi`. It is seeded from your host dotfiles on first use, so
  logins performed in the standalone wrappers after that do not automatically
  appear inside Herdr — log in once inside a Herdr pane, or rely on forwarded
  API keys.
- Agents launched inside Herdr run with their native approval prompts; the
  container is still the sandbox, but the standalone wrappers' bypass flags
  (`--dangerously-skip-permissions` etc.) are not injected. Configure Herdr's
  agent arguments if you want them.
- The Herdr server runs inside the per-run container: detach/reattach works
  while the container is alive, but panes and sessions end when the container
  exits. Session metadata in the durable home survives.

### Repo-specific base images

A project can opt into its own sandbox base image by adding a `Containerfile`
at the repo root. When `bin/build-containers` is run from that project, or with
`AISB_WORKSPACE=/path/to/project`, it builds `./Containerfile` as a deterministic
repo-scoped base image:

```sh
localhost/aisb-<repo-name>-<repo-hash>:latest
```

If all a repo needs is a few extra packages, you can skip the `Containerfile`
entirely and declare them in `.aisb.env` with `AISB_NPM_PACKAGES` and/or
`AISB_PYTHON_TOOLS` (see the recognized keys below). AISB generates a base image
with the same repo-scoped tag, layered on `localhost/aisb-base:latest`.

If `.aisb.env` does not already name a base image, interactive builds prompt to
create or update it with that generated tag after the managed base image is
available:

```sh
AISB_BASE_IMAGE=localhost/aisb-<repo-name>-<repo-hash>:latest
```

You can also choose your own existing base image by adding `.aisb.env` manually
at the repo root:

```sh
AISB_BASE_IMAGE=localhost/my-project-aisb-base:latest
```

The file is parsed as data, not sourced as shell. Blank lines and comments are
allowed. Recognized keys:

- `AISB_BASE_IMAGE` — base image tag (see above).
- `AISB_NPM_PACKAGES` — whitespace-separated npm package specs installed globally
  (`npm install -g`) into a generated repo base image, e.g.
  `AISB_NPM_PACKAGES=playwright prettier`.
- `AISB_PYTHON_TOOLS` — whitespace-separated Python tool specs installed with
  `uv tool install` into the same generated base, e.g.
  `AISB_PYTHON_TOOLS=httpie`.

  These two keys take effect only when the repo has no `Containerfile` and no
  explicit `AISB_BASE_IMAGE` (those paths already give the repo full control, so
  the package keys are ignored with a warning if combined). When present, AISB
  compiles them into a generated base image
  (`localhost/aisb-<repo-name>-<repo-hash>:latest`) layered on
  `localhost/aisb-base:latest`, builds the default base first if needed, and the
  agent images derive from it the same way they do for a repo `Containerfile`.
  The package list is folded into the image's recipe fingerprint, so editing
  `.aisb.env` marks the generated base stale. Tool and `all` builds prompt before
  refreshing a stale existing base and default to reusing it. Each token is
  passed verbatim to `npm`/`uv` and validated first: tokens containing a single
  quote or backslash, or starting with `-`, are rejected to prevent command
  injection.
- `AISB_ALLOW_NON_GIT_WORKSPACE` — set to `1` to let agent wrappers run with
  this directory as the workspace even when it is not a git repository.
  Equivalent to the host env var of the same name, but scoped to the repo.
- `AISB_EXTRA_MOUNTS` — extra host bind mounts. Each value is one or more
  whitespace-separated entries; the key may also be repeated on multiple lines.
  A path containing spaces (e.g. an external volume named `T7 Shield`) can be
  wrapped in single or double quotes so it is treated as one entry. Each entry
  takes one of these forms:
  - `/host/path` — mount at the same path inside the container
  - `/host/path:opts` — same-path mount with custom options
  - `/host/path:/container/path` — explicit mapping
  - `/host/path:/container/path:opts` — mapping with options

  Default options are `ro`; supported flags are `ro`, `rw`, `z`, `Z`, `noexec`.
  The wrappers always force `nosuid,nodev` and reject:
  - relative or `..`-bearing paths, and paths containing `:`, `,`, a tab, or a
    newline (`:` and `,` are Podman `-v` field separators; spaces are allowed)
  - host paths that don't exist, are symlinks, sit inside the workspace, or are
    broad locations like `/`, `$HOME`, `/etc`, `/tmp` (mount a narrower
    subdirectory instead)
  - container paths that overlap reserved mount points (`$ROOT`, the user home,
    `/aisb-<tool>`, `/uv-tools`, `/uv-bin`, `/tmp`, and for `sb` the
    `/uv-cache`, `/uv-python`, `/venv`, `/home/sb` paths)

  Examples:

  ```sh
  AISB_EXTRA_MOUNTS=/home/foo /srv/datasets
  AISB_EXTRA_MOUNTS=/var/tmp/scratch:rw
  AISB_EXTRA_MOUNTS=/srv/cache:/data:rw
  AISB_EXTRA_MOUNTS=/home/gbtlogs /home/gbtdata "/run/media/me/T7 Shield"
  ```

When a repo-specific base image is active:

- `sb` runs that image directly unless `SB_IMAGE` is set.
- `claude`, `codex`, `pi`, and `herdr` use repo-scoped derived images built from
  that base, such as `localhost/aisb-codex-<repo-hash>:latest`, unless their
  per-wrapper image override is set.
- `bin/build-containers` builds `./Containerfile` into the generated base tag
  when that file is the source of the repo base image. For manually configured
  `AISB_BASE_IMAGE` values, it expects that image to already exist.
- `bin/build-containers` uses the repo base as the `BASE_IMAGE` build arg for
  derived tool images and tags those images with the same repo-scoped names the
  wrappers expect.
- When a derived tool or `all` build sees an existing managed base image that
  looks stale, interactive runs ask whether to refresh it and default to `no`.
  Non-interactive runs warn and reuse the existing base. If the base image is
  missing, AISB builds managed bases first because Podman needs a concrete image
  for `FROM`.

Derived tool images install a shared agent toolbox on top of the repo base,
without changing the repo base image itself. The `codex`, `pi`, and `herdr`
images also install Node.js/npm in their own image before installing their CLI
packages.
The shared toolbox includes `prek`, installed to `/usr/local/bin` so it remains
available independently of wrapper-managed uv tool directories. This requires
the repo base to have one supported package manager: `microdnf`, `dnf`,
`apt-get`, or `apk`.

Build smoke-test checklist for repo-derived images:

- default path with no repo `Containerfile`
- Fedora or Fedora-minimal repo base using `microdnf`
- Debian or Ubuntu repo base using `apt-get`
- Alpine repo base using `apk`
- unsupported repo base with no package manager; `claude`, `codex`, `pi`, and
  `herdr` builds should fail with the supported package-manager message, while
  `sb` can still run the repo image directly

Build repo-specific tool images from inside the project repo, or point the build
script at the project explicitly:

```sh
AISB_WORKSPACE=/path/to/project aisb-build all
```

Explicit environment overrides keep precedence: `SB_IMAGE`, `CLAUDE_IMAGE`,
`CODEX_IMAGE`, `PI_IMAGE`, and `HERDR_IMAGE` override wrapper selection;
`BASE_IMAGE` overrides the base image used by `bin/build-containers`.

For AISB-managed images, the wrappers compare the current build recipe against
image metadata from the last build. In interactive runs, if the image looks
older than the current AISB code or repo `Containerfile`, AISB prompts to rebuild
it before continuing. In non-interactive runs, it warns and keeps going.

[podman]: https://podman.io
[direnv]: https://direnv.net
[pass]: https://www.passwordstore.org
[Herdr]: https://herdr.dev
</content>
</invoke>
