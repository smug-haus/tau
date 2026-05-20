#!/usr/bin/env bash
# install-toolchain.sh — install Erlang/OTP, Elixir, Hex, rebar3, and Zig from
# precompiled binaries, without using the OS package manager.
#
# Per-user by default. NO sudo. NO writes to /opt or /etc. Everything lands
# under $HOME, owned by the invoking user.
#
# Idempotent: safe to re-run. Existing installs are skipped.
#
# Versions are pinned from the project's .tool-versions (BEAM) and from
# the ZIG_VERSION variable below (Zig; matches release.yml / ci.yml):
#   erlang 27.2
#   elixir 1.18.1-otp-27
#   zig    0.15.2
#
# Prerequisites (distro-provided, not installed here):
#   xz    — required for Zig .tar.xz and Burrito packing (apt install xz-utils)
#
# Sources (verified, no --insecure / --unsafe flags):
#   - OTP precompiled binaries:  https://builds.hex.pm/builds/otp/<distro>/
#     (the same source used by the erlef/setup-beam GitHub Action)
#   - Elixir precompiled zip:    https://github.com/elixir-lang/elixir/releases
#   - Hex archive:               https://builds.hex.pm/installs/<elixir>/hex.ez
#   - rebar3 binary:             https://github.com/erlang/rebar3/releases/latest
#   - Zig binary:                https://ziglang.org/download/<version>/
#
# Usage:
#   bash scripts/install-toolchain.sh         # installs under $HOME/.local
#   PREFIX=$HOME/dev/toolchain bash scripts/install-toolchain.sh   # override
#
# System-wide install (root, /opt) is supported but NOT the default. Pass
# both PREFIX and PROFILE_FILE explicitly and run with sudo:
#   sudo PREFIX=/opt PROFILE_FILE=/etc/profile.d/tau-toolchain.sh bash scripts/install-toolchain.sh

set -euo pipefail

# Resolve the invoking user even if the script is somehow run via sudo, so
# Hex/rebar3 (per-user resources) land in the right $HOME.
if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
  TARGET_USER="$SUDO_USER"
  TARGET_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  TARGET_USER="${USER:-$(id -un)}"
  TARGET_HOME="${HOME:-$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
fi

PREFIX="${PREFIX:-$TARGET_HOME/.local/share/tau-toolchain}"
ERLANG_VERSION="${ERLANG_VERSION:-27.2}"
ELIXIR_VERSION="${ELIXIR_VERSION:-1.18.1}"
ELIXIR_OTP_MAJOR="${ELIXIR_OTP_MAJOR:-27}"
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"

ERLANG_HOME="$PREFIX/erlang/OTP-$ERLANG_VERSION"
ELIXIR_HOME="$PREFIX/elixir"
ZIG_HOME="$PREFIX/zig"
ZIG_ARCH="x86_64-linux"
# ZIG_INSTALL_DIR is discovered post-extract (Zig's tarball internal layout
# is not pinned by upstream and has varied across releases — see the Zig
# install step below). Initialised to the legacy-expected path so it's set
# before PROFILE_FILE generation runs.
ZIG_INSTALL_DIR="$ZIG_HOME/zig-${ZIG_ARCH}-${ZIG_VERSION}"
PROFILE_FILE="${PROFILE_FILE:-$TARGET_HOME/.local/share/tau-toolchain/env.sh}"

log()  { printf '\033[1;32m[install-toolchain]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-toolchain]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-toolchain]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------

[[ "$(uname -s)" == "Linux" ]]   || die "Linux only (got $(uname -s))."
[[ "$(uname -m)" == "x86_64" ]]  || die "x86_64 only (got $(uname -m))."

# Probe install destinations early. Defaults are user-writable ($HOME paths);
# only an explicit system-wide override (e.g. PREFIX=/opt) needs root.
if ! mkdir -p "$PREFIX" "$(dirname "$PROFILE_FILE")" 2>/dev/null; then
  die "Cannot create $PREFIX or $(dirname "$PROFILE_FILE") — paths not writable by $TARGET_USER.
The default is a per-user install under \$HOME (no sudo). If you overrode PREFIX
or PROFILE_FILE to a system path, either revert to the default or re-run with
sudo plus an explicit PROFILE_FILE under /etc:
    sudo PREFIX=/opt PROFILE_FILE=/etc/profile.d/tau-toolchain.sh bash $0"
fi

# When this script IS being run via sudo, drop privileges for per-user steps
# (Hex archive, rebar3) so files land owned by $TARGET_USER, not root.
# In the default per-user flow this is a no-op.
as_target_user() {
  if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    sudo -u "$TARGET_USER" -H --preserve-env=PATH,ERLANG_HOME,ELIXIR_HOME,ELIXIR_ERL_OPTIONS,LANG,LC_ALL,HEX_CACERTS_PATH "$@"
  else
    "$@"
  fi
}

. /etc/os-release 2>/dev/null || die "Cannot read /etc/os-release."
case "$VERSION_ID" in
  24.04) DISTRO="ubuntu-24.04" ;;
  22.04) DISTRO="ubuntu-22.04" ;;
  20.04) DISTRO="ubuntu-20.04" ;;
  *) die "Unsupported distro $ID-$VERSION_ID. Add to install-toolchain.sh." ;;
