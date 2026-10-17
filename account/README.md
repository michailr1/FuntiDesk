# FuntiDesk account API

Кабинет работает на Core с SQLite и SMTP по [ADR-013](../docs/ADR-013-core-only-account.md). Другой сервер или witness не требуются. Собственная учётная запись хранит устройства, копии семьи, отзывы, избранное и историю; вход по почте не даёт доступа к экрану компьютера.

Для запуска нужны `FUNTI_ACCOUNT_KEY_FILE` с существующим закрытым ключом, `FUNTI_ACCOUNT_DATABASE`, SMTP host/port и локальный registry socket hbbs. Секреты не выводятся и не входят в Git. Значения конфигурации и закрытая поставка — [ACCOUNT_DEPLOYMENT.md](../docs/ACCOUNT_DEPLOYMENT.md).

Обычный запуск `funtidesk-account` требует уже существующей базы. `funtidesk-account initialize` создаёт только новую отсутствующую базу и отказывает поверх существующего пути. `Store::open` обновляет существующую схему до v4; account key и прикладные данные сохраняются. Новая схема удаляет только старые witness-метаданные. Команды witness/relay/restore удалены.

Проверки: `cargo test --manifest-path account/Cargo.toml --locked`, fmt/Clippy, `scripts/web/account-browser-test.mjs` с настоящим локальным API и `scripts/account/smoke-mail.py` с SMTP в изолированной Docker-сети. Восстановление обычной SQLite-копии описано в [ACCOUNT_RECOVERY.md](../docs/ACCOUNT_RECOVERY.md).
