# Upstream baseline and merge policy

## Baseline

FuntiDesk starts from the latest stable upstream releases verified on 2026-09-17:

- Client: `rustdesk/rustdesk` tag `1.4.9`, commit `6c578292e8ebbbec708b76986ba8c4bc7c509747`.
- Server: `rustdesk/rustdesk-server` tag `1.1.16`, commit `73523b31cfd25d77dee862e6fc9f5e1fb5e485ef`.

We intentionally do not baseline on a moving `master` branch.

## Repository layout

FuntiDesk is planned as a single product repository with two upstream-derived trees:

```text
/client   # rustdesk/rustdesk derived source
/server   # rustdesk/rustdesk-server derived source
/docs
/infra
```

The initial source import should preserve upstream history where practical (preferred: `git subtree`/history-preserving import rather than copy-paste snapshots).

## Upstream remotes

Recommended local remotes:

```text
origin            -> github.com/michailr1/FuntiDesk
upstream-client   -> github.com/rustdesk/rustdesk
upstream-server   -> github.com/rustdesk/rustdesk-server
```

## Merge policy

1. Product-specific changes should be kept small and isolated.
2. Avoid protocol changes unless required for a documented FuntiDesk feature or security property.
3. Prefer build-time configuration, branding modules and policy wrappers over invasive edits to core networking/media code.
4. Track stable upstream releases, not nightly/master by default.
5. Review upstream security fixes promptly and merge them independently from feature upgrades when practical.
6. Every upstream rebase/merge must pass the FuntiDesk E2E matrix before release.

## Areas expected to diverge

- product name, icons and UI text;
- default/pinned rendezvous and relay endpoints;
- server public-key trust policy;
- prevention of fallback to public RustDesk infrastructure;
- packaging/installers and update channel;
- later: saved-device UX and friendly aliases layered over the existing numeric ID.

## Areas expected to stay close to upstream

- video/audio pipeline;
- screen capture;
- keyboard/mouse transport;
- clipboard/file transfer protocol;
- NAT traversal and relay protocol;
- platform-specific low-level code.

## Versioning

FuntiDesk releases will use their own product version while recording the incorporated upstream client/server baselines in release notes and build metadata.
