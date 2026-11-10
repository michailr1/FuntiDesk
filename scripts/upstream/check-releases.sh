#!/usr/bin/env bash
# FUNTIDESK: is there a newer stable RustDesk than the one in docs/UPSTREAM.md?
# Prints a Markdown report (commits that look like security fixes, and how a
# trial merge of the client goes) and exits 10 when there is something new,
# 0 when the baseline is current. Changes nothing: the trial merge runs in a
# temporary worktree. Needs the full history (not a shallow clone).
#
#   scripts/upstream/check-releases.sh > report.md
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

baseline() { # $1: repository name as written in docs/UPSTREAM.md
  grep -oE "rustdesk/$1\`, tag \`[^\`]+\`" docs/UPSTREAM.md | head -1 | sed -E 's/.*tag `([^`]+)`/\1/'
}
latest() { # $1: repository; newest tag that is exactly N.N.N
  git ls-remote --tags --refs "https://github.com/rustdesk/$1.git" |
    sed 's#.*refs/tags/##' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
}
WORDS='secur|cve|vuln|overflow|traversal|inject|auth|bypass|sanitiz|privilege|permission|junction|symlink|validat|guard|spoof|leak|crash|panic'

new=0
report() { # $1: repository, $2: subtree in this repository
  local repo=$1 dir=$2 base tip
  base="$(baseline "$repo")"; tip="$(latest "$repo")"
  if [[ -z $base || -z $tip ]]; then
    echo "## $repo"; echo; echo "Не удалось определить версии (baseline: '$base', upstream: '$tip')."; echo
    new=1; return
  fi
  if [[ $base == "$tip" ]]; then
    echo "## $repo: $base — актуально"; echo; return
  fi
  new=1
  echo "## $repo: $base → $tip"; echo
  git fetch -q --no-tags "https://github.com/rustdesk/$repo.git" \
    "refs/tags/$base:refs/tags/upstream-$dir-$base" "refs/tags/$tip:refs/tags/upstream-$dir-$tip"
  local range="upstream-$dir-$base..upstream-$dir-$tip"
  echo "Коммитов: $(git rev-list --count "$range"). Похожи на исправления безопасности и надёжности:"; echo
  git log --format='- `%h` %ad %s' --date=short "$range" | grep -iE "$WORDS" | head -60 || echo "- не найдено по ключевым словам"
  echo
  local tree; tree="$(mktemp -d)"
  git worktree add -q --detach "$tree" HEAD
  local out conflicts
  out="$(git -C "$tree" -c user.name=check -c user.email=check@invalid -c merge.renameLimit=20000 \
    merge --no-ff --no-commit -X "subtree=$dir" "upstream-$dir-$tip" 2>&1 || true)"
  conflicts="$(git -C "$tree" diff --name-only --diff-filter=U | grep -v '/src/lang/' || true)"
  echo "Пробное слияние (\`-X subtree=$dir\`): конфликтов $(grep -c '^CONFLICT' <<<"$out" || true), из них вне переводов:"; echo
  if [[ -n $conflicts ]]; then sed 's/^/- `/; s/$/`/' <<<"$conflicts" | head -60; else echo "- нет"; fi
  echo
  git worktree remove --force "$tree"
}

echo "# Новые версии upstream"; echo
report rustdesk client
report rustdesk-server server
echo "Порядок слияния — \`docs/UPSTREAM.md\`, «Как сливать новый RustDesk». Отсутствие конфликта не доказывает, что наши правки на месте: после слияния обязательны \`scripts/ci/*.sh\` и сверка списка правок."
[[ $new == 0 ]] || exit 10
