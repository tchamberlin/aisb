#!/bin/sh
set -eu

# Add the official GitHub CLI repo and install gh from there. Used when
# the distro's default repos don't ship gh (e.g. Rocky 8, RHEL 8).
# Recipes follow https://github.com/cli/cli/blob/trunk/docs/install_linux.md.
install_gh_from_official_repo() {
  if command -v microdnf >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo \
      -o /etc/yum.repos.d/gh-cli.repo
    microdnf install -y gh
  elif command -v dnf >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/rpm/gh-cli.repo \
      -o /etc/yum.repos.d/gh-cli.repo
    dnf install -y gh
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends wget
    mkdir -p -m 755 /etc/apt/keyrings
    wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      > /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    mkdir -p -m 755 /etc/apt/sources.list.d
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
    apt-get update
    apt-get install -y --no-install-recommends gh
  else
    echo "warn: no gh-install fallback available for this package manager" >&2
    return 1
  fi
}

if command -v microdnf >/dev/null 2>&1; then
  microdnf install -y --setopt=install_weak_deps=0 --allowerasing \
    ca-certificates curl git openssh-clients bash which \
    ripgrep less jq vim-enhanced \
    unzip zip tar xz gzip \
    patch diffutils findutils coreutils \
    procps-ng iproute

  if ! microdnf install -y gh; then
    echo "info: gh not in default repos; installing from cli.github.com" >&2
    install_gh_from_official_repo
  fi

  microdnf clean all
  rm -rf /var/cache/dnf /var/cache/yum

elif command -v dnf >/dev/null 2>&1; then
  dnf install -y --setopt=install_weak_deps=0 --allowerasing \
    ca-certificates curl git openssh-clients bash which \
    ripgrep less jq vim-enhanced \
    unzip zip tar xz gzip \
    patch diffutils findutils coreutils \
    procps-ng iproute

  if ! dnf install -y gh; then
    echo "info: gh not in default repos; installing from cli.github.com" >&2
    install_gh_from_official_repo
  fi

  dnf clean all
  rm -rf /var/cache/dnf /var/cache/yum

elif command -v apt-get >/dev/null 2>&1; then
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git openssh-client bash \
    ripgrep less jq vim \
    unzip zip tar xz-utils gzip \
    patch diffutils findutils coreutils \
    procps iproute2

  if ! apt-get install -y --no-install-recommends gh; then
    echo "info: gh not in default repos; installing from cli.github.com" >&2
    install_gh_from_official_repo
  fi

  rm -rf /var/lib/apt/lists/*

elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache \
    ca-certificates curl git openssh-client bash which \
    ripgrep less jq vim github-cli \
    unzip zip tar xz gzip \
    patch diffutils findutils coreutils \
    procps iproute2
else
  echo "error: no supported package manager found for agent runtime dependencies" >&2
  echo "supported package managers: microdnf, dnf, apt-get, apk" >&2
  echo "run-sb can still use the repo image directly; only derived agent images require this toolbox" >&2
  exit 127
fi
