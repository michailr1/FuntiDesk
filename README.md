# FuntiDesk

FuntiDesk is a self-hosted remote desktop project based on the open-source RustDesk ecosystem.

## Goal

Build a private remote-access stack for personal use, family and friends where all rendezvous/relay traffic uses infrastructure we control.

## Product decisions

- Keep the RustDesk numeric device ID as a universal fallback connection method.
- Add human-friendly device names and a device list later without replacing the underlying ID model.
- Do not depend on public RustDesk rendezvous/relay infrastructure.
- Start with Windows-to-Windows, then Android and iOS clients.
- Minimize changes to the upstream protocol/core so upstream security and compatibility updates remain practical to merge.

## Initial milestones

1. **M0 — Architecture**: baseline upstream, fork strategy, licensing, trust/security model.
2. **M1 — Self-hosted Server**: reproducible hbbs/hbbr deployment.
3. **M2 — Windows MVP**: first Windows build configured only for FuntiDesk infrastructure.
4. **M3 — End-to-End Validation**: P2P, relay fallback, NAT, reboot, UAC/login, clipboard and file transfer.
5. **M4 — Family Release**: branding, simple installer/portable mode, friendly device names and safe unattended access.

## First acceptance criterion

Two Windows machines running FuntiDesk can connect through infrastructure we control, including both direct P2P and relay fallback, without relying on public RustDesk servers.

## Project management

Code and pull requests live in GitHub. Roadmap, dependencies and execution status live in Linear.

## License

The upstream RustDesk client is licensed under GNU AGPL v3. FuntiDesk will preserve all applicable license and source-distribution obligations. Exact notices and third-party attribution will be finalized as part of M0.
