# FuntiDesk Roadmap

## M0 — Architecture

- Pin client/server baselines.
- Define upstream integration strategy.
- Define trust model and security baseline.
- Define product identity and UI separation rules.
- Define licensing/attribution boundaries.

Exit criteria: architecture and security decisions are documented and implementation can start without unresolved trust-model questions.

## M1 — Self-hosted Server

- Reproducible rendezvous/relay deployment.
- Persistent keys and configuration.
- Firewall/port documentation.
- Health checks and logs.
- Backup/restore of server identity material.

Exit criteria: server can be rebuilt from repository documentation and accepts only the intended FuntiDesk configuration.

## M2 — Windows MVP

- First FuntiDesk Windows build.
- FuntiDesk infrastructure preconfigured.
- No silent fallback to third-party public infrastructure.
- Numeric device ID retained.
- Remote control, clipboard and file transfer.
- Portable and installed/service modes.

Exit criteria: two Windows clients can connect using FuntiDesk infrastructure.

## M3 — End-to-End Validation

- Direct P2P path.
- Relay fallback path.
- Different NAT/provider scenarios.
- Restart/reconnect.
- Login screen/UAC.
- Clipboard and file transfer.
- Temporary and unattended access.

Exit criteria: acceptance matrix passes without dependency on third-party public rendezvous/relay services.

## M4 — Family Release

- Distinct FuntiDesk visual system and interaction model.
- Simple onboarding for family/friends.
- Device name + numeric ID.
- Favourites/recent devices.
- Installer and portable distribution.
- Safe unattended access defaults.

## Later

- Android client.
- iOS client.
- Optional device/account management layer.
- Signed releases and controlled auto-update.