esac

for tool in curl unzip tar xz; do
  command -v "$tool" >/dev/null || die "Missing required tool: $tool (install xz-utils for xz)"
done

# --- Erlang ------------------------------------------------------------------

if [[ -x "$ERLANG_HOME/bin/erl" ]] && \
   "$ERLANG_HOME/bin/erl" -noshell -eval 'halt(0).' 2>/dev/null; then
  log "Erlang/OTP $ERLANG_VERSION already installed at $ERLANG_HOME — skipping."
else
  log "Downloading OTP-$ERLANG_VERSION precompiled for $DISTRO ..."
  mkdir -p "$PREFIX/erlang"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/otp.tar.gz" \
    "https://builds.hex.pm/builds/otp/$DISTRO/OTP-$ERLANG_VERSION.tar.gz"
  tar -xzf "$TMP/otp.tar.gz" -C "$PREFIX/erlang"
  log "Running OTP Install in $ERLANG_HOME ..."
  ( cd "$ERLANG_HOME" && ./Install -minimal "$ERLANG_HOME" )
  trap - EXIT
  rm -rf "$TMP"
  "$ERLANG_HOME/bin/erl" -version
fi

# --- Elixir ------------------------------------------------------------------

if [[ -x "$ELIXIR_HOME/bin/elixir" ]] && \
   PATH="$ERLANG_HOME/bin:$ELIXIR_HOME/bin:$PATH" \
   "$ELIXIR_HOME/bin/elixir" --version 2>/dev/null \
     | grep -q "Elixir $ELIXIR_VERSION"; then
  log "Elixir $ELIXIR_VERSION already installed at $ELIXIR_HOME — skipping."
else
  log "Downloading Elixir $ELIXIR_VERSION (otp-$ELIXIR_OTP_MAJOR build) ..."
  mkdir -p "$ELIXIR_HOME"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/elixir.zip" \
    "https://github.com/elixir-lang/elixir/releases/download/v$ELIXIR_VERSION/elixir-otp-$ELIXIR_OTP_MAJOR.zip"
  ( cd "$ELIXIR_HOME" && unzip -qo "$TMP/elixir.zip" )
  trap - EXIT
  rm -rf "$TMP"
fi

# --- PATH for the rest of this script ----------------------------------------
#
# The persistent PROFILE_FILE is written at the end (so it captures the
# discovered ZIG_INSTALL_DIR — Zig's tarball layout is not pinned). For this
# script's own subsequent steps (Hex, rebar3, Zig) we just need PATH.

export ERLANG_HOME ELIXIR_HOME
export PATH="$ERLANG_HOME/bin:$ELIXIR_HOME/bin:$PATH"
export ELIXIR_ERL_OPTIONS="+fnu"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"

elixir --version | tail -2
mix --version    | tail -1

# --- Hex archive -------------------------------------------------------------
#
# Download the Hex archive via curl and install it offline so this script
# works on hosts without Mix archives on disk yet.

ELIXIR_MINOR="$(echo "$ELIXIR_VERSION" | awk -F. '{print $1"."$2".0"}')"

# Hex archive lands in the target user's ~/.mix/archives/. The mix invocation
# is dropped to TARGET_USER when running under sudo so files are owned right.
if as_target_user mix hex.info >/dev/null 2>&1; then
  log "Hex archive already installed for $TARGET_USER — skipping."
