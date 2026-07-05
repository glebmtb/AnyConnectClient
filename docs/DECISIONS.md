# Архитектурные решения

## ADR-0001: первый рабочий режим через OpenConnect CLI + ocproxy

Дата: 2026-07-04.

Статус: принято для MVP.

Решение:

Первый рабочий клиент строим как macOS app, которая запускает `openconnect` с `--script-tun` и `ocproxy`, поднимая локальный SOCKS5 proxy.

Причины:

- быстрее всего получить usable VPN для ежедневной работы
- не нужен root и ручная настройка TUN/routes/DNS
- ocproxy официально рассчитан на запуск через `openconnect --script-tun`
- можно тестировать вертикально: process, logs, status, SOCKS, disconnect

Последствия:

- первый MVP не является system-wide VPN
- приложения настраиваются на SOCKS5 вручную
- `NEPacketTunnelProvider`, PAC и system proxy не входят в текущий scope

Изменение от 2026-07-04:

Пользователь уточнил, что system-wide VPN и system proxy не нужны. Целевой продукт - только SOCKS5-клиент.

## ADR-0002: секреты не попадают в argv, git и diagnostics

Дата: 2026-07-04.

Статус: принято.

Решение:

Пароль передается в OpenConnect через stdin. Локальные profile/credentials файлы игнорируются git. Любые logs и diagnostics проходят через redaction.

Причины:

- аргументы процесса видны через process list
- реальные credentials нельзя сохранять в документах и тестах
- VPN cookie и token values должны считаться секретами

Последствия:

- нужен отдельный `Redactor`
- нужен `KeychainCredentialStore`
- command builder должен иметь тесты, что secrets не попадают в argv

## ADR-0003: multi-profile model с отдельным SOCKS-портом на профиль

Дата: 2026-07-04.

Статус: принято.

Решение:

Клиент поддерживает несколько профилей. Каждый профиль имеет свой `authgroup` и свой локальный SOCKS5 endpoint, обычно `127.0.0.1:<port>`.

Причины:

- пользователь хочет поднимать несколько профилей
- приложения могут быть настроены на разные SOCKS-порты
- lifecycle проще держать изолированным по профилю

Последствия:

- нужен уникальный port validation
- состояние подключения хранится на профиль
- история событий хранится на профиль

## ADR-0004: tray-first UX

Дата: 2026-07-04.

Статус: принято.

Решение:

Приложение живет в macOS menu bar/tray. Главные действия: start, stop, reconnect, settings, connection history.

Состояния иконки:

- gray: stopped
- pulsing: connecting/reconnecting
- green: connected
- red: failed/degraded

Последствия:

- UI должен быть компактным
- состояние всех профилей агрегируется в один tray status
- нужна история подключений и разрывов

## ADR-0005: app settings + Touch ID Vault вместо dotenv runtime

Дата: 2026-07-05.

Статус: принято.

Решение:

Ignored legacy profile больше не является runtime-источником конфигурации. Он используется только для явного одноразового legacy-import, если путь передан tool-у извне.

Runtime-настройки без секретов хранятся в:

```text
~/Library/Application Support/AnyConnectClient/profile-settings.json
```

Секреты хранятся в Touch ID credential vault:

- Keychain service `AnyConnectClient`, account `credential-vault-key`: один случайный AES-GCM ключ, защищенный Touch ID.
- `~/Library/Application Support/AnyConnectClient/credential-vault.json`: зашифрованный vault-документ с password/servercert pin по профилям.
- Legacy Keychain items `<profileID>.password` и `<profileID>.servercert` читаются только для ленивой миграции в vault и удаляются после успешной записи.
- Если SwiftPM/dev-build получает Keychain `-34018` при создании biometry-bound key, используется fallback account `credential-vault-key.application-gated`: ключ хранится обычным Keychain item, а Touch ID проверяется приложением перед чтением после restart.
- Per-profile можно явно выбрать `Store without Touch ID (unsafe)`. Тогда password/servercert pin пишутся в `unsafe-credential-vault.json`, зашифрованный app-key. Это не strong security и включается только после warning-confirmation.

Причины:

- пользователь хочет удалить env-файл
- пароль и servercert pin нельзя хранить в файловом профиле в открытом виде
- per-profile Keychain items слишком часто вызывают macOS prompts в dev-build workflow
- текущий SwiftPM/dev-build может не иметь entitlement/signing identity для strict biometry-bound Keychain item
- пользователю нужен аварийный режим без Touch ID prompts, но он должен быть явно рискованным
- settings UI должен менять server, login и port без возврата к dotenv

Последствия:

- app должна запускаться без legacy profile после миграции
- smoke script читает settings JSON и vault
- изменение пароля идет только через vault
- первый connect/test/routes/show может попросить Touch ID, чтобы разблокировать vault на app-сессию
- auto connect/reconnect после unlock не требует Touch ID, иначе восстановление после sleep/network drop станет интерактивным
- если пользователь включает unsafe mode и отменяет Touch ID при миграции старого пароля, UI предлагает ввести пароль заново
- storage mode показывается только в profile settings, не в tray menu
- command-line status не должен читать secret bytes; для locked vault показывать `locked`

## 2026-07-05: Servercert pin auto-trust

Статус: принято.

Решение:

Для этого локального macOS-клиента принимаем `pin-sha256`, который OpenConnect сам печатает при первом connect или ротации сертификата. Значение pin извлекается из raw process output как structured secret до redaction, сохраняется в vault и не выводится в menu/logs/docs. После сохранения выполняется один automatic retry.

Причины:

- пользователь не хочет вручную видеть/копировать servercert pin
- новые профили должны подключаться без интерактивного `yes/no` от OpenConnect
- VPN-сторона может ротировать сертификат и прислать новый pin

Последствия:

- UI показывает только факт `Server pin saved; retrying`
- `AnyConnectCredentialTool smoke` может сохранить missing servercert pin и повторить connect
- если retry не удался, профиль остается failed, pin value все равно не печатается
