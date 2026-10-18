# Браузерный клиент FuntiDesk

Собственный интерфейс и транспорт для текущих открытых protobuf-описаний в `client/`: WebCodecs VP9 → Windows, удалённый экран, мышь и клавиатура. По [ADR-014](../docs/ADR-014-phone-web-console.md), #65 подготовлен интерфейс сеанса для телефона; приёмка в Safari на iPhone и с экрана «Домой» ещё впереди. Веб-клиент не наследует семейное доверие из кабинета; временный или постоянный пароль проверяет принимающий FuntiDesk. Требуется клиент с обменом ключами v1; незашифрованного пути нет.

## Воспроизводимая сборка

Node 22 или новее:

```sh
npm ci --prefix web-client --ignore-scripts
npm --prefix web-client run build
npm --prefix web-client test
python3 scripts/web/package.py --write-manifest
python3 scripts/web/package.py --output /tmp/funtidesk-web.tar
```

`build.mjs` генерирует статические protobuf-кодеки из исходных `.proto`, затем собирает `web/connect/session.js` и уведомления о лицензиях. В браузере не используются генерация кода через `eval`, CDN или динамическая загрузка зависимостей. `wasm-unsafe-eval` нужен криптографической библиотеке, а `unsafe-eval` для JavaScript не разрешён. Сгенерированные публичные файлы включены в Git и проверяются повторной сборкой; промежуточные исходники и `node_modules` игнорируются.

Описания протокола — AGPL-3.0, исходные уведомления RustDesk/Purslane сохранены в `client/`. Криптографические и protobuf-зависимости закреплены в `package-lock.json`, их полные лицензии поставляются в `web/connect/licenses.html`. Исторический webclient-v1 изучен как справочный код; его небезопасный транспорт и UI не импортированы.

## Развёртывание и приёмка

Техническое решение: [ADR-012](../docs/ADR-012-account-sync-and-browser.md). Отдельный WSS-фрагмент — `infra/funtidesk-account/Caddyfile.web-client.fragment`, дополнительная сеть Caddy — `caddy-web-client.override.yaml`. Для живой приёмки подготовлен отдельный `scripts/account/update-browser-desk.py`: он сохраняет текущие API и страницы кабинета, проверяет оба manifest, изменяет только desk-блок и добавляет только сеть серверов. При неуспешной готовности возвращает прежние Caddyfile, webroot и сети. При последующих recreate сохранять оба overlay из закрытого integration-каталога и остальные сайты. Это кандидат для проверки Windows, а не принятый релиз.

Проверки криптографии сопоставляют побайтовые контрольные значения текущего нативного Rust-клиента: подписи обеих идентичностей, ID, запечатанный ключ, отдельные ключи направлений и парольный challenge. Протокольный тест с синтетическим компьютером не заменяет реальную Windows-приёмку: временный пароль, постоянный пароль, отказ пароля/ключа, запрет ввода, отзыв подтверждения, обрыв сети и существующие native-native подключения.

На телефоне (`pointer: coarse`) после входа остаются экран и перетаскиваемое меню: тачпад/касание, масштаб, системная клавиатура и спецклавиши, монитор, качество, подтверждение Ctrl+Alt+Del, завершение. Wake Lock запрашивается только во время сеанса; отказ не обрывает подключение. Подсказка — собственный слой с кнопкой «Понятно»: один раз за открытие страницы и из меню, без записи в хранилище браузера. `/connect/app.webmanifest` открывает страницу в `standalone`, без service worker и кеширования паролей/сеансов. Для manifest нужен согласованный `manifest-src 'self'` в существующем desk-блоке Caddy; порядок — в [ACCOUNT_DEPLOYMENT.md](../docs/ACCOUNT_DEPLOYMENT.md).

Значок iOS `/connect/apple-touch-icon.png` (180×180, `apple-touch-icon`) растеризован из `design/brand/funtidesk-mark.svg` существующим Skia-renderer Android. Повторный экспорт из корня в окружении с `skia-python` и `numpy`:

```python
import numpy as np
import skia
from scripts.brand.export_android_icons import render
image = skia.Image.fromarray(np.ascontiguousarray(render(180, 180)),
    colorType=skia.kRGBA_8888_ColorType, alphaType=skia.kUnpremul_AlphaType)
image.save('web/connect/apple-touch-icon.png', skia.kPNG)
```

Пока не включены: семейный вход из браузера, файлы, звук, буфер обмена, камера и автоматическая запись браузерных сеансов в историю аккаунта. Некоторые сочетания перехватывает браузер. Chromium с эмуляцией касаний проверяет транспорт, жесты, клавиши, поворот и режим просмотра; он не заменяет реальный iPhone, диктовку и клавиатуру Safari.
