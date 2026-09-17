# Windows baseline build

Статус: MIK-19.

Цель этапа — получить рабочую Windows x64-сборку **неизменённого импортированного baseline** до любых FuntiDesk security/branding-патчей. Это позволяет отделить проблемы toolchain от наших изменений.

## Зафиксированная upstream-конфигурация

Для x86_64 Windows upstream CI baseline 1.4.9 использует:

- Rust `1.75`;
- Flutter для генерации bridge: `3.22.3`;
- Flutter для Windows build: `3.24.5`;
- `flutter_rust_bridge_codegen` `1.80.1`;
- `cargo-expand` `1.0.95`;
- LLVM/Clang `15.0.6`;
- vcpkg commit `120deac3062162151622ca4860575a33844ba10b`;
- vcpkg triplet `x64-windows-static`;
- build args: `--portable --flutter --skip-portable-pack --hwcodec --vram`.

Flutter 3.24.5 получает upstream patch `flutter_3.24.4_dropdown_menu_enableFilter.diff` и custom Windows x64 engine так же, как upstream CI.

## Почему полная Visual Studio не нужна

Для сборки необходим MSVC toolchain и Windows SDK, но IDE не требуется. `bootstrap.ps1` устанавливает Visual Studio 2022 **Build Tools** с workload C++.

## Порядок запуска на чистом Windows x64

Открыть PowerShell от имени администратора только для первичной установки инструментов.

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd <путь-к-FuntiDesk>
.\scripts\windows\doctor.ps1
.\scripts\windows\bootstrap.ps1
```

После bootstrap закрыть PowerShell и открыть новый обычный PowerShell, затем:

```powershell
cd <путь-к-FuntiDesk>
.\scripts\windows\doctor.ps1
.\scripts\windows\build-baseline.ps1
```

## Артефакты приёмки

Успешная сборка должна вывести:

```text
BASELINE_BUILD_OK=true
ARTIFACT=...
SHA256=...
LOG=...
```

Build log сохраняется в локальном `build-logs/`. В репозиторий бинарники и локальные toolchain-каталоги не коммитятся.

## Что на этом этапе запрещено

До прохождения MIK-19 не меняются:

- rendezvous/relay endpoints;
- server public key;
- `custom-client` trust path;
- branding;
- Flutter UI;
- Rust core;
- протокол.

Любая ошибка должна сначала трактоваться как проблема воспроизводимости baseline/toolchain, а не исправляться продуктовым патчем.

## Sciter

Для целевой x64 Windows Flutter-сборки upstream использует Flutter job. Sciter остаётся в импортированном исходном дереве, но удалять его в MIK-19 нельзя: сначала подтверждаем baseline. Решение об удалении legacy UI принимается отдельным изменением после успешной сборки.
