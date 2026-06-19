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
NODE_VERSION="${EQS_NODE_VERSION:-22.20.0}"
EQS_HOME="${EQS_HOME:-/opt/equantic}"
SETUP_PORT="${EQS_SETUP_PORT:-3000}"
API_PORT="${EQS_API_PORT:-3001}"

log()  { printf '\033[36m›\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── 1. host checks ────────────────────────────────────────────────────────────
[ "$(uname -s)" = "Linux" ] || die "Apenas Linux é suportado (esta é a sua estação? rode na VPS)."
case "$(uname -m)" in
  x86_64|amd64)  ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Arquitetura não suportada: $(uname -m)" ;;
esac
command -v curl >/dev/null 2>&1 || die "curl é necessário."
command -v tar  >/dev/null 2>&1 || die "tar é necessário."

log "eQuantic Space — instalador (linux-$ARCH)"
mkdir -p "$EQS_HOME" "$EQS_HOME/run" "$EQS_HOME/logs"

# ── 2. portable Node (downloaded, not installed system-wide) ──────────────────
NODE_DIR="$EQS_HOME/node"
NODE_BIN="$NODE_DIR/bin/node"
if [ ! -x "$NODE_BIN" ] || [ "$("$NODE_BIN" -v 2>/dev/null || true)" != "v$NODE_VERSION" ]; then
  log "Baixando Node v$NODE_VERSION (portátil)…"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  curl -fsSL "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-$ARCH.tar.gz" \
    | tar -xz -C "$NODE_DIR" --strip-components=1
  ok "Node pronto"
else
  ok "Node v$NODE_VERSION já presente"
fi

# ── 3. platform bundle (standalone web + api) ─────────────────────────────────
log "Baixando a plataforma (bundle standalone)…"
APP_DIR="$EQS_HOME/app"
rm -rf "$APP_DIR"; mkdir -p "$APP_DIR"
BUNDLE_URL="https://github.com/$REPO/releases/latest/download/equantic-space-linux-$ARCH.tar.gz"
curl -fSL "$BUNDLE_URL" -o "$EQS_HOME/bundle.tar.gz" \
  || die "Bundle não encontrado para linux-$ARCH. Gere com: EQS_PLATFORM=linux/$ARCH ./scripts/release-setup.sh"
tar -xz -C "$APP_DIR" -f "$EQS_HOME/bundle.tar.gz" --strip-components=1
rm -f "$EQS_HOME/bundle.tar.gz"
VERSION="$(cat "$APP_DIR/VERSION" 2>/dev/null || echo '')"
ok "Bundle extraído (${VERSION:-?})"

# ── 4. update mode — upgrade an existing platform in place (ADR-012) ───────────
# When a platform is already running on this host, upgrade it from THIS bundle
# host-side (the images travel in the bundle — no registry, no GitHub) instead of
# re-running the install wizard. This is the only upgrade path for instances that
# predate the in-cluster auto-update. Force the first-run wizard with
# EQS_FORCE_INSTALL=1 (recovery).
if [ "${EQS_FORCE_INSTALL:-0}" != "1" ] \
  && command -v k3s >/dev/null 2>&1 \
  && k3s kubectl get deployment equantic-api -n equantic >/dev/null 2>&1; then
  log "Plataforma existente detectada — atualizando para ${VERSION:-?} (sem reinstalar)…"
  if ( cd "$APP_DIR/api" && EQS_IMAGE_BUNDLE_DIR="$APP_DIR/images" EQS_VERSION="$VERSION" "$NODE_BIN" dist/main.update.js ); then
    ok "Plataforma atualizada para ${VERSION:-?}."
    exit 0
  fi
  die "A atualização falhou — a versão anterior segue no ar (veja os logs acima)."
fi

# ── 5. stop any previous setup processes ──────────────────────────────────────
for p in api web; do
  pidf="$EQS_HOME/run/$p.pid"
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null || true
  rm -f "$pidf"
done

# ── 6. start api (setup mode, stateless) + web, detached ──────────────────────
start() { # name, workdir, env-prefixed command…
  name="$1"; shift; wd="$1"; shift
  log "Subindo ${name}…"
  # nohup so the servers survive the `curl | sh` pipe closing (no systemd needed).
  ( cd "$wd" && nohup env "$@" >"$EQS_HOME/logs/$name.log" 2>&1 & echo $! >"$EQS_HOME/run/$name.pid" )
}

start api "$APP_DIR/api" \
  API_PORT="$API_PORT" WEB_URL="http://localhost:$SETUP_PORT" \
  EQS_IMAGE_BUNDLE_DIR="$APP_DIR/images" EQS_RUN_DIR="$EQS_HOME/run" \
  EQS_VERSION="$VERSION" \
  "$NODE_BIN" dist/main.setup.js
start web "$APP_DIR/web" \
  PORT="$SETUP_PORT" HOSTNAME=0.0.0.0 NEXT_PUBLIC_API_URL="http://localhost:$API_PORT" \
  "$NODE_BIN" apps/web/server.js

# ── 7. wait for the wizard to answer, then print the URL ──────────────────────
log "Aguardando o assistente…"
i=0
until curl -fsS "http://localhost:$SETUP_PORT/setup" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -gt 60 ] && die "O assistente não respondeu. Veja $EQS_HOME/logs/."
  sleep 1
done

IP="$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo 'SEU-IP')"
ok "eQuantic Space pronto para instalação!"
printf '\n  Abra no navegador:  \033[1;32mhttp://%s:%s/setup\033[0m\n\n' "$IP" "$SETUP_PORT"
printf '  Logs:  %s/logs/   ·   parar:  kill \$(cat %s/run/*.pid)\n\n' "$EQS_HOME" "$EQS_HOME"
