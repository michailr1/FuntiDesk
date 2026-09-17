#!/usr/bin/env bash
set -euo pipefail

CLIENT_REPO="https://github.com/rustdesk/rustdesk.git"
SERVER_REPO="https://github.com/rustdesk/rustdesk-server.git"
COMMON_REPO="https://github.com/rustdesk/hbb_common.git"

CLIENT_SHA="6c578292e8ebbbec708b76986ba8c4bc7c509747"
SERVER_SHA="73523b31cfd25d77dee862e6fc9f5e1fb5e485ef"
CLIENT_COMMON_SHA="7e1c392c62d39c364127307cd408421dd5f8cfb0"
SERVER_COMMON_SHA="83419b6549636ee39dacef7776c473f5802e08d6"

if [[ ! -d .git ]]; then
  echo "Запускайте скрипт из корня клона FuntiDesk" >&2
  exit 1
fi

for p in client server; do
  if [[ -e "$p" ]]; then
    echo "Каталог $p уже существует; импорт остановлен, чтобы не смешать состояния" >&2
    exit 1
  fi
done

ensure_remote() {
  local name="$1" url="$2"
  if git remote get-url "$name" >/dev/null 2>&1; then
    git remote set-url "$name" "$url"
  else
    git remote add "$name" "$url"
  fi
}

ensure_remote upstream-client "$CLIENT_REPO"
ensure_remote upstream-server "$SERVER_REPO"
ensure_remote upstream-common "$COMMON_REPO"

git fetch upstream-client "$CLIENT_SHA"
git fetch upstream-server "$SERVER_SHA"
git fetch upstream-common "$CLIENT_COMMON_SHA"
git fetch upstream-common "$SERVER_COMMON_SHA"

echo "==> Импорт клиента"
git subtree add --prefix=client upstream-client "$CLIENT_SHA"
git rm -f client/libs/hbb_common client/.gitmodules
git commit -m "chore(import): заменить client hbb_common gitlink на vendored tree"
git subtree add --prefix=client/libs/hbb_common upstream-common "$CLIENT_COMMON_SHA"

echo "==> Импорт сервера"
git subtree add --prefix=server upstream-server "$SERVER_SHA"
git rm -f server/libs/hbb_common server/.gitmodules
git commit -m "chore(import): заменить server hbb_common gitlink на vendored tree"
git subtree add --prefix=server/libs/hbb_common upstream-common "$SERVER_COMMON_SHA"

cat > docs/BASELINE_IMPORT.md <<EOF
# Baseline import

Импорт выполнен без функциональных изменений FuntiDesk.

- client: \`rustdesk/rustdesk@$CLIENT_SHA\` (1.4.9)
- client/libs/hbb_common: \`rustdesk/hbb_common@$CLIENT_COMMON_SHA\`
- server: \`rustdesk/rustdesk-server@$SERVER_SHA\` (1.1.16)
- server/libs/hbb_common: \`rustdesk/hbb_common@$SERVER_COMMON_SHA\`

Внутренние \`.gitmodules\` удалены; обе версии \`hbb_common\` хранятся непосредственно в монорепозитории.
EOF

git add docs/BASELINE_IMPORT.md
git commit -m "docs: зафиксировать baseline import manifest"

echo "==> Проверка структуры"
test -f client/Cargo.toml
test -f client/libs/hbb_common/Cargo.toml
test -f server/Cargo.toml
test -f server/libs/hbb_common/Cargo.toml
test ! -e client/.gitmodules
test ! -e server/.gitmodules

if git ls-files -s client/libs/hbb_common | awk '$1==160000 {found=1} END{exit !found}'; then
  echo "В client/libs/hbb_common остался gitlink" >&2
  exit 1
fi
if git ls-files -s server/libs/hbb_common | awk '$1==160000 {found=1} END{exit !found}'; then
  echo "В server/libs/hbb_common остался gitlink" >&2
  exit 1
fi

echo "Импорт baseline завершён успешно. Проверьте git log и git status перед push."
