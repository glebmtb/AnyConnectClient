# AGENTS.md

Правила для работы над macOS VPN-клиентом на Swift 6.3.3.

## Главная цель

Собрать полностью рабочий macOS tray-клиент для OpenConnect AnyConnect, который надежно подключается в SOCKS5-режиме через `openconnect --script-tun` и `ocproxy`.

## Карта проекта

- `docs/ARCHITECTURE.md` - текущая архитектура, решения и границы модулей.
- `docs/TASK_PLAN.md` - порядок задач, acceptance criteria и вопросы к пользователю.
- `ThirdParty/openconnect-9.21/` - исходники OpenConnect 9.21. Считать vendor-кодом.
- `ThirdParty/ocproxy/` - исходники ocproxy 1.70. Считать vendor-кодом.
- `.vpn_access_profile`, `.vpn-access-credentials` - legacy-файлы с локальными секретами. Использовать только для одноразового импорта, не печатать, не коммитить.
- `~/Library/Application Support/AnyConnectClient/profile-settings.json` - runtime-настройки профиля без секретов: server, username, authgroup, SOCKS endpoint.
- `~/Library/Application Support/AnyConnectClient/credential-vault.json` - encrypted vault-файл с секретами; содержимое не читать и не печатать без явной необходимости.

## Секреты и безопасность

- Никогда не выводить в ответ, логи, diff или тестовые fixtures реальные пароли, токены, cookie, OTP, client keys, server profile values.
- Если нужно проверить профиль, показывать только имена полей и redacted-значения.
- Пароль передавать в OpenConnect через stdin (`--passwd-on-stdin`), а не через аргументы процесса.
- Cookie, token secret и servercert считать секретами. Логировать только redacted-форму.
- Servercert pin может ротироваться на стороне VPN. При mismatch не подключаться молча, распознавать отдельное состояние `serverCertificateChanged`, новый pin не печатать и обновлять доверенный pin только отдельным подтвержденным действием пользователя.
- Все сохраненные credentials должны идти в Touch ID credential vault: один vault key в Keychain, сами password/servercert pin в encrypted vault-файле.
- Для SwiftPM/dev-build возможен Keychain `-34018` при создании biometry-bound item. В этом случае допустим fallback: vault key хранится обычным app Keychain item, но чтение после restart gated через явный Touch ID prompt на уровне приложения.
- Допустим per-profile unsafe режим только по явной галочке `Store without Touch ID (unsafe)` и после warning-confirmation прямо при включении галочки. Не показывать этот статус в tray menu. В профиле можно показывать/менять.
- Unsafe local storage не считать strong security: файл шифруется app-key только против случайного просмотра; человек с доступом к app+user data потенциально может использовать credentials.
- Старые per-profile Keychain items считать legacy; читать только для миграции в vault и удалять после успешной записи.
- `.vpn_access_profile` не использовать как runtime-источник после миграции; приложение должно работать, если пользователь удалил этот файл.
- Файловые runtime-настройки могут хранить только несекретные поля: server, username, authgroup, SOCKS host/port, display name.
- Touch ID использовать для первого unlock vault в app-сессии. После unlock connect/reconnect/test/routes/show должны переиспользовать in-memory vault cache без повторных prompts.
- CLI/status-команды не должны читать secret bytes из vault или unsafe local storage. Явные smoke/diagnose-команды могут интерактивно unlock vault, но не должны печатать секреты.

## Архитектурные правила

- Двигаться маленькими вертикальными срезами: сначала CLI smoke, затем Swift process runner, затем UI, затем packaging.
- Не начинать Network Extension, system-wide VPN, PAC или system proxy без нового явного решения пользователя.
- Каждый VPN-профиль имеет свой локальный SOCKS5 endpoint; не запускать два профиля на одном порту.
- Core-модули должны быть UI-free: модели, state machine, command builder, log parser и credential abstractions не импортируют SwiftUI/AppKit.
- UI работает через `@MainActor` view models и не управляет процессами напрямую.
- Runtime-слой изолирует `openconnect`, `ocproxy`, paths, env, stdin/stdout/stderr и lifecycle.
- Settings-слой изолирует app settings и credential vault; UI не читает dotenv/env напрямую.
- Каждый внешний процесс получает один владелец lifecycle. Не размазывать `Process` по UI.
- Все команды строить через типизированный `OpenConnectCommandBuilder`; не собирать shell-string в UI.
- Не использовать shell, если можно вызвать executable с массивом arguments.
- `ThirdParty` не менять напрямую без отдельного решения. Если нужен patch, описать причину в `docs/ARCHITECTURE.md` и держать patch отдельно.

## Swift-стиль

- Swift 6.3.3, strict concurrency where practical.
- Предпочитать `async/await`, `AsyncStream`, `actor` для lifecycle и логов.
- Ошибки оформлять типами (`enum VPNConnectionError: Error`) с user-facing message отдельно от technical details.
- Инъекции зависимостей через initializer, протоколы только там, где есть реальная граница: credentials, process runner, runtime paths, proxy controller.
- Не добавлять глобальное mutable state, кроме явно централизованной конфигурации runtime paths.
- Unit-тесты обязательны для command builder, parser, state machine и redaction.

## Контекстная экономия

- Перед изменениями читать только нужные файлы, искать через `rg`.
- Для архитектурных вопросов сначала открыть `docs/ARCHITECTURE.md` и `docs/TASK_PLAN.md`.
- Не перечитывать весь `ThirdParty`; использовать targeted search по `openconnect.h`, `README.md`, `config.log`, `tun.c`, `main.c`, `ocproxy.c`.
- После существенного решения обновлять docs коротко: что решили, почему, какой следующий шаг.
- Ответы пользователю держать короткими, а подробности класть в docs.

## Проверка

- Минимальная проверка для Swift-кода: `swift test`.
- Для app-срезов: `swift build` или Xcode build target, затем smoke connect на локальном профиле.
- Для VPN-runtime: проверять, что `openconnect` стартует, `ocproxy` слушает локальный порт, disconnect убивает оба процесса, секреты не попали в logs.
- Для packaging: проверять `otool -L` у bundled binaries; переносимость за пределы текущего Mac не является целью без отдельного решения.
