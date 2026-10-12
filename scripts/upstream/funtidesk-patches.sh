#!/usr/bin/env bash
# FuntiDesk patches against upstream: which upstream files we changed, how
# much, and how many FUNTIDESK markers each has. Run before and after an
# upstream merge (docs/UPSTREAM.md, "Как сливать новый RustDesk").
#
#   scripts/upstream/funtidesk-patches.sh [upstream-client-ref]
#
# The ref defaults to the tag recorded in docs/UPSTREAM.md (fetched as
# upstream-client-<tag>). Files we added ourselves (funti_*) are listed too.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

ref="${1:-}"
if [[ -z "$ref" ]]; then
  tag="$(grep -oE 'rustdesk/rustdesk`, tag `[^`]+`' docs/UPSTREAM.md | head -1 | sed -E 's/.*tag `([^`]+)`/\1/')"
  ref="upstream-client-$tag"
fi
if ! git rev-parse --verify -q "$ref^{commit}" >/dev/null; then
  echo "Upstream ref $ref is not here. Fetch it first, for example:" >&2
  echo "  git fetch --no-tags https://github.com/rustdesk/rustdesk.git refs/tags/<tag>:refs/tags/upstream-client-<tag>" >&2
  exit 1
fi

echo "# FuntiDesk changes in client/ against $ref"
echo
echo "| added | removed | markers | file |"
echo "|---:|---:|---:|---|"
git diff --numstat "$ref^{tree}" "HEAD:client" -- . ':!libs/hbb_common' |
  while IFS=$'\t' read -r added removed file; do
    markers=0
    if [[ -f "client/$file" ]]; then
      markers="$(grep -c 'FUNTIDESK' "client/$file" || true)"
    fi
    echo "$((${added/-/0} + ${removed/-/0})) | $added | $removed | $markers | \`client/$file\`"
  done |
  sort -t'|' -k1,1nr |
  cut -d'|' -f2- |
  sed 's/^ /| /; s/$/ |/'
