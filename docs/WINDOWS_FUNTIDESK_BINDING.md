# Windows FuntiDesk infrastructure binding (MIK-15)

## Scope and baseline

This document records the first production-oriented Windows client binding for
FuntiDesk. It is based on the accepted MIK-19 Windows build environment and
RustDesk client baseline `1.4.9` (`6c578292e8ebbbec708b76986ba8c4bc7c509747`).
Vendored client `hbb_common` remains at
`7e1c392c62d39c364127307cd408421dd5f8cfb0`; no upstream update or server
source change is included.

The changes are deliberately limited to infrastructure trust/configuration and
build validation. This is not a UI/branding redesign. The upstream `RustDesk`
product name remains visible in this milestone.

## Production trust model

| Parameter | Production value |
|---|---|
| Rendezvous host | `desk.funti.cc` |
| Rendezvous port | `21116` (standard RustDesk semantics) |
| Relay | supplied by hbbs; fallback is standard `desk.funti.cc:21117` |
| Server Ed25519 public key | `2R3kWM1HR3BMoz3EB6KDmv5SjOKrDEVdrZXRcFWaDg4=` |
| Numeric device ID | retained |

The endpoint and key are compile-time constants in
`client/libs/hbb_common/src/config.rs`. The client does not use `custom.txt`,
an executable-name licence, persisted server options, UI input, or a normal
user environment variable to select another rendezvous/key.

## Architecture and changed source paths

- `client/libs/hbb_common/src/config.rs`
  - binds `RENDEZVOUS_SERVERS` and `RS_PUB_KEY` to FuntiDesk;
  - rejects/clears persisted and bulk-applied endpoint/key options:
    `custom-rendezvous-server`, `rendezvous-servers`, `relay-server`,
    `api-server`, `key`, and `other-server-key`;
  - always returns the compile-time rendezvous host;
  - does not use runtime rendezvous/key overrides.
- `client/src/common.rs`
  - returns only the compile-time server key;
  - makes upstream signed custom-client payload processing a no-op, per
    ADR-002.
- `client/src/client.rs`
  - makes a rendezvous signing-key mismatch terminal (`bail!`); the old
    insecure fallback is removed;
  - strips the `@foreign-server?key=...` suffix from a peer ID, so it cannot
    select an alternate rendezvous/trust path; the numeric peer ID is resolved
    only through FuntiDesk infrastructure.
- `client/src/rendezvous_mediator.rs`
  - preserves hbbs-provided relay selection; if hbbs omits a relay it uses the
    standard `host + 1` RustDesk rule, yielding `desk.funti.cc:21117`.
  - does not read a local `relay-server` override.
- `client/flutter/lib/desktop/pages/desktop_setting_page.dart`
  - hides ID Server / Relay Server / API Server / Key controls. Unrelated proxy
    and WebSocket controls remain.

The production policy is fail closed: DNS failure, unavailable `desk.funti.cc`,
or a key mismatch produces a connection failure. No branch may select public
RustDesk rendezvous/relay or downgrade a mismatched server key.

## External network endpoints

MIK-15 distinguishes trust-critical infrastructure from auxiliary network
services. Rendezvous and relay are FuntiDesk-only. The upstream NAT diagnostics
still use the following public STUN endpoints:

- `stun.l.google.com:19302`
- `stun.cloudflare.com:3478`
- `stun.nextcloud.com:3478`

They are not RustDesk rendezvous/relay servers and cannot provide a FuntiDesk
server key or redirect a peer connection. They remain an explicit external
dependency to review again before Family Release, per `docs/SECURITY.md`.

## Custom client and runtime override decision

`load_custom_client()` may still discover `custom.txt` as an upstream call
site, but `read_custom_client()` is deliberately inert in this production
build. It cannot change the app name, endpoints, relay, key, default settings,
override settings, or security policy.

The Rust policy enforces the same decision even if a stale local configuration
file has dangerous values. The Flutter controls are hidden to avoid presenting
a nonfunctional/server-redirection UI. Development/test variants, if needed in
the future, must be explicit separate builds; they are not selected by normal
runtime input here.

## Automated validation

Run from repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/windows/validate-funtidesk-binding.ps1
```

The validator fails unless the compiled FuntiDesk endpoint/key are present,
public RustDesk rendezvous endpoints are absent from the effective production
path, custom-client loading is a no-op, insecure key fallback is gone, and
runtime server/key overrides are blocked.

Latest result: `FUNTIDESK_BINDING_VALIDATION_OK=true`.

## Windows build environment and artifact

| Component | Value |
|---|---|
| Windows | Windows 11 Pro build 22631 x64 |
| MSVC | 14.44.35207 |
| Windows SDK | 10.0.22621.0 |
| Rust | 1.75.0 (`x86_64-pc-windows-msvc`) |
| Flutter bridge | 3.22.3 |
| Flutter build | 3.24.5 with pinned RustDesk Windows x64 engine |
| LLVM | 15.0.6 |
| vcpkg | `120deac3062162151622ca4860575a33844ba10b` |
| vcpkg triplet | `x64-windows-static` |
| Python | 3.11.15 |

Build entry point:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/windows/build-funtidesk.ps1
```

