# Выпуски FuntiDesk по платформам

Пользовательские загрузки: [desk.funti.cc/#download](https://desk.funti.cc/#download).

| Платформа | Выпуски GitHub | Статус |
| --- | --- | --- |
| Windows x64 | [Только Windows](https://github.com/michailr1/FuntiDesk/releases?q=funtidesk-windows-&expanded=true) | EXE, ZIP и SHA256SUMS.txt; текущий стабильный выпуск — latest |
| Android arm64 | [Только Android](https://github.com/michailr1/FuntiDesk/releases?q=funtidesk-android-&expanded=true) | APK и SHA256SUMS.txt; тестовые prerelease с отладочной подписью |
| iPhone / iPad | [Веб-консоль](https://desk.funti.cc/connect/) | Отдельное приложение не опубликовано |
| Linux x64 | [Только Linux](https://github.com/michailr1/FuntiDesk/releases?q=funtidesk-linux-&expanded=true) | DEB и SHA256SUMS.txt; тестовые prerelease, не latest; публикует `linux-build.yml` при запуске на `main` (ADR-016) |
| macOS | [Веб-консоль](https://desk.funti.cc/connect/) | Готовый клиентский дистрибутив не опубликован |
| Сервер Linux x64 | [Только сервер](https://github.com/michailr1/FuntiDesk/releases?q=funtidesk-server-&expanded=true) | hbbs/hbbr; технические prerelease, не клиентский дистрибутив |

## Порядок

GitHub хранит Releases репозитория в общей ленте; отдельные страницы по ОС открываются фильтрами выше. Для каждой ОС сохраняется собственный выпуск, исходный тег и набор файлов. Перенос бинарных файлов между тегами или повторная упаковка для оформления не нужны.

Названия, применяемые также в существующих workflow:

- `Windows x64 — FuntiDesk <версия>`; если историческое описание не содержит версии, вместо неё остаётся короткий commit.
- `Android arm64 — FuntiDesk (тестовая сборка <commit>)`.
- `Linux x64 — FuntiDesk <версия>`.
- `Сервер Linux x64 — FuntiDesk <commit>`.
- `Служебное — журнал сборки Android` — диагностика CI, не приложение.

При упорядочивании опубликованных выпусков меняется только title через `gh release edit <tag> --title '<название>'`. Сначала сохранить текущие метаданные (`gh api --paginate repos/michailr1/FuntiDesk/releases`); после сверить прежние теги, наборы и ID файлов, target commit, draft/prerelease и latest. Откат оформления — вернуть title из сохранённых метаданных. Описания, файлы, теги, SHA-256, latest и настройки публикации при этом не меняются.

`install.ps1` и обновление Windows используют общий `releases/latest/download`. Android, Linux и сервер не занимают latest; для них остаются prerelease и отдельные теги. Сайт ссылается на Windows latest и конкретный принятый Android-тег. Изменение этой схемы потребует отдельной работы над обновлениями, а не переименования релизов.

Новые сборки и публикации выполняются по существующему процессу релиза ведущим разработчиком. Эта работа меняет оформление и навигацию, не запускает релиз.
