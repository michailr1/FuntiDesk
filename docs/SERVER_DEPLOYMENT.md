# FuntiDesk Server — M1 deployment

Текущий production endpoint: `desk.funti.cc` (`173.249.195.36`) на shared VM `core.funti.cc`.

FuntiDesk использует на shared VM только OSS-компоненты `hbbs` и `hbbr` и свой persistent root `/opt/funtidesk`. На том же хосте могут работать другие production-сервисы; FuntiDesk deployment не должен изменять их конфигурацию, контейнеры, firewall-правила или listeners.

## Baseline

Server baseline: `1.1.16`.

Container image фиксируется по tag + amd64 digest:

```text
ghcr.io/rustdesk/rustdesk-server:1.1.16@sha256:5c5d42feed1c85c54ffebaaf478dc2551e3efbab1b9ea97bc8bed5815f8c1d54
```

## Порты

Для Windows MVP открываем только минимально необходимый набор:

| Port | Proto | Component | Purpose |
|---|---|---|---|
| 21115 | TCP | hbbs | NAT type test |
| 21116 | TCP | hbbs | connection / TCP hole punching |
| 21116 | UDP | hbbs | ID registration / heartbeat |
| 21117 | TCP | hbbr | relay |

`21118/TCP` и `21119/TCP` не публикуются: Web Client не входит в текущий scope.

`21114/TCP` не используется: это Pro/API path.

## Persistent state

Runtime root:

```text
/opt/funtidesk
├── repo
├── server.env
├── data
└── backups
```

Ключи сервера создаются `hbbs` в persistent каталоге `/opt/funtidesk/data`.

Приватный ключ никогда не коммитится в Git.

## Deployment

На VM repository должен находиться в:

```text
/opt/funtidesk/repo
```

Deployment:

```bash
sudo bash /opt/funtidesk/repo/scripts/server/deploy.sh
```

После запуска выполняется `verify.sh`, который проверяет containers, listeners, отсутствие WebSocket ports и наличие persistent server identity.

## Firewall / SSH

До публичной приёмки агент должен:

1. сохранить работающий SSH-доступ;
2. убедиться, что текущая SSH-сессия стабильна;
3. выполнить `sudo bash scripts/server/apply-firewall.sh`;
4. проверить, что новая SSH-сессия по-прежнему открывается;
5. убедиться, что FuntiDesk использует только `21115/TCP`, `21116/TCP+UDP`, `21117/TCP`;
6. не открывать `21118/21119`;
7. не изменять правила, listeners или контейнеры других сервисов shared VM.

Изменение SSH root/password policy выполняется только после подтверждения key-based доступа, чтобы исключить lockout.

## Backup

`scripts/server/backup.sh` создаёт root-only archive persistent `data` и SHA-256.

Минимум для M1:

- создать backup после генерации server identity;
- выполнить `restore-check.sh`;
- скопировать backup **off-host** в разрешённое владельцем хранилище;
- не удалять последнюю рабочую копию server private key;
- хранить authoritative runtime identity и проверенный защищённый backup на `core.funti.cc`.

## Migration state

Production migration завершена:

- `desk.funti.cc -> 173.249.195.36` (`core.funti.cc`);
- server identity сохранена, публичный ключ остался `2R3kWM1HR3BMoz3EB6KDmv5SjOKrDEVdrZXRcFWaDg4=`;
- old RackNerd/ai source больше не является rollback-площадкой FuntiDesk;
- на старой VM удалены hbbs/hbbr, RustDesk server image, `/opt/funtidesk` вместе со старой копией private identity и FuntiDesk firewall rules;
- authoritative FuntiDesk runtime/backup state находится на `core.funti.cc`.

Старые адреса `107.172.76.106`, `107.172.73.97` и `23.94.233.131` относятся только к истории миграции и не должны использоваться в текущих deployment/acceptance инструкциях.

## Acceptance

M1 считается готовым, когда подтверждены:

- `hbbs` и `hbbr` running;
- listeners только на минимальных RustDesk ports;
- public key получен и сохранён для последующего client binding;
- server identity переживает container restart/recreate;
- backup создан;
- backup проходит restore-check;
- firewall применён без потери SSH;
- нет зависимости от публичных RustDesk rendezvous/relay.

Client security binding выполняется позже в M2.
