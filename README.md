# FuntiDesk

FuntiDesk is a private self-hosted remote-access platform for personal use, family and friends.

## Product goal

Provide simple, reliable remote access where identity, rendezvous, relay, configuration, releases and future device management are controlled by FuntiDesk infrastructure.

## Product principles

- All production clients use only FuntiDesk infrastructure.
- Keep a numeric device ID as a universal fallback connection method.
- Add human-friendly device names, favourites and a device list without breaking the underlying ID model.
- Start with Windows-to-Windows, then Android and iOS clients.
- Build a distinct FuntiDesk product identity and UX rather than a re-skinned upstream interface.
- Keep low-level protocol/core changes minimal where possible so security and compatibility fixes remain practical to integrate.
- Security-sensitive behaviour must be explicit, documented and fail closed.

## Initial milestones

1. **M0 — Architecture**: baseline, fork strategy, licensing, trust/security model and product identity rules.
2. **M1 — Self-hosted Server**: reproducible rendezvous/relay deployment.
3. **M2 — Windows MVP**: first Windows client configured only for FuntiDesk infrastructure.
4. **M3 — End-to-End Validation**: P2P, relay fallback, NAT, reboot, UAC/login, clipboard and file transfer.
5. **M4 — Family Release**: distinctive UI, simple installer/portable mode, friendly device names and safe unattended access.

## First acceptance criterion

Two Windows machines running FuntiDesk can connect through infrastructure we control, including both direct P2P and relay fallback, without relying on any third-party public rendezvous/relay service.

## Project governance

- GitHub is the source of truth for code, architecture, roles, plans, ADRs and operational documentation.
- Linear tracks execution status, priorities and dependencies.
- Changes to production behaviour are implemented through repository history and reviewed against documented acceptance criteria.

See:

- `AGENTS.md` — working rules and agent responsibilities.
- `docs/ROLES.md` — project roles and decision ownership.
- `docs/ROADMAP.md` — delivery plan and milestones.
- `docs/PRODUCT.md` — product and UX principles.
- `docs/ARCHITECTURE.md` — technical architecture.
- `docs/UPSTREAM.md` — upstream integration strategy.

## Licensing and attribution

FuntiDesk is built using open-source components. Required license, copyright and source-availability notices are preserved in the repository and distributions where legally required. Product-facing UI and documentation should otherwise use FuntiDesk naming and identity.
