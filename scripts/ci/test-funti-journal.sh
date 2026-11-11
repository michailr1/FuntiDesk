#!/usr/bin/env bash
# FuntiDesk connection journal (ADR-020): tests of its file store, built on
# its own — the whole client does not build on a plain CI runner.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/src"
cat > "$work/Cargo.toml" <<TOML
[package]
name = "funti-journal-store"
version = "0.0.0"
edition = "2021"
[dependencies]
serde_json = "1.0"
TOML
echo "#[path = \"$root/client/src/funti_journal/store.rs\"] pub mod store;" > "$work/src/lib.rs"
cargo test --manifest-path "$work/Cargo.toml"
