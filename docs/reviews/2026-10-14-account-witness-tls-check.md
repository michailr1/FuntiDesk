# Автоматическое обновление TLS независимой копии: установка на DE

Проверено 2026-10-14, окончательный контроль — `20:48:25 UTC`. Настройка разрешена владельцем. На DE установлен почасовой таймер синхронизации сертификата; первая передача, запуск в sandbox systemd и принудительная перезагрузка собственного Caddy прошли.

## Воспроизводимый источник

Установлен код commit [`6316cd2705d1e5dc696425ac26bea64438a2f14d`](https://github.com/michailr1/FuntiDesk/commit/6316cd2705d1e5dc696425ac26bea64438a2f14d) из чистого sparse checkout `/opt/funtidesk-account-witness-tls-source`, закреплённого в detached HEAD. Checkout занимает 392 238 байт.

Использован `scripts/account/install-witness-tls.sh`. SHA256 установленного `/usr/local/libexec/funtidesk-account-sync-witness-tls.py` совпал с репозиторием:

```text
c6764b2b02b94eaf3a9f81b97da37dc3cfddb9fe6c1a7ac52ca138dd83a6d7de
```

Установлены собственные service/timer и закрытый файл путей `/etc/funtidesk-account-witness-tls.env`. Процедура повторной установки и диагностики — [ACCOUNT_WITNESS_TLS.md](../ACCOUNT_WITNESS_TLS.md).

## Источник сертификата

Действующий системный Caddy активен, работает как `caddy`. У HTTP-серверов домена действует Automatic HTTPS по умолчанию; в runtime-конфигурации отсутствуют отключения автоматического HTTPS и ручные модули загрузки сертификатов. Пара найдена в управляемом хранилище Let's Encrypt:

```text
/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/de.funti.cc/de.funti.cc.crt
/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/de.funti.cc/de.funti.cc.key
```

Оба исходных файла имеют `0600`, UID `997`. Цепочка доверена системным CA, имя `de.funti.cc` совпадает. Публичные даты сертификата: `2026-09-04 04:13:55 UTC` — `2026-12-03 04:13:54 UTC`. SHA256 сертификата в DER:

```text
a63818316d54c8dbe48e625dd1feafcb433fe99440db02ec8efc2ebd5ee5268f
```

Следующий выпуск выполняет существующий Caddy по своему расписанию. Эта проверка подтверждает передачу и загрузку пары; смена пары проверена отдельно с тестовым CA.

## Работа на сервере

- `funtidesk-account-witness-tls.timer`: **enabled**, **active**.
- Последний service: `Result=success`, `ExecMainStatus=0`.
- Применён sandbox: `ProtectSystem=strict`, `ProtectHome=yes`, `NoNewPrivileges=yes`.
- Следующее срабатывание на момент контроля: `2026-10-14 21:48:01 UTC`, затем раз в час с небольшим случайным сдвигом.
- Каталог получателя и генерация: root/`0700`; сертификат и ключ: root/`0600`.

Для проверки запущен временный Caddy с закреплённым digest `sha256:748016f285ed8c43a9ce6e3aed6d92d3009d90ca41157950880f40beaf3ff62b`, labels собственного Compose-проекта и loopback admin внутри контейнера. Он читает только закрытый каталог получателя; исходное хранилище Caddy в него не монтируется.

Настоящее TLS-соединение с DE проверило доверие, имя и точное совпадение выдаваемого сертификата с источником. Внешний HTTPS-запрос к временному `/_tls-check` на 8447 дал `200` и ожидаемый ответ. Запуск **установленного** service привёл к `WITNESS_TLS_SYNC_OK: unchanged and reloaded`; HTTPS после reload сохранил правильный сертификат.

Временный контейнер, конфиг и загруженный для теста образ удалены. Порт 8447 снова свободен. Системный Caddy остался активен с PID `3668003`; SHA256 канонической runtime-конфигурации до и после совпал:

```text
82c0c579ead36d8b1fa6b21802b0cedbe3d21789eb4d182238db032d251c8abc
```

После уборки свободно `1 501 769 728` байт на DE. Данные account/witness и почтовая инфраструктура остаются предметом следующего развёртывания.

## Локальные проверки

Прошли `test-witness-tls.py` с отказом неверному имени/паре/правам, откатом при ошибке reload и сбоями `fsync`; синтаксис installer, проверка systemd units, Compose/Caddy validation. Настоящий HTTPS smoke с тестовым CA подтвердил смену сертификата и восстановление reload после обрыва процесса между публикацией и перезагрузкой. В том же сценарии прошли подписанный witness head и отказ неверному HMAC.

TLS-механизм установлен. Следующий этап — запуск собственного witness/account, проверка свежего подписанного head в рабочем контуре, внешней почты и реальных клиентов по критериям M3.
