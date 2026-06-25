#!/bin/sh
# ──────────────────────────────────────────────────────────────────────────────
# eqs-wg-sync — reconcile wg0 peers from the fleet registry (ADR-017).
#
# The mesh is PULL-BASED: this agent runs on every fleet node (via a systemd
# timer, every 30s), pulls the full peer list from the control-plane's
# `GET /v1/fleet/peers` (the `cluster_nodes` rows ARE the registry), and
# `wg set`s each peer onto its own wg0. The api never pushes peers.
#
# Idempotent + safe to run on a timer: `wg set peer …` upserts, so re-running
# only adds new peers / refreshes endpoints. Reads /etc/eqs-fleet/sync.env:
#   EQS_CONTROL_PLANE   base URL of the control-plane api (no trailing slash)
#   EQS_NODE_TOKEN      this node's long-lived bearer token
#   EQS_WG_IFACE        (optional) the wg interface, default wg0
#
# Requires: wg (wireguard-tools), jq, curl.
# ──────────────────────────────────────────────────────────────────────────────
set -eu

ENV_FILE=/etc/eqs-fleet/sync.env
[ -f "$ENV_FILE" ] || { echo "eqs-wg-sync: $ENV_FILE missing" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"

: "${EQS_CONTROL_PLANE:?eqs-wg-sync: EQS_CONTROL_PLANE unset}"
: "${EQS_NODE_TOKEN:?eqs-wg-sync: EQS_NODE_TOKEN unset}"
WG_IFACE="${EQS_WG_IFACE:-wg0}"

command -v wg   >/dev/null 2>&1 || { echo "eqs-wg-sync: wg not installed" >&2; exit 1; }
command -v jq   >/dev/null 2>&1 || { echo "eqs-wg-sync: jq not installed" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "eqs-wg-sync: curl not installed" >&2; exit 1; }
wg show "$WG_IFACE" >/dev/null 2>&1 || { echo "eqs-wg-sync: $WG_IFACE not up" >&2; exit 1; }

# Our own public key — never peer with ourselves.
SELF_PUB="$(wg show "$WG_IFACE" public-key 2>/dev/null || echo '')"

PEERS="$(curl -fsSL --max-time 15 \
  -H "Authorization: Bearer $EQS_NODE_TOKEN" \
  "$EQS_CONTROL_PLANE/v1/fleet/peers")" || {
  echo "eqs-wg-sync: failed to fetch peers from $EQS_CONTROL_PLANE" >&2
  exit 1
}

# One TSV line per peer: <pubkey>\t<wgIp>\t<endpoint|->. jq normalises the shape
# and substitutes "-" for a null endpoint (a peer with no reachable public IP).
echo "$PEERS" | jq -r '.[] | [.wgPublicKey, .wgIp, (.endpoint // "-")] | @tsv' |
while IFS="$(printf '\t')" read -r PUB IP EP; do
  [ -n "$PUB" ] && [ -n "$IP" ] || continue
  # Skip self.
  [ -n "$SELF_PUB" ] && [ "$PUB" = "$SELF_PUB" ] && continue
  if [ "$EP" != "-" ] && [ -n "$EP" ]; then
    wg set "$WG_IFACE" peer "$PUB" endpoint "$EP" \
      allowed-ips "$IP/32" persistent-keepalive 25
  else
    wg set "$WG_IFACE" peer "$PUB" \
      allowed-ips "$IP/32" persistent-keepalive 25
  fi
done

exit 0
