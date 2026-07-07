#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────────
# eQuantic Space — bootstrap installer (ADR-009, layer 1)
#
#   curl -fsSL https://get.equantic.space/install.sh | sudo sh
#
# This script installs NOTHING on the host. It only downloads a portable Node
# runtime and the standalone platform bundle, runs the api+web in **setup mode**
# (stateless — no database), and prints the URL of the install wizard. The setup
# wizard is what installs everything else (Docker/k3s, Postgres in-cluster, TLS).
# Re-running it is safe: it stops the previous setup processes and starts fresh.
# ──────────────────────────────────────────────────────────────────────────────
set -eu

REPO="eQuantic/equantic-space-setup"
CLI_REPO="eQuantic/equantic-space-cli-setup"   # the eqs CLI ships from its own repo (ADR-023)
NODE_VERSION="${EQS_NODE_VERSION:-22.20.0}"
EQS_HOME="${EQS_HOME:-/opt/equantic}"
SETUP_PORT="${EQS_SETUP_PORT:-3000}"
API_PORT="${EQS_API_PORT:-3001}"

log()  { printf '\033[36m›\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── 1. host checks ────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Linux" ] || die "Only Linux is supported (is this your workstation? run it on the VPS)."
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl is required."
command -v tar  >/dev/null 2>&1 || die "tar is required."

# Drop the `eqs` CLI on the box too, so the operator can drive the platform from
# the terminal (its own independent cli-v* release — ADR-020 F4). Best-effort: a
# CLI hiccup must never fail the platform install. Opt out with EQS_SKIP_CLI=1.
install_cli() {
  [ "${EQS_SKIP_CLI:-0}" = "1" ] && return 0
  if command -v eqs >/dev/null 2>&1; then ok "eqs CLI already installed"; return 0; fi
  log "Installing the eqs CLI…"
  cli_tag="$(curl -fsSL "https://api.github.com/repos/$CLI_REPO/releases" 2>/dev/null \
    | grep -oE '"tag_name": *"cli-v[^"]+"' | head -1 \
    | sed -E 's/.*"(cli-v[^"]+)".*/\1/')"
  if [ -z "$cli_tag" ]; then
    printf '\033[33m! eqs CLI release not found yet — skipping\033[0m\n'
    return 0
  fi
  if curl -fSL "https://github.com/$CLI_REPO/releases/download/$cli_tag/eqs-linux-$ARCH" \
       -o /usr/local/bin/eqs 2>/dev/null; then
    chmod +x /usr/local/bin/eqs
    ok "eqs CLI $cli_tag installed — run: eqs login"
  else
    printf '\033[33m! eqs CLI download failed — skipping (later: curl -fsSL https://get.cli.equantic.space/install.sh | sh)\033[0m\n'
  fi
}

# ── 1b. fleet join mode — add THIS host to an existing cluster (ADR-017) ──────
# When a join grant is present, this box is a NEW NODE joining an existing
# eQuantic Space fleet, not a first install. Download the host-side fleet scripts
# (served from the same Pages host as this installer) and hand off to join.sh —
# it does the WireGuard + k3s-join. No portable Node / platform bundle needed.
if [ -n "${EQS_JOIN_GRANT:-}" ]; then
  [ -n "${EQS_CONTROL_PLANE:-}" ] || die "EQS_CONTROL_PLANE is required to join the fleet."
  log "Fleet mode: joining the existing cluster…"
  SCRIPTS_BASE="${EQS_SCRIPTS_BASE:-https://get.equantic.space}"
  JOIN_DIR="$(mktemp -d)"
  curl -fsSL "$SCRIPTS_BASE/join.sh"        -o "$JOIN_DIR/join.sh"        || die "Could not download join.sh from $SCRIPTS_BASE."
  curl -fsSL "$SCRIPTS_BASE/eqs-wg-sync.sh" -o "$JOIN_DIR/eqs-wg-sync.sh" || die "Could not download eqs-wg-sync.sh from $SCRIPTS_BASE."
  chmod +x "$JOIN_DIR/join.sh" "$JOIN_DIR/eqs-wg-sync.sh"
  # exec hands over the process (and the env, incl. EQS_JOIN_GRANT/EQS_CONTROL_PLANE).
  exec sh "$JOIN_DIR/join.sh"
fi

log "eQuantic Space — installer (linux-$ARCH)"
mkdir -p "$EQS_HOME" "$EQS_HOME/run" "$EQS_HOME/logs"

