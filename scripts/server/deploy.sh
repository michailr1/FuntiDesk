#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/funtidesk}"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repo}"
COMPOSE_DIR="$REPO_DIR/infra/funtidesk-server"
ENV_FILE="$ROOT_DIR/server.env"
DATA_DIR="$ROOT_DIR/data"
BACKUP_DIR="$ROOT_DIR/backups"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 1
fi

for cmd in git docker ss; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 1; }
done

docker compose version >/dev/null

install -d -m 0750 "$ROOT_DIR" "$DATA_DIR" "$BACKUP_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "ERROR: expected repository at $REPO_DIR" >&2
  exit 1
fi

# FUNTIDESK: production deployments must be reproducible from a committed tree.
if [[ -n "$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all)" ]]; then
  echo "ERROR: repository has uncommitted or untracked changes" >&2
  exit 1
fi

DEPLOYED_COMMIT="$(git -C "$REPO_DIR" rev-parse HEAD)"
echo "DEPLOYED_COMMIT=$DEPLOYED_COMMIT"

if [[ ! -f "$ENV_FILE" ]]; then
  install -m 0640 "$COMPOSE_DIR/.env.example" "$ENV_FILE"
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${FUNTIDESK_FQDN:?FUNTIDESK_FQDN is required}"

# FUNTIDESK: deployment owns file permissions; verify.sh must remain read-only.
if [[ -f "$DATA_DIR/id_ed25519" ]]; then
  chmod 600 "$DATA_DIR/id_ed25519"
fi
if [[ -f "$DATA_DIR/id_ed25519.pub" ]]; then
  chmod 644 "$DATA_DIR/id_ed25519.pub"
fi

# FUNTIDESK ADR-004: own server build from the pinned, hash-checked release.
set -a
# shellcheck disable=SC1091
source "$REPO_DIR/infra/funtidesk-server/server-release.env"
set +a
REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/server/build-image.sh"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" config >/dev/null

# FUNTIDESK R-01: on a clean data directory, hbbs owns creation of the
# persistent server identity. Do not start hbbr until both key files exist,
# otherwise two services could race while initializing shared state.
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" up -d hbbs

for _ in $(seq 1 30); do
  if [[ -s "$DATA_DIR/id_ed25519" && -s "$DATA_DIR/id_ed25519.pub" ]]; then
    break
  fi
  sleep 1
done
[[ -s "$DATA_DIR/id_ed25519" && -s "$DATA_DIR/id_ed25519.pub" ]] || {
  echo "ERROR: hbbs did not create persistent server identity within 30s" >&2
  docker logs funtidesk-hbbs >&2 || true
  exit 1
}

chmod 600 "$DATA_DIR/id_ed25519"
chmod 644 "$DATA_DIR/id_ed25519.pub"
bash "$REPO_DIR/scripts/server/validate-keypair.sh"   "$DATA_DIR/id_ed25519" "$DATA_DIR/id_ed25519.pub" >/dev/null

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" up -d hbbr

bash "$REPO_DIR/scripts/server/verify.sh"

printf '%s\n' "$DEPLOYED_COMMIT" > "$ROOT_DIR/DEPLOYED_COMMIT"
chmod 0644 "$ROOT_DIR/DEPLOYED_COMMIT"
