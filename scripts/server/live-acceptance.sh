#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="${ROOT_DIR:-/opt/funtidesk}"
REPO_DIR="${REPO_DIR:-$ROOT_DIR/repo}"
OUT="${1:-$ROOT_DIR/m1-live-acceptance-$(date -u +%Y%m%dT%H%M%SZ).txt}"

{
  echo "FUNTIDESK_M1_LIVE_ACCEPTANCE=true"
  echo "TIMESTAMP_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "HOST=$(hostname -f 2>/dev/null || hostname)"

  if [[ -f "$ROOT_DIR/DEPLOYED_COMMIT" ]]; then
    echo "DEPLOYED_COMMIT=$(tr -d '\r\n' < "$ROOT_DIR/DEPLOYED_COMMIT")"
  else
    echo "DEPLOYED_COMMIT=MISSING"
  fi

  echo "REPO_HEAD=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
  echo "REPO_DIRTY=$(if [[ -n "$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all 2>/dev/null)" ]]; then echo true; else echo false; fi)"

  if [[ -f "$ROOT_DIR/data/id_ed25519.pub" ]]; then
    echo "PUBLIC_KEY=$(tr -d '\r\n' < "$ROOT_DIR/data/id_ed25519.pub")"
  else
    echo "PUBLIC_KEY=MISSING"
  fi

  for c in funtidesk-hbbs funtidesk-hbbr; do
    echo "CONTAINER=$c"
    echo "  STATE=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo MISSING)"
    echo "  IMAGE=$(docker inspect -f '{{.Config.Image}}' "$c" 2>/dev/null || echo UNKNOWN)"
    echo "  IMAGE_ID=$(docker inspect -f '{{.Image}}' "$c" 2>/dev/null || echo UNKNOWN)"
    echo "  CMD=$(docker inspect -f '{{json .Config.Cmd}}' "$c" 2>/dev/null || echo UNKNOWN)"
    docker port "$c" 2>/dev/null | sed 's/^/  PORT=/' || true
  done

  echo "LISTENERS="
  ss -lntup 2>/dev/null | grep -E ':(21115|21116|21117|21118|21119)\b' || true

  echo "VERIFY_BEGIN"
  bash "$REPO_DIR/scripts/server/verify.sh"
  echo "VERIFY_END"

  if command -v ufw >/dev/null 2>&1; then
    echo "UFW_BEGIN"
    ufw status verbose || true
    echo "UFW_END"
  fi
} | tee "$OUT"

chmod 600 "$OUT"
echo "LIVE_ACCEPTANCE_REPORT=$OUT"
