#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────────
# eQuantic Space — fleet node join (ADR-017).
#
# Run as root on a BRAND-NEW Linux VPS to add it to an existing eQuantic Space
# k3s cluster over the WireGuard overlay. Driven entirely by env vars:
#
#   EQS_JOIN_GRANT     (required) the single-use join grant minted by the
#                      control-plane (Fleet UI → "add node")
#   EQS_CONTROL_PLANE  (required) base URL of the control-plane api
#                      (e.g. https://space.example.com — no trailing slash)
#   EQS_NODE_ROLE      (optional) "agent" (default) or "server" (HA control-plane)
#
# The flow: install wireguard-tools/curl/jq → make a wg keypair → register with
# the control-plane (handing it our pubkey + public IP) → bring up wg0 on the
# overlay IP it assigns → install the wg-sync agent (so we keep our peers fresh)
# → join k3s over the overlay. Idempotent + fails fast with clear messages.
# ──────────────────────────────────────────────────────────────────────────────
set -eu

log()  { printf '\033[36m›\033[0m %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

WG_IFACE=wg0
WG_PORT=51820
WG_CONF=/etc/wireguard/${WG_IFACE}.conf

# ── 0. preconditions ──────────────────────────────────────────────────────────
[ "$(uname -s)" = "Linux" ] || die "Only Linux is supported (run this on the new VPS)."
[ "$(id -u)" = "0" ] || die "Must run as root."
[ -n "${EQS_JOIN_GRANT:-}" ] || die "EQS_JOIN_GRANT is required (mint it in the Fleet UI)."
[ -n "${EQS_CONTROL_PLANE:-}" ] || die "EQS_CONTROL_PLANE is required (the control-plane api URL)."
ROLE="${EQS_NODE_ROLE:-agent}"
case "$ROLE" in
  agent|server) ;;
  *) die "EQS_NODE_ROLE must be 'agent' or 'server' (got '$ROLE')." ;;
esac
# Strip any trailing slash so URL joins are clean.
CONTROL_PLANE="$(printf '%s' "$EQS_CONTROL_PLANE" | sed 's:/*$::')"

log "Joining the eQuantic Space fleet as a '$ROLE' node"

# ── 1. dependencies (wireguard-tools + curl + jq), best-effort across distros ──
install_deps() {
  need=""
  command -v wg    >/dev/null 2>&1 || need="$need wireguard-tools"
  command -v curl  >/dev/null 2>&1 || need="$need curl"
  command -v jq    >/dev/null 2>&1 || need="$need jq"
  [ -n "$need" ] || { ok "Dependencies present"; return; }
  log "Installing dependencies:$need"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y $need
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y $need
  elif command -v yum >/dev/null 2>&1; then
    yum install -y $need
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache $need
  else
    die "No supported package manager (apt/dnf/yum/apk) found — install$need manually."
  fi
}
install_deps
command -v wg   >/dev/null 2>&1 || die "wireguard-tools is required but not installed."
command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
command -v jq   >/dev/null 2>&1 || die "jq is required but not installed."
ok "Dependencies ready"

# ── 2. WireGuard keypair (private key never leaves this box) ───────────────────
mkdir -p /etc/wireguard && chmod 700 /etc/wireguard
WG_PRIVKEY="$(wg genkey)"
WG_PUBKEY="$(printf '%s' "$WG_PRIVKEY" | wg pubkey)"

