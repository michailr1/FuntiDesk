# FuntiDesk Product Identity

## Positioning

FuntiDesk is a small private remote-access product for the owner, family and trusted friends. It should feel intentionally designed for this use case rather than like a generic enterprise remote-desktop tool.

## Naming

User-facing naming should use **FuntiDesk** consistently.

Avoid upstream project names in:

- window titles;
- installer names;
- tray/menu labels;
- onboarding;
- settings labels;
- help text intended for end users;
- screenshots and release notes intended for family/friends.

Upstream references remain only where required or useful for engineering history, licensing, attribution and update tracking.

## UX separation

FuntiDesk must not be a cosmetic recolour of the upstream interface.

The first family-facing UI should be redesigned around these primary actions:

1. **My device** — device name, numeric ID, connection state and access controls.
2. **Connect** — one clear field for device ID/name plus recent/favourite devices.
3. **My devices** — friendly names and status, added after MVP.
4. **Settings** — simplified settings relevant to trusted personal use.

Advanced transport/server configuration should not be part of normal end-user flows because production builds are bound to FuntiDesk infrastructure.

## Visual direction

- independent iconography and application icon;
- independent typography/spacing/layout decisions where practical;
- avoid reproducing the same home-screen hierarchy and component arrangement;
- simple, calm interface with few primary actions;
- Russian-first UX initially, with localisation architecture retained;
- infrastructure details hidden from normal users;
- clear security state: temporary access vs unattended access must never look interchangeable.

## Device identity

Keep the numeric device ID for compatibility and easy one-off support.

Preferred presentation:

**Home PC**  
ID: `123 456 789`  
Online

The friendly name is primary; numeric ID is secondary but always accessible.

## Product rule

Whenever there is a choice between preserving upstream UI similarity and creating a clearer FuntiDesk-specific workflow, prefer the FuntiDesk-specific workflow unless doing so would materially destabilise the core remote-control functionality.
