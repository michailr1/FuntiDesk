#!/usr/bin/env bash
# FUNTIDESK ADR-004: build the local funtidesk-server image from the pinned
# release binaries. Fails closed if a download or a SHA256 check fails.
set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
RELEASE_ENV="$REPO_DIR/infra/funtidesk-server/server-release.env"
REPO_SLUG="${FUNTIDESK_RELEASE_REPO:-michailr1/FuntiDesk}"

# shellcheck disable=SC1090
source "$RELEASE_ENV"
: "${FUNTIDESK_SERVER_RELEASE:?missing in $RELEASE_ENV}"
: "${HBBS_SHA256:?missing in $RELEASE_ENV}"
: "${HBBR_SHA256:?missing in $RELEASE_ENV}"

for cmd in curl sha256sum docker; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

base="https://github.com/$REPO_SLUG/releases/download/$FUNTIDESK_SERVER_RELEASE"
for bin in hbbs hbbr; do
  curl -fsSL --retry 3 --proto '=https' -o "$work/$bin" "$base/$bin"
done
(
  cd "$work"
  printf '%s  hbbs\n%s  hbbr\n' "$HBBS_SHA256" "$HBBR_SHA256" | sha256sum -c --quiet -
) || { echo "ERROR: server binaries do not match pinned SHA256" >&2; exit 1; }
chmod 0755 "$work/hbbs" "$work/hbbr"
cp "$REPO_DIR/infra/funtidesk-server/Dockerfile" "$work/Dockerfile"

image="funtidesk-server:$FUNTIDESK_SERVER_RELEASE"
docker build -q -t "$image" "$work" >/dev/null
echo "SERVER_IMAGE=$image"
echo "SERVER_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$image")"