# ── 3. public IP (so peers behind/at this box can dial us) ────────────────────
PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(curl -fsS --max-time 5 https://icanhazip.com 2>/dev/null || true)"
[ -n "$PUBLIC_IP" ] || PUBLIC_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
NODE_NAME="$(hostname)"
log "This node: name=$NODE_NAME pubkey=${WG_PUBKEY%%=*}… public-ip=${PUBLIC_IP:-<none>}"

# ── 4. register with the control-plane (redeems the single-use grant) ─────────
log "Registering with the control-plane…"
REG_BODY="$(jq -nc \
  --arg t  "$EQS_JOIN_GRANT" \
  --arg pk "$WG_PUBKEY" \
  --arg ip "$PUBLIC_IP" \
  --arg nn "$NODE_NAME" \
  '{token:$t, wgPublicKey:$pk, k3sNodeName:$nn} + (if $ip == "" then {} else {publicIp:$ip} end)')"

RESP="$(curl -fsSL --max-time 30 \
  -X POST "$CONTROL_PLANE/v1/fleet/nodes/register" \
  -H 'Content-Type: application/json' \
  -d "$REG_BODY")" \
  || die "Registration failed. Check EQS_CONTROL_PLANE is reachable and the grant is valid/unused."

# Parse what we need to wire into the cluster + mesh.
K3S_TOKEN="$(printf '%s' "$RESP"        | jq -r '.k3sToken // empty')"
SERVER_WG_IP="$(printf '%s' "$RESP"     | jq -r '.serverWgIp // empty')"
SERVER_WG_PUBKEY="$(printf '%s' "$RESP" | jq -r '.serverWgPublicKey // empty')"
SERVER_ENDPOINT="$(printf '%s' "$RESP"  | jq -r '.serverEndpoint // empty')"
WG_SUBNET="$(printf '%s' "$RESP"        | jq -r '.wgSubnet // empty')"
NODE_TOKEN="$(printf '%s' "$RESP"       | jq -r '.nodeToken // empty')"
ASSIGNED_WG_IP="$(printf '%s' "$RESP"   | jq -r '.assignedWgIp // empty')"

for v in K3S_TOKEN SERVER_WG_IP SERVER_WG_PUBKEY SERVER_ENDPOINT WG_SUBNET NODE_TOKEN ASSIGNED_WG_IP; do
  eval "val=\$$v"
  [ -n "$val" ] || die "Control-plane response missing '$v' — is the host bootstrapped with EQS_FLEET_ENABLED?"
done
# The overlay prefix (e.g. 16 from 10.234.0.0/16); default 16 if absent.
WG_PREFIX="$(printf '%s' "$WG_SUBNET" | sed -n 's:.*/::p')"; [ -n "$WG_PREFIX" ] || WG_PREFIX=16
ok "Registered — assigned overlay IP $ASSIGNED_WG_IP"

# ── 5. bring up wg0 (our interface + the server-1 peer) ───────────────────────
log "Configuring WireGuard ($WG_IFACE = $ASSIGNED_WG_IP/$WG_PREFIX)…"
umask 177
cat > "$WG_CONF" <<EOF
# Managed by eQuantic Space fleet (ADR-017). The control-plane peer is seeded
# here; all other peers are added at runtime by eqs-wg-sync (do not hand-edit).
[Interface]
Address = $ASSIGNED_WG_IP/$WG_PREFIX
ListenPort = $WG_PORT
PrivateKey = $WG_PRIVKEY

[Peer]
# Control-plane (server-1). AllowedIPs is the whole overlay so traffic to any
# not-yet-synced node still routes via the server until the mesh fills in.
PublicKey = $SERVER_WG_PUBKEY
Endpoint = $SERVER_ENDPOINT
AllowedIPs = $SERVER_WG_IP/32, $WG_SUBNET
PersistentKeepalive = 25
EOF
chmod 600 "$WG_CONF"

if wg show "$WG_IFACE" >/dev/null 2>&1; then
  # Re-apply without dropping a live tunnel (idempotent re-run). POSIX sh (dash)
  # has no process substitution, so strip to a tempfile under /run.
  STRIPPED="$(mktemp /run/eqs-wg0.XXXXXX 2>/dev/null || mktemp)"
  wg-quick strip "$WG_CONF" > "$STRIPPED"
  wg syncconf "$WG_IFACE" "$STRIPPED" || true
  rm -f "$STRIPPED"
  ok "$WG_IFACE re-synced"
else
  wg-quick up "$WG_IFACE" || { wg-quick down "$WG_IFACE" 2>/dev/null || true; wg-quick up "$WG_IFACE"; }
  ok "$WG_IFACE up"
fi
# Survive reboots (best-effort; systems without systemd just skip this).
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
fi

# ── 6. install the wg-sync agent (keeps our peers reconciled, every 30s) ──────
log "Installing the wg-sync agent…"
mkdir -p /etc/eqs-fleet /usr/local/lib/eqs-fleet
umask 177
cat > /etc/eqs-fleet/sync.env <<EOF
# Managed by eQuantic Space fleet (ADR-017).
EQS_CONTROL_PLANE=$CONTROL_PLANE
EQS_NODE_TOKEN=$NODE_TOKEN
EOF
umask 022

# Ship the reconcile script next to us (the bundle put it alongside join.sh).
SCRIPT_SRC="$(dirname "$0")/eqs-wg-sync.sh"
if [ -f "$SCRIPT_SRC" ]; then
  cp "$SCRIPT_SRC" /usr/local/lib/eqs-fleet/eqs-wg-sync.sh
else
  die "eqs-wg-sync.sh not found next to join.sh ($SCRIPT_SRC) — re-download the bundle."
fi
chmod 700 /usr/local/lib/eqs-fleet/eqs-wg-sync.sh

if command -v systemctl >/dev/null 2>&1; then
  cat > /etc/systemd/system/eqs-wg-sync.service <<EOF
[Unit]
Description=eQuantic Space fleet WireGuard peer sync (ADR-017)
After=network-online.target wg-quick@${WG_IFACE}.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/eqs-fleet/eqs-wg-sync.sh
EOF
  cat > /etc/systemd/system/eqs-wg-sync.timer <<EOF
[Unit]
Description=Run eQuantic Space fleet WireGuard peer sync every 30s (ADR-017)

[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=eqs-wg-sync.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now eqs-wg-sync.timer
  # Prime it once now so the mesh forms immediately (don't wait for the timer).
  systemctl start eqs-wg-sync.service || true
  ok "wg-sync agent installed (systemd timer, every 30s)"
else
  log "systemd not found — running one reconcile now; set up your own scheduler for /usr/local/lib/eqs-fleet/eqs-wg-sync.sh"
  /usr/local/lib/eqs-fleet/eqs-wg-sync.sh || true
fi

# ── 7. join k3s over the overlay ──────────────────────────────────────────────
if command -v k3s >/dev/null 2>&1; then
  ok "k3s already installed on this node — skipping install (the node is joined)."
  exit 0
fi

log "Joining the k3s cluster over the overlay ($SERVER_WG_IP)…"
if [ "$ROLE" = "server" ]; then
  # Additional control-plane (HA): the `server` subcommand + --server points it at
  # the existing control-plane; bind to our overlay IP and ride flannel over wg0.
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_EXEC="server --server https://$SERVER_WG_IP:6443 --token $K3S_TOKEN --node-ip $ASSIGNED_WG_IP --flannel-iface $WG_IFACE" \
    sh - \
    || die "k3s server join failed (see output above)."
else
  # Worker (agent): K3S_URL/K3S_TOKEN put the installer in agent mode.
  curl -sfL https://get.k3s.io | \
    K3S_URL="https://$SERVER_WG_IP:6443" K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_EXEC="--node-ip $ASSIGNED_WG_IP --flannel-iface $WG_IFACE" \
    sh - \
    || die "k3s agent join failed (see output above)."
fi

ok "Node joined the fleet as '$ROLE' ($ASSIGNED_WG_IP). Verify with: kubectl get nodes"
