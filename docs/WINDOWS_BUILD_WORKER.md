# Windows build worker для FuntiDesk

Статус: постоянный процесс разработки Windows-клиента.

## Зачем нужен отдельный build worker

GitHub Actions R21 остаётся эталонной проверкой воспроизводимости на чистом `windows-2022` runner. Для повседневной разработки это слишком дорого по времени: runner каждый раз поднимает toolchain и зависимости заново.

Постоянный Windows build worker на машине владельца используется для быстрых итерационных сборок и runtime smoke-check. Он **не заменяет** R21 и не является источником production/release-артефактов.

## Разделение ответственности

### Ведущий разработчик (Claude) / инженерный контур

Ведущий разработчик определяет архитектуру изменений, правит исходники/скрипты/документацию в GitHub, анализирует CI и решает, какой уровень проверки нужен.

Windows-агент не должен самостоятельно принимать архитектурные решения и не используется для задач, которые можно безопасно выполнить напрямую через GitHub.

### Windows build worker

Windows-агент используется только там, где нужен реальный Windows toolchain/runtime:

- incremental Windows build;
- локальный clean build;
- запуск собранного `FuntiDesk.exe`;
- проверка Windows metadata, AppData, registry/service/task/IPC поведения;
- smoke/E2E проверки на реальной Windows;
- сбор логов и SHA256 артефактов.

Он не должен без отдельного разрешения:

- менять production;
- деплоить на `desk.funti.cc`;
- менять server key/endpoints;
- merge'ить в `main`;
- переписывать архитектуру или делать массовый rename по собственной инициативе.

## Три уровня сборки

### 1. Incremental worker build

Назначение: быстрый цикл разработки после небольших изменений.

Использует уже установленный и прогретый toolchain/cache на Windows worker. Не удаляет Cargo/vcpkg/Flutter caches.

Результат предназначен для локального smoke-test и ручной проверки, но не считается воспроизводимым release artifact.

### 2. Local clean worker build

Назначение: контроль перед важным push/PR либо после изменений build/toolchain/FFI/Windows identity.

Очищаются только build outputs текущего проекта; глобальные toolchain caches сохраняются. Сборка выполняется через закреплённый FuntiDesk build process.

Результат подтверждает, что проект собирается на реальной Windows-машине владельца, но всё ещё не заменяет чистый GitHub runner.

### 3. GitHub R21 clean build

Назначение: обязательная проверка воспроизводимости.

Workflow: `.github/workflows/r21-windows-clean-build.yml`.

R21 запускается на чистом `windows-2022` runner, использует pinned dependencies и публикует полный runtime с `SHA256SUMS.txt`.

R21 обязателен:

- перед merge существенных Windows/runtime изменений;
- перед release;
- после изменений build scripts/toolchain/dependency pins;
- после изменений FFI/bridge, Windows packaging/identity, installer/service integration;
- если локальная сборка и CI расходятся.

## Source of truth

Зафиксированный baseline toolchain и контрольная последовательность находятся в:

- `scripts/windows/bootstrap.ps1`;
- `scripts/windows/build-baseline.ps1`;
- `scripts/windows/doctor.ps1`;
- `.github/workflows/r21-windows-clean-build.yml`;
- `docs/WINDOWS_BASELINE_BUILD.md`.

Build worker обязан использовать тот же pinned toolchain. Локальная оптимизация допускает пропуск повторной установки уже проверенных инструментов и повторной загрузки неизменяемых dependency assets, но не замену версий.

## Постоянные каталоги worker

Рекомендуемый layout на Windows worker:

```text
C:\funtidesk-build\
  repo\                 # рабочий checkout/worktree
  artifacts\            # локальные runtime snapshots
  logs\                 # build/runtime logs
```

Проектные toolchain caches могут оставаться в существующем `<repo>\.tools`, `%USERPROFILE%\.cargo`, vcpkg/Flutter cache. Они не являются частью артефакта и не коммитятся.

Не следует размещать production secrets в build tree или build logs.

## Именование артефактов

Пользовательский executable должен называться:

```text
FuntiDesk.exe
```

Локальный snapshot рекомендуется сохранять как:

```text
funtidesk-windows-x64-<git-sha>\
```

В snapshot должны быть:

- полный runtime directory;
- `SHA256SUMS.txt`;
- build log;
- текстовый provenance-файл с git SHA, branch, timestamp и режимом (`incremental`/`clean`).

GitHub R21 использует artifact name:

```text
funtidesk-windows-x64-<github.sha>
```

## Правило чистоты исходников

До и после build worker должен фиксировать:

```powershell
git status --short
git rev-parse HEAD
```

Сборка не должна оставлять изменения tracked source files. Временные изменения `pubspec.yaml`, generated bridge и прочие build-time patches должны быть восстановлены скриптами.

Если после сборки `git status --short` показывает неожиданные tracked изменения, результат считается FAIL до разбора причины.

## Проверки после локальной сборки

Минимальный worker acceptance:

1. Build завершился с exit code 0.
2. `FuntiDesk.exe` существует в ожидаемом `Release` runtime.
3. SHA256 executable и runtime manifest рассчитаны.
4. tracked source tree не изменён сборкой.
5. executable запускается и остаётся жив достаточно для smoke-check.
6. для identity-refactor: Windows не показывает `RustDesk` в product/file metadata.
7. после Phase 2 identity-refactor дополнительно проверяются FuntiDesk AppData/log/config и IPC/service namespaces.

## Когда нужен полный runtime/E2E тест

Полный runtime-тест требуется после изменений в:

- `APP_NAME`/filesystem namespace;
- IPC/named pipes;
- service/installer/registry/task integration;
- trust/security handshake;
- network transport/P2P/relay;
- privilege/UAC/service boundary;
- file transfer/clipboard/control path.

Обычные docs-only или независимые UI layout изменения не требуют запуска Windows-агента, если CI/static validation достаточно.

## Merge/release gate

Успешная worker build не даёт разрешения на merge/deploy.

Для существенного Windows изменения перед merge должны быть одновременно понятны:

- локальная worker проверка — PASS либо документированное ограничение;
- GitHub policy/security CI — PASS;
- R21 clean build — PASS;
- необходимый runtime acceptance — PASS/owner-accepted limitation.

Production/deployment остаются отдельным явным действием владельца.
