#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/funtidesk}"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repo}"
COMPOSE_DIR="$REPO_DIR/infra/funtidesk-server"
ENV_FILE="$ROOT_DIR/server.env"
DATA_DIR="$ROOT_DIR/data"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" ps

for c in funtidesk-hbbs funtidesk-hbbr; do
  state="$(docker inspect -f '{{.State.Status}}' "$c")"
  [[ "$state" == "running" ]] || { echo "ERROR: $c state=$state" >&2; exit 1; }
done

for spec in "tcp:21115" "tcp:21116" "udp:21116" "tcp:21117"; do
  proto="${spec%%:*}"
  port="${spec##*:}"
  if [[ "$proto" == "tcp" ]]; then
    ss -lntH "( sport = :$port )" | grep -q . || { echo "ERROR: TCP $port not listening" >&2; exit 1; }
  else
    ss -lnuH "( sport = :$port )" | grep -q . || { echo "ERROR: UDP $port not listening" >&2; exit 1; }
  fi
done

for port in 21118 21119; do
  if ss -lntH "( sport = :$port )" | grep -q .; then
    echo "ERROR: WebSocket TCP $port unexpectedly exposed" >&2
    exit 1
  fi
done

[[ -f "$DATA_DIR/id_ed25519" ]] || { echo "ERROR: server private key missing" >&2; exit 1; }
[[ -f "$DATA_DIR/id_ed25519.pub" ]] || { echo "ERROR: server public key missing" >&2; exit 1; }

chmod 600 "$DATA_DIR/id_ed25519"
chmod 644 "$DATA_DIR/id_ed25519.pub"

echo "SERVER_VERIFY_OK=true"
echo "FQDN=$FUNTIDESK_FQDN"
echo "PUBLIC_KEY=$(cat "$DATA_DIR/id_ed25519.pub")"