else
  log "Downloading Hex archive for Elixir $ELIXIR_MINOR ..."
  # Use a temp file in TARGET_HOME so the drop-to-user mix invocation can
  # read it; /tmp would work too but this keeps everything under $HOME.
  HEX_EZ="$(as_target_user mktemp --tmpdir="$TARGET_HOME" hex.XXXXXX.ez)"
  curl -fsSL -o "$HEX_EZ" \
    "https://builds.hex.pm/installs/$ELIXIR_MINOR/hex.ez"
  # Ensure the file is readable by TARGET_USER if curl ran as root.
  [[ $EUID -eq 0 ]] && chown "$TARGET_USER" "$HEX_EZ"
  as_target_user mix archive.install "$HEX_EZ" --force
  rm -f "$HEX_EZ"
fi

# --- rebar3 ------------------------------------------------------------------

REBAR3="${REBAR3:-$TARGET_HOME/.mix/rebar3}"
if [[ -x "$REBAR3" ]] && "$REBAR3" --version >/dev/null 2>&1; then
  log "rebar3 already installed at $REBAR3 — skipping."
else
  log "Downloading rebar3 from GitHub release ..."
  as_target_user mkdir -p "$(dirname "$REBAR3")"
  curl -fsSL -o "$REBAR3" \
    "https://github.com/erlang/rebar3/releases/latest/download/rebar3"
  chmod +x "$REBAR3"
  [[ $EUID -eq 0 ]] && chown "$TARGET_USER" "$REBAR3"
  "$REBAR3" --version
fi

# --- Zig ---------------------------------------------------------------------
#
# Zig is required by Burrito to compile its native launcher (cross-compilation
# driver). Pinned version matches release.yml / ci.yml (mlugg/setup-zig@v1).
# Installed to $ZIG_HOME/$ZIG_ARCH-$ZIG_VERSION/; $ZIG_INSTALL_DIR is on PATH
# via $PROFILE_FILE.

ZIG_TARBALL="zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}"

# Locate an already-installed Zig binary of the right version under $ZIG_HOME.
# The tarball's internal layout (single-dir vs nested) is not pinned by
# upstream — discover the real binary path rather than hard-coding it.
discover_zig_bin() {
  find "$ZIG_HOME" -maxdepth 4 -type f -name zig -executable 2>/dev/null \
    | while read -r candidate; do
        if "$candidate" version 2>/dev/null | grep -q "^${ZIG_VERSION}"; then
          echo "$candidate"; break
        fi
      done | head -1
}

ZIG_BIN="$(discover_zig_bin || true)"

if [[ -n "$ZIG_BIN" ]]; then
  log "Zig $ZIG_VERSION already installed at $ZIG_BIN — skipping."
else
  log "Downloading Zig $ZIG_VERSION for $ZIG_ARCH ..."
  mkdir -p "$ZIG_HOME"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fsSL -o "$TMP/$ZIG_TARBALL" "$ZIG_URL"
  tar -xJf "$TMP/$ZIG_TARBALL" -C "$ZIG_HOME"
  trap - EXIT
  rm -rf "$TMP"
  ZIG_BIN="$(discover_zig_bin || true)"
  [[ -n "$ZIG_BIN" ]] || die "Zig extraction succeeded but no zig binary of version $ZIG_VERSION found under $ZIG_HOME. Inspect: find $ZIG_HOME -name zig -type f"
  "$ZIG_BIN" version
fi

# Real install dir — the directory that actually contains the binary.
ZIG_INSTALL_DIR="$(dirname "$ZIG_BIN")"

# --- Profile -----------------------------------------------------------------
#
# Written last so it captures the *discovered* ZIG_INSTALL_DIR (Zig's tarball
# layout varies across releases; see the Zig install step).

log "Writing $PROFILE_FILE ..."
mkdir -p "$(dirname "$PROFILE_FILE")"
cat > "$PROFILE_FILE" <<EOF
# Generated by scripts/install-toolchain.sh
export ERLANG_HOME="$ERLANG_HOME"
export ELIXIR_HOME="$ELIXIR_HOME"
export ZIG_HOME="$ZIG_INSTALL_DIR"
export PATH="\$ERLANG_HOME/bin:\$ELIXIR_HOME/bin:\$ZIG_HOME:\$PATH"
export ELIXIR_ERL_OPTIONS="+fnu"
export LANG="\${LANG:-C.UTF-8}"
export LC_ALL="\${LC_ALL:-C.UTF-8}"
# Point Hex at the system CA bundle for its HTTPS verification.
export HEX_CACERTS_PATH="/etc/ssl/certs/ca-certificates.crt"
EOF
chmod +x "$PROFILE_FILE"

# --- Final summary -----------------------------------------------------------

log "Done. Open a new shell or 'source $PROFILE_FILE' to pick up PATH."
log ""
log "Next step (in a fresh checkout): mix deps.get && mix compile"
