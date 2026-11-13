#!/usr/bin/env bash
# FuntiDesk client modules that need only std and serde_json (the connection
# journal store, ADR-020; the wake device list, ADR-021): built and tested on
# their own — the whole client does not build on a plain CI runner.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/src"
cat > "$work/Cargo.toml" <<TOML
[package]
name = "funti-client-parts"
version = "0.0.0"
edition = "2021"
[dependencies]
serde_json = "1.0"
TOML
cat > "$work/src/lib.rs" <<RS
#[path = "$root/client/src/funti_journal/store.rs"] pub mod journal_store;
#[path = "$root/client/src/funti_wake/devices.rs"] pub mod wake_devices;
#[path = "$root/client/src/funti_admin/rules.rs"] pub mod admin_rules;
#[path = "$root/client/src/funti_admin/autostart_rules.rs"] pub mod autostart_rules;
#[path = "$root/client/src/funti_admin/eventlog_rules.rs"] pub mod eventlog_rules;
RS
cargo test --manifest-path "$work/Cargo.toml"