The build invokes the accepted MIK-19 pipeline after running the binding
validator. Flutter plugin operations require Windows symbolic-link privilege;
this host uses the verified per-user `Hermes_Gateway_Elevated` task for that
build context rather than enabling Developer Mode.

The earlier pre-review artifact (SHA-256
`151B6B5D319D8E6CAB43E5BA67EAE463F3053A240ECB2F3766BFC08C72ADF1CB`)
was built from head `83201432e9bd3324a87ec402ab3ce7eaf809dd50`.
It is retained only as historical evidence and is **not** the acceptance artifact
for the architect-reviewed branch. A fresh build and SHA-256 are required after
the review corrections.

## Reviewed CI candidate

The architect-reviewed Windows x64 candidate is built by the root GitHub Actions
workflow `.github/workflows/mik15-windows-reviewed.yml`.

Accepted CI build:

```text
workflow_run=35569932541
head_sha=4ef3719cf0ea830deb5cfcabeeef45718fcb4ffa
artifact_name=mik15-windows-x64-4ef3719cf0ea830deb5cfcabeeef45718fcb4ffa
artifact_id=10626907901
artifact_bundle_size=32402450
artifact_file_count=93
rustdesk.exe_sha256=C19CA395239258BAF0FFF5D939679CE2B3C0CF2F8045E5EBD730CA7A3ACA3698
runner=windows-2022
```

The workflow completed successfully through binding validation, bridge generation,
pinned LLVM/Rust/Flutter/vcpkg setup, Windows x64 build, manifest generation and
artifact upload.

## Acceptance matrix

| Scenario | Result | Evidence |
|---|---|---|
| Build and launch | CI BUILD PASS; runtime launch pending | reviewed full runtime bundle built successfully by GitHub Actions run `35569932541`; local runtime launch still required |
| Normal rendezvous | RECHECK REQUIRED | pre-review artifact used only `desk.funti.cc`; repeat after fresh build |
| Public RustDesk connection | RECHECK REQUIRED | source invariant is present; repeat runtime observation after fresh build |
| Server unavailable fail-closed | PASS (local network isolation) | temporarily blocked only `107.172.76.106` for this artifact using two temporary outbound firewall rules; process stayed up, established TCP count was `0`, public RustDesk TCP count was `0`; rules were removed in `finally` |
| `custom.txt` override | PASS | malicious local `custom.txt` attempting app name, ID server, relay, key, default and override settings was ignored; artifact launched with the normal `RustDesk` title and made no public RustDesk TCP connection |
| Wrong server key | SOURCE-LEVEL PASS; runtime peer handshake pending | mismatch branch is terminal `Handshake failed: server key mismatch`, with no insecure fallback. A live peer handshake needs a second test endpoint. |
| Direct P2P | PENDING | current NAT is `ASYMMETRIC`; a second Windows endpoint is not available in this test run |
| hbbr relay `:21117` | PENDING | needs a second endpoint and an actual session/forced relay |
| Remote control | PENDING | needs a second Windows endpoint |
| Clipboard | PENDING | local initialization logged; end-to-end transfer needs a second Windows endpoint |
| File transfer | PENDING | local file-transfer clipboard context initialized; end-to-end transfer needs a second Windows endpoint |
| Portable mode | SMOKE PASS | artifact is built with `--portable`; it launched and started its portable service |
| Installed mode | PENDING | no installer acceptance run in this milestone |
| Service mode | PENDING | no two-endpoint/service-session acceptance run in this milestone |

The earlier historical `rs-ny.rustdesk.com` log belongs to a pre-MIK-15
installed upstream RustDesk instance. The current artifact log is timestamped
`2026-09-19 13:45` and names only `desk.funti.cc` for rendezvous/NAT.

## Known limitations and next acceptance step

A successful local build and single-client registration are not evidence for
remote-control, clipboard, file transfer, direct P2P, or relay operation. To
close MIK-15 fully, run the same FuntiDesk artifact on a second Windows endpoint
and record one direct attempt, one forced/natural hbbr relay attempt on
`desk.funti.cc:21117`, a wrong-key variant handshake, remote control,
clipboard, and file transfer. No server runtime, firewall, deployment, ports,
or server identity was changed for this work.
