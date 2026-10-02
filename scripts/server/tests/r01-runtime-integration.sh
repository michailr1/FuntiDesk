#!/usr/bin/env bash
set -euo pipefail

COMPOSE="infra/funtidesk-server/compose.yaml"
TMP="$(mktemp -d)"
export FUNTIDESK_FQDN="127.0.0.1"
export FUNTIDESK_DATA_DIR="$TMP/data"
mkdir -p "$FUNTIDESK_DATA_DIR"

cleanup() {
  docker compose -f "$COMPOSE" down --remove-orphans >/dev/null 2>&1 || true

  # FUNTIDESK: hbbs/hbbr run as root in the container and can leave root-owned
  # files in the bind-mounted temporary directory. Cleanup must not turn a
  # successful integration test into a false failure.
  if ! rm -rf "$TMP" 2>/dev/null; then
    if command -v sudo >/dev/null 2>&1; then
      sudo rm -rf "$TMP" >/dev/null 2>&1 || true
    else
      echo "WARN: unable to remove root-owned integration-test temp directory: $TMP" >&2
    fi
  fi
}
trap cleanup EXIT

docker compose -f "$COMPOSE" up -d hbbs

for _ in $(seq 1 30); do
  state="$(docker inspect -f '{{.State.Status}}' funtidesk-hbbs 2>/dev/null || true)"
  [[ "$state" == "running" && -s "$FUNTIDESK_DATA_DIR/id_ed25519.pub" ]] && break
  sleep 1
done

[[ "$(docker inspect -f '{{.State.Status}}' funtidesk-hbbs)" == "running" ]] || {
  docker logs funtidesk-hbbs >&2 || true
  echo "ERROR: hbbs did not stay running" >&2
  exit 1
}
[[ -s "$FUNTIDESK_DATA_DIR/id_ed25519.pub" ]] || {
  docker logs funtidesk-hbbs >&2 || true
  echo "ERROR: hbbs did not create persistent identity" >&2
  exit 1
}

docker compose -f "$COMPOSE" up -d hbbr
for _ in $(seq 1 20); do
  state="$(docker inspect -f '{{.State.Status}}' funtidesk-hbbr 2>/dev/null || true)"
  [[ "$state" == "running" ]] && break
  sleep 1
done

[[ "$(docker inspect -f '{{.State.Status}}' funtidesk-hbbr)" == "running" ]] || {
  docker logs funtidesk-hbbr >&2 || true
  echo "ERROR: hbbr did not stay running with -k _" >&2
  exit 1
}

hbbs_cmd="$(docker inspect -f '{{json .Config.Cmd}}' funtidesk-hbbs)"
hbbr_cmd="$(docker inspect -f '{{json .Config.Cmd}}' funtidesk-hbbr)"
[[ "$hbbs_cmd" == *'"-k","_"'* ]] || { echo "ERROR: hbbs missing -k _ at runtime" >&2; exit 1; }
[[ "$hbbr_cmd" == *'"-k","_"'* ]] || { echo "ERROR: hbbr missing -k _ at runtime" >&2; exit 1; }

expected_key="$(tr -d '\r\n' < "$FUNTIDESK_DATA_DIR/id_ed25519.pub")"
[[ -n "$expected_key" ]] || { echo "ERROR: generated public key empty" >&2; exit 1; }

for c in funtidesk-hbbs funtidesk-hbbr; do
  logged_key="$(docker logs "$c" 2>&1 | sed -n 's/.*Key: \([^[:space:]]*\).*/\1/p' | tail -n1)"
  if [[ -n "$logged_key" && "$logged_key" != "$expected_key" ]]; then
    echo "ERROR: $c logged a different public key" >&2
    exit 1
  fi
done

echo "R01_RUNTIME_INTEGRATION_OK=true"
echo "PUBLIC_KEY=$expected_key"
