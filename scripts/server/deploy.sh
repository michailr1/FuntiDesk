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

docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" config >/dev/null
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" pull
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_DIR/compose.yaml" up -d

bash "$REPO_DIR/scripts/server/verify.sh"

printf '%s\n' "$DEPLOYED_COMMIT" > "$ROOT_DIR/DEPLOYED_COMMIT"
chmod 0644 "$ROOT_DIR/DEPLOYED_COMMIT"
