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

# FUNTIDESK: Docker-published ports bypass UFW INPUT, so verify the actual published set.
check_published_ports() {
  local container="$1"
  local expected="$2"
  local actual
  actual="$(docker port "$container" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)"
  [[ "$actual" == "$expected" ]] || {
    echo "ERROR: $container published ports '$actual', expected '$expected'" >&2
    exit 1
  }
}
check_published_ports funtidesk-hbbs "21115/tcp,21116/tcp,21116/udp"
check_published_ports funtidesk-hbbr "21117/tcp"

[[ -f "$DATA_DIR/id_ed25519" ]] || { echo "ERROR: server private key missing" >&2; exit 1; }
[[ -f "$DATA_DIR/id_ed25519.pub" ]] || { echo "ERROR: server public key missing" >&2; exit 1; }

private_mode="$(stat -c '%a' "$DATA_DIR/id_ed25519")"
public_mode="$(stat -c '%a' "$DATA_DIR/id_ed25519.pub")"
[[ "$private_mode" == "600" ]] || { echo "ERROR: id_ed25519 mode=$private_mode, expected 600" >&2; exit 1; }
[[ "$public_mode" == "644" ]] || { echo "ERROR: id_ed25519.pub mode=$public_mode, expected 644" >&2; exit 1; }

expected_key="$(tr -d '\r\n' < "$DATA_DIR/id_ed25519.pub")"
[[ -n "$expected_key" ]] || { echo "ERROR: server public key empty" >&2; exit 1; }

# FUNTIDESK: both rendezvous and relay must advertise the same persistent identity.
for c in funtidesk-hbbs funtidesk-hbbr; do
  logged_key="$(docker logs "$c" 2>&1 | grep -oE 'Key: [^[:space:]]+' | tail -n1 | awk '{print $2}')"
  [[ -n "$logged_key" ]] || { echo "ERROR: $c did not log server Key" >&2; exit 1; }
  [[ "$logged_key" == "$expected_key" ]] || {
    echo "ERROR: $c key mismatch" >&2
    exit 1
  }
done

echo "SERVER_VERIFY_OK=true"
echo "FQDN=$FUNTIDESK_FQDN"
echo "PUBLIC_KEY=$expected_key"
