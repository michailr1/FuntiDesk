#!/usr/bin/env bash
# FuntiDesk Dart checks that need only the Dart SDK: an empty package config
# keeps `dart` from resolving the app's dependencies (no `pub get`).
set -euo pipefail
cd "$(dirname "$0")/../../client/flutter"
packages=$(mktemp)
trap 'rm -f "$packages"' EXIT
echo '{"configVersion":2,"packages":[]}' > "$packages"
for f in test/funti/*_check.dart; do
  echo "==> $f"
  dart --packages="$packages" "$f"
done
