# FuntiDesk runtime network allowlist

Статус: security baseline для M2 / R-14.

Цель документа — отделить необходимые runtime-соединения FuntiDesk от build-time загрузок и пользовательских ссылок.

## Разрешённые автоматические runtime endpoints

| Endpoint | Protocol | Purpose |
|---|---|---|
| `desk.funti.cc:21115` | TCP | NAT type probe |
| `desk.funti.cc:21116` | TCP | rendezvous / TCP hole punching |
| `desk.funti.cc:21116` | UDP | registration / heartbeat |
| `desk.funti.cc:21117` | TCP | relay fallback |
| `stun.l.google.com:19302` | STUN | public address discovery only |
| `stun.cloudflare.com:3478` | STUN | public address discovery fallback |
| `stun.nextcloud.com:3478` | STUN | public address discovery fallback |

Third-party STUN is explicitly allowed for NAT/address discovery; remote-control payload, authentication secrets and relay traffic must not be sent to these STUN services.

System DNS/NTP and operating-system traffic are outside the FuntiDesk process allowlist.

## Explicitly disabled runtime endpoints

Production code must not perform background requests to:

- `api.rustdesk.com`;
- `admin.rustdesk.com`;
- public RustDesk rendezvous/relay infrastructure.

The upstream update checker is a no-op until FuntiDesk owns an update channel (R-30). The API-server resolver returns an empty string because no FuntiDesk account/API service exists in M2.

Documentation/help URLs that a user explicitly opens in an external browser are not background FuntiDesk network dependencies; they remain subject to later branding cleanup.

## Build-time network

GitHub Actions, Flutter/LLVM/vcpkg bootstrap and package registries are build-time dependencies and are not part of the runtime allowlist. R-21 pins security-sensitive Windows build assets by immutable identity/SHA256.

## Acceptance capture

Before Family Release, capture DNS/TCP/UDP from a clean Windows VM for:

1. idle startup;
2. normal ID-based connection;
3. forced relay;
4. server unavailable;
5. wrong server key;
6. network switch/reconnect.

Any FuntiDesk process destination outside this allowlist requires a documented decision before release.
