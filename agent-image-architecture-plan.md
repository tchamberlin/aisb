# Agent Image Architecture Plan

## Decision

Keep the repo `Containerfile` as the source of truth for the environment the
repo code runs in. AISB should centralize wrapper behavior and build
orchestration, but it should not require repo `Containerfile`s to inherit from
an AISB base image.

The derived agent images are intentionally not identical to the repo runtime
image. They are agent-capable images built on top of the repo image.

```text
run-sb      -> repo image exactly
run-claude  -> repo image + AISB agent toolbox + Claude
run-codex   -> repo image + AISB agent toolbox + Node/npm + Codex
run-pi      -> repo image + AISB agent toolbox + Node/npm + pi-coding-agent
```

This is the same basic model as the old per-repo `podman_utils` setup, but with
the wrappers, state layout, image naming, version resolution, and agent toolbox
installation consolidated in AISB.

## Goals

- Preserve arbitrary repo `Containerfile` semantics.
- Let `run-sb` execute in the repo image without agent additions.
- Let `run-claude`, `run-codex`, and `run-pi` add the tools agents realistically
  need.
- Keep Claude/Codex/PI auth, state, mounts, and wrapper behavior centralized.
- Make supported and unsupported base-image behavior explicit.
- Avoid pretending derived agent images are pure repo runtime images.

## Non-Goals

- Do not require repos to inherit from `localhost/aisb-base:latest`.
- Do not convert repo `Containerfile`s into fragments.
- Do not support every possible container base, such as scratch, distroless, or
  images with no package manager.
- Do not copy broad OS toolboxes between unrelated image lineages.

## Supported Base Contract

Repo images may be arbitrary, but derived agent images require enough OS support
to install the AISB agent toolbox. The supported package managers are:

```text
microdnf
dnf
apt-get
apk
```

If none is available, derived agent-image builds should fail with a clear error.
`run-sb` can still use the repo image directly.

The practical contract for agent images is:

- `claude`, `codex`, and `pi` images install the shared agent toolbox.
- `codex` and `pi` images install Node.js/npm before their CLI package.
- `claude` uses the upstream installer after the shared toolbox provides `curl`,
  `bash`, and related basics.
- The repo base image itself is not modified.

## Current Implementation Direction

Use a shared script:

```text
container/install-agent-runtime-deps.sh
```

Each derived agent `Containerfile` copies and runs that script before installing
the tool-specific CLI.

Expected tool-specific layers:

```text
Containerfile.claude:
  FROM ${BASE_IMAGE}
  install shared agent toolbox
  install Claude

Containerfile.codex:
  FROM ${BASE_IMAGE}
  install shared agent toolbox
  install Node/npm
  install Codex

Containerfile.pi:
  FROM ${BASE_IMAGE}
  install shared agent toolbox
  install Node/npm
  install pi-coding-agent
```

## Agent Toolbox Contents

The shared toolbox should include practical agent/runtime utilities, not every
package from the default AISB base.

Initial scope:

```text
ca-certificates
curl
git
openssh client
bash
which
ripgrep
less
jq
unzip
zip
tar
xz
gzip
patch
diffutils
findutils
coreutils
procps
iproute
```

Package names vary by distro family. The script owns that mapping.

## Cleanup Tasks

1. Keep `Containerfile.base` as the default AISB sandbox image for repos that do
   not provide their own `Containerfile`.
2. Keep repo-specific image generation as-is:
   `./Containerfile` builds to `localhost/aisb-<repo>-<hash>:latest`.
3. Keep `run-sb` using the repo image directly.
4. Ensure all derived agent images run `install-agent-runtime-deps.sh`.
5. Ensure `codex` and `pi` install Node/npm in their own images, not in the repo
   image.
6. Keep npm cache configured to a writable runtime path to avoid root-owned
   `$HOME/.npm` issues.
7. Make error messages from `install-agent-runtime-deps.sh` mention the supported
   package managers and that `run-sb` remains available.
8. Update README language to describe derived agent images as repo images plus
   agent additions.
9. Add a build smoke-test checklist for:
   - default no-repo-Containerfile path
   - Fedora/microdnf repo base
   - Debian/apt repo base
   - Alpine/apk repo base
   - unsupported base with no package manager

## Resolved Questions

- `codex` installs or verifies Node/npm directly in its derived image, like
  `pi`. If the repo base already provides `npm`, the Node installer exits early.
- Do not add `AISB_SKIP_AGENT_TOOLBOX=1` for now. Repos that want to own the
  full agent image can use `CLAUDE_IMAGE`, `CODEX_IMAGE`, or `PI_IMAGE`.
- Use the same shared practical toolbox for Claude, Codex, and PI.
- Keep parallel derived-image builds as the default for
  `bin/build-containers all`, but add an opt-in sequential/debug mode such as
  `AISB_BUILD_SEQUENTIAL=1` for slow or package-manager constrained bases.

## Rationale

The cleanest theoretical designs require either AISB-controlled base inheritance
or repo `Containerfile` fragments. Those are architecturally neat, but they give
up the existing and useful property that a repo owns the image its code runs in.

This plan accepts that derived agent images are operational images, not pure repo
runtime images. That keeps the mental model honest:

```text
repo image: what the code runs in
agent image: what the agent needs to work effectively inside that repo image
```

The price is distro-aware package installation in the derived images. That is a
reasonable price if the supported base families are documented and failures are
clear.
