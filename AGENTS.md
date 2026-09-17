# FuntiDesk Working Rules

This file defines how humans and AI agents work on FuntiDesk.

## Source of truth

GitHub is authoritative for code, architecture, ADRs, security rules, release procedures and operational documentation. Linear is used for planning and execution status.

## Roles

- **Owner** — defines product intent and accepts user-facing outcomes.
- **Lead architect/developer (ChatGPT)** — owns architecture, implementation planning, code changes, reviews, documentation consistency and acceptance criteria.
- **Execution/deployment agents** — may build, test, deploy and diagnose within the boundaries defined in the repository. They do not silently redefine architecture or product behaviour.

## Development rules

1. Prefer small, reviewable changes with explicit acceptance criteria.
2. Do not modify protocol/core code unless configuration, adapters or product layers cannot solve the requirement cleanly.
3. Security-sensitive failures must fail closed. No silent fallback to public or untrusted infrastructure.
4. Never commit private keys, passwords, signing secrets or production credentials.
5. Keep user-facing terminology FuntiDesk-specific. Upstream names belong only in engineering, licensing and attribution contexts where needed.
6. Do not copy upstream UI mechanically. New screens should follow FuntiDesk information architecture and interaction patterns.
7. Preserve required open-source notices and licence obligations.
8. Every production-impacting change must be reproducible from the repository.
9. Update relevant documentation when architecture, deployment, security or operational behaviour changes.
10. Linear issue state must reflect actual work state; GitHub history remains the evidence of implementation.

## Delivery order

M0 Architecture → M1 Server → M2 Windows MVP → M3 E2E validation → M4 Family release → Android → iOS → optional device/account management.

## Acceptance philosophy

The project is considered working only when behaviour is verified end-to-end on real clients. A successful compile is not acceptance.