# ── 2. portable Node (downloaded, not installed system-wide) ──────────────────
NODE_DIR="$EQS_HOME/node"
NODE_BIN="$NODE_DIR/bin/node"
if [ ! -x "$NODE_BIN" ] || [ "$("$NODE_BIN" -v 2>/dev/null || true)" != "v$NODE_VERSION" ]; then
  log "Downloading Node v$NODE_VERSION (portable)…"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$ARCH.tar.gz" \
    | tar -xz -C "$NODE_DIR" --strip-components=1
  ok "Node ready"
else
  ok "Node v$NODE_VERSION already present"
fi

# ── 3. platform bundle (standalone web + api) ─────────────────────────────────
log "Downloading the platform (standalone bundle)…"
APP_DIR="$EQS_HOME/app"
rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"
BUNDLE_URL="https://github.com/$REPO/releases/latest/download/equantic-space-linux-$ARCH.tar.gz"
curl -fSL "$BUNDLE_URL" -o "$EQS_HOME/bundle.tar.gz" \
  || die "Bundle not found for linux-$ARCH. Build it with: EQS_PLATFORM=linux/$ARCH ./scripts/release-setup.sh"
tar -xz -C "$APP_DIR" -f "$EQS_HOME/bundle.tar.gz" --strip-components=1
rm -f "$EQS_HOME/bundle.tar.gz"
VERSION="$(cat "$APP_DIR/VERSION" 2>/dev/null || echo '')"
ok "Bundle extracted (${VERSION:-?})"

# ── 4. update mode — upgrade an existing platform in place (ADR-012) ───────────
# When a platform is already running on this host, upgrade it from THIS bundle
# host-side (the images travel in the bundle — no registry, no GitHub) instead of
# re-running the install wizard. This is the only upgrade path for instances that
# predate the in-cluster auto-update. Force the first-run wizard with
# EQS_FORCE_INSTALL=1 (recovery).
if [ "${EQS_FORCE_INSTALL:-0}" != "1" ] \
  && command -v k3s >/dev/null 2>&1 \
  && k3s kubectl get deployment equantic-space-api -n equantic-space >/dev/null 2>&1; then
  log "Existing platform detected — updating to ${VERSION:-?} (without reinstalling)…"
  if ( cd "$APP_DIR/api" && EQS_IMAGE_BUNDLE_DIR="$APP_DIR/images" EQS_VERSION="$VERSION" "$NODE_BIN" dist/main.update.js ); then
    ok "Platform updated to ${VERSION:-?}."
    install_cli
    exit 0
  fi
  die "The update failed — the previous version is still running (see the logs above)."
fi

# ── 5. stop any previous setup processes ──────────────────────────────────────
for p in api platform; do
  pidf="$EQS_HOME/run/$p.pid"
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true
  rm -f "$pidf"
done

# ── 6. start api (setup mode, stateless) + web, detached ──────────────────────
start() { # name, workdir, env-prefixed command…
  name="$1"; shift; wd="$1"; shift
  log "Starting ${name}…"
  # nohup so the servers survive the `curl | sh` pipe closing (no systemd needed).
  ( cd "$wd" && nohup env "$@" >"$EQS_HOME/logs/$name.log" 2>&1 & echo $! >"$EQS_HOME/run/$name.pid" )
}

start api "$APP_DIR/api" \
  API_PORT="$API_PORT" WEB_URL="http://localhost:$SETUP_PORT" \
  EQS_IMAGE_BUNDLE_DIR="$APP_DIR/images" EQS_RUN_DIR="$EQS_HOME/run" \
  EQS_VERSION="$VERSION" \
  "$NODE_BIN" dist/main.setup.js
start platform "$APP_DIR/platform" \
  PORT="$SETUP_PORT" HOSTNAME=0.0.0.0 NEXT_PUBLIC_API_URL="http://localhost:$API_PORT" \
  "$NODE_BIN" apps/platform/server.js

# ── 7. wait for the wizard to answer, then print the URL ──────────────────────
log "Waiting for the wizard…"
i=0
until curl -fsS "http://localhost:$SETUP_PORT/setup" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && die "The wizard did not respond. See $EQS_HOME/logs/."
  sleep 1
done

install_cli

IP="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR-IP')"
ok "eQuantic Space ready to install!"
printf '\n  Open in your browser:  \033[1;32mhttp://%s:%s/setup\033[0m\n\n' "$IP" "$SETUP_PORT"
printf '  Logs:  %s/logs/   ·   stop:  kill \$(cat %s/run/*.pid)\n\n' "$EQS_HOME" "$EQS_HOME"
