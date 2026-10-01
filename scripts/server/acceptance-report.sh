#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/funtidesk}"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repo}"
DATA_DIR="$ROOT_DIR/data"

[[ -f "$ROOT_DIR/DEPLOYED_COMMIT" ]] || { echo "ERROR: DEPLOYED_COMMIT missing" >&2; exit 1; }
[[ -f "$DATA_DIR/id_ed25519.pub" ]] || { echo "ERROR: server public key missing" >&2; exit 1; }

deployed_commit="$(tr -d '\r\n' < "$ROOT_DIR/DEPLOYED_COMMIT")"
current_commit="$(git -C "$REPO_DIR" rev-parse HEAD)"
public_key="$(tr -d '\r\n' < "$DATA_DIR/id_ed25519.pub")"

[[ "$deployed_commit" == "$current_commit" ]] || {
  echo "ERROR: deployed commit does not match repository HEAD" >&2
  exit 1
}

verify_output="$(env ROOT_DIR="$ROOT_DIR" REPO_DIR="$REPO_DIR" bash "$REPO_DIR/scripts/server/verify.sh")"
printf '%s\n' "$verify_output"

hbbs_image="$(docker inspect -f '{{.Image}}' funtidesk-hbbs)"
hbbr_image="$(docker inspect -f '{{.Image}}' funtidesk-hbbr)"
[[ "$hbbs_image" == "$hbbr_image" ]] || {
  echo "ERROR: hbbs/hbbr image IDs differ" >&2
  exit 1
}

echo "M1_ACCEPTANCE_REPORT=true"
echo "UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "DEPLOYED_COMMIT=$deployed_commit"
echo "PUBLIC_KEY=$public_key"
echo "HBBS_IMAGE_ID=$hbbs_image"
echo "HBBR_IMAGE_ID=$hbbr_image"
echo "NOTE=External port reachability and off-host backup are verified from a separate host."
