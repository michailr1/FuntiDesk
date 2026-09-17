# FuntiDesk Architecture

Status: draft for M0.

## Scope

FuntiDesk is a private self-hosted remote desktop system based on RustDesk. The first production target is Windows-to-Windows remote access for a small trusted circle (owner, family, friends).

## Core topology

```text
FuntiDesk client A
        |
        | rendezvous / registration
        v
      hbbs
        |
        +---- direct P2P when possible ----> FuntiDesk client B
        |
        +---- relay fallback via hbbr -----> FuntiDesk client B
```

## Initial components

- **Client**: fork of `rustdesk/rustdesk`.
- **Rendezvous server**: RustDesk Server OSS `hbbs`.
- **Relay server**: RustDesk Server OSS `hbbr`.
- **Infrastructure**: DNS, firewall, persistent server keys/configuration, logs and backups under our control.

## Decisions already made

### Device identity

The existing RustDesk numeric ID remains part of the protocol and UI as a universal fallback. Human-friendly device names and a saved-device list may be layered on top later.

### Public RustDesk infrastructure

FuntiDesk clients must not silently fall back to public RustDesk rendezvous or relay infrastructure. Server endpoints and the expected server public key will be controlled by the FuntiDesk build/configuration.

### Upstream compatibility

Protocol/core modifications should be minimized. Branding, defaults and policy enforcement should be isolated where practical so upstream security fixes remain mergeable.

### Mobile direction

Android and iOS clients are planned after the Windows MVP and E2E validation. iOS is initially an outbound controller; platform restrictions on remote control of iOS itself are outside the Windows MVP scope.

## Security baseline

The first implementation must include:

- server public-key verification/pinning;
- no public-server fallback;
- protected persistent server private keys;
- documented backup/restore of server identity;
- explicit temporary vs permanent/unattended access modes;
- reproducible build/deployment documentation;
- no hidden remote access or silent privilege escalation.

## First acceptance criterion

Two Windows machines running FuntiDesk can connect without public RustDesk services in both cases:

1. direct P2P connection succeeds;
2. P2P is unavailable and traffic is relayed by our `hbbr`.

Additional E2E checks include NAT differences, reboot/reconnect, Windows login/UAC, clipboard and file transfer.

## Open M0 decisions

- exact upstream client commit/tag;
- exact upstream server commit/tag;
- repository import layout;
- update/merge policy for upstream releases;
- final product name/branding assets;
- deployment hostname(s) and environment separation;
- release signing and update trust chain.
