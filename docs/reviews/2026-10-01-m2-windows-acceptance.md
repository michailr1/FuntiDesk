# FuntiDesk M2 — Windows security acceptance

Scope: manual/network acceptance for R-10…R-16 after automated CI is green. This document is evidence-oriented: every scenario records exact build SHA, client logs, network evidence, and PASS/FAIL.

## Test build

- Branch: `michailr/m2-security-review-fixes`
- Required source head: replace with the final validated commit before execution.
- Use only the GitHub Actions artifact produced by `.github/workflows/r21-windows-clean-build.yml`.
- Both Windows endpoints must use the same artifact unless a scenario explicitly requires a modified negative-test build/config.
- Preserve prior working FuntiDesk runtime/profile as rollback material. Do not reuse upstream RustDesk tokens or public-server settings.

## Evidence bundle

For each scenario preserve:

- exact Git commit SHA;
- SHA256 of the tested `rustdesk.exe` / FuntiDesk runtime executable;
- relevant `%APPDATA%\RustDesk\log\rustdesk_rCURRENT.log` excerpt with timestamps;
- DNS/TCP/UDP capture or equivalent connection inventory;
- hbbs/hbbr logs for matching timestamps when server-side evidence is relevant;
- PASS/FAIL and observed user-facing error.

Never record passwords, private server keys, access tokens, or age identities.

## A1 — R-11 renamed executable negative test

1. Copy the tested executable/runtime to a separate directory.
2. Rename the executable to a RustDesk-style infrastructure-bearing name, for example one containing a foreign host and key.
3. Start it with an otherwise clean profile.
4. Verify the process still registers only against `desk.funti.cc:21116`.
5. Verify no foreign host/key is persisted to user config.
6. Capture DNS/network evidence.

PASS: executable name has no effect on rendezvous, relay, API, or server trust key.

## A2 — R-12 hostile saved configuration

1. With the application closed, place foreign rendezvous/relay/API/key values into a disposable test profile.
2. Start FuntiDesk.
3. Verify runtime uses only the build-time FuntiDesk rendezvous and trust key.
4. Make `desk.funti.cc` temporarily unreachable in the isolated test environment; do not change production DNS.
5. Verify there is no fallback to any upstream RustDesk rendezvous/relay/API endpoint.

PASS: mutable config cannot redirect production infrastructure and server-down produces failure, not fallback.

## A3 — R-13 custom.txt negative test

1. Place an upstream-style `custom.txt` next to the executable in an isolated test copy.
2. Start the application.
3. Verify app name, endpoints, trust key, and security policy remain FuntiDesk values.
4. Repeat with malformed `custom.txt`.

PASS: `custom.txt` has no runtime trust or policy effect.

## A4 — R-10 wrong rendezvous/server key

Use an isolated test rendezvous endpoint or controlled negative build/config fixture; do not rotate the production key.

Test:
- rendezvous presents a different signing key;
- client has a wrong trust key;
- signed peer key is missing/invalid or peer ID does not match.

PASS: connection is rejected with a clear authentication/integrity error; no remote desktop session opens and no plaintext fallback exists.

## A5 — R-10 receiving-side invalid PublicKey

Inject/produce a connection attempt where the receiving side gets:
- empty `PublicKey.asymmetric_value`;
- invalid asymmetric key length;
- empty symmetric value;
- `secure == false` path where reachable.

PASS: receiving side terminates the connection before `Connection::start`; no application session starts.

## A6 — R-15 clean-profile defaults

Start with a disposable clean FuntiDesk profile and record the effective values.

Expected production policy:

| Setting | Expected |
|---|---|
| direct server / direct-IP exposure | disabled/locked |
| LAN discovery | disabled/locked |
| remote config modification | disabled/locked |
| permanent unattended password | not enabled by default |
| temporary password | enabled |
| approval/verification mode | explicit documented safe value |
| insecure TLS/API fallback | disabled |

PASS: defaults match policy without inheriting old RustDesk profile values.

## A7 — R-14 runtime network allowlist

On a clean Windows endpoint capture DNS and TCP/UDP for each scenario separately:

1. application startup, idle 2 minutes;
2. successful connection via rendezvous/direct P2P;
3. relay fallback session;
4. `desk.funti.cc` unavailable;
5. wrong-key/authentication failure.

Compare with `docs/NETWORK_ALLOWLIST.md`.

PASS: no runtime connections occur outside the committed allowlist. Static documentation hyperlinks do not count unless actually contacted by the process.

## A8 — final Windows↔Windows functional regression

With the same validated security build on both endpoints:

- correct ID connection;
- remote picture/control;
- clipboard both directions;
- file transfer both directions;
- direct P2P proof;
- relay fallback proof;
- network switch scenario from MIK-16 without application restart.

PASS: security changes do not regress required MVP functions. Record transport evidence for direct and relay cases.

## Release gate

Do not distribute the M2 build to family/friends until A1–A8 are recorded PASS, or any accepted exception is documented in the external review developer-response table with rationale.
