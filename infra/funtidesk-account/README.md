# Кабинет FuntiDesk на Core

По [ADR-013](../../docs/ADR-013-core-only-account.md) проект Compose содержит только account API и SMTP. SQLite и существующий account key находятся на Core; независимого witness, relay для него и зависимости от DE нет.

API доступен только во frontend-сети действующему Caddy; SMTP — только во внутренней сети API. SMTP использует собственную outbound-сеть для отправки писем. Публичные дополнительные порты API/SMTP не открываются. Resolver hbbs и действующие идентичности компьютеров сохраняются.

Поставка проверяется `check-config.py`, настоящим SMTP smoke и API/Chromium-тестами без witness. Точная поставка и обновление существующей базы — [ACCOUNT_DEPLOYMENT.md](../../docs/ACCOUNT_DEPLOYMENT.md). Секреты не входят в Git и архивы CI. `.env.example` содержит только пример конфигурации.
