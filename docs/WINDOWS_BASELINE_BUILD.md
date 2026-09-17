# Windows baseline build

Статус: MIK-19 — выполнено.

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

## Фактическая приёмка

Успешная контрольная сборка выполнена на Windows-машине владельца без изменений production source.

Зафиксированная среда:

- Windows: `Windows 11 Pro`, build `22631`, x64;
- MSVC: `14.44.35207`;
- Windows SDK: `10.0.22621.0`;
- Rust: `1.75.0`;
- Flutter bridge: `3.22.3`;
- Flutter build: `3.24.5`;
- `flutter_rust_bridge_codegen`: `1.80.1`;
- LLVM: `15.0.6`;
- vcpkg: `120deac3062162151622ca4860575a33844ba10b`;
- Python: `3.11.15`.

Результат:

- executable: `client/flutter/build/windows/x64/runner/Release/rustdesk.exe`;
- SHA256: `B341C0536496662ADFF3D73F2BCE7DA18AB5F77C06D94DEA63B52AF655DD16C2`;
- file/product version: `1.4.9+67`;
- Flutter UI успешно открылся;
- процесс оставался жив не менее 20 секунд;
- Sciter для x64 Flutter build не потребовался;
- production source не изменялся.

Перед runtime-проверкой ранее установленный экземпляр исходного клиента был закрыт, чтобы исключить single-instance forwarding и гарантировать запуск именно собранного бинарника.

Build log локально сохранялся в `artifacts/logs/baseline-build.log`; бинарник и локальные toolchain-каталоги в git не коммитятся.

## Артефакты приёмки

Успешная сборка должна вывести:

```text
BASELINE_BUILD_OK=true
ARTIFACT=...
SHA256=...
LOG=...
```

## Что на этом этапе запрещено

До прохождения MIK-19 не менялись:

- rendezvous/relay endpoints;
- server public key;
- `custom-client` trust path;
- branding;
- Flutter UI;
- Rust core;
- протокол.

Этап завершён: дальнейшие FuntiDesk security/product patches теперь можно отличать от проблем baseline/toolchain.

## Sciter

Для целевой x64 Windows Flutter-сборки Sciter не потребовался. Legacy Sciter-код остаётся в импортированном исходном дереве и может быть рассмотрен на отдельном этапе очистки после появления стабильной FuntiDesk-сборки.