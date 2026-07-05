# План работ

Цель: получить полностью рабочий macOS VPN-клиент на Swift 6.3.3, которым можно пользоваться спокойно каждый день.

## Принцип движения

Каждая задача должна давать маленький проверяемый результат. После каждой задачи фиксируем:

- что работает
- как проверить
- что осталось рискованным
- какой следующий шаг

## Вопросы к пользователю

Ответы пользователя от 2026-07-04:

1. Протокол: `anyconnect`.
2. Scope: только SOCKS5-клиент, без system-wide VPN.
3. 2FA/OTP/SSO/external browser: нет.
4. `authgroup`: да, нужно несколько профилей; у каждого профиля свой SOCKS-порт.
5. Servercert pin: генерируется/фиксируется при первом соединении, пользователю не показывать.
   Pin может ротироваться на стороне VPN; mismatch должен стать отдельным состоянием `serverCertificateChanged`, новый pin не показывать и доверять ему только после explicit-подтверждения.
6. Платформа: только текущий Mac arm64.
7. Positive smoke: внутренние URLs задаются только локально пользователем/тестовым окружением.
8. Negative smoke: внешний контрольный URL задается только локально пользователем/тестовым окружением и через SOCKS должен быть недоступен.
9. System proxy: не включать.

Дополнительные требования:

- приложение в tray/menu bar
- start/stop/reconnect по профилям
- автоподъем после wake
- reconnect при временной потере интернета
- история подключений и разрывов
- tray icon: gray stopped, pulsing connecting, green connected, red failed
- certificate pin rotation workflow: detect mismatch, stop safely, offer explicit trust/update action

## Этап 0. Гигиена репозитория

Acceptance:

- есть `.gitignore` для секретов и build-мусора
- есть `AGENTS.md`
- есть `docs/ARCHITECTURE.md`
- есть `docs/TASK_PLAN.md`

Статус: готово.

## Release audit 1.0.0

Статус 2026-07-05:

- release `.app` содержит app executable, bundled `openconnect`, bundled `ocproxy` и нужные dylibs
- release `.app` содержит `AppIcon.icns` и plist keys `CFBundleIconFile`/`CFBundleIconName`; иконка видна у bundle-процесса при запуске через `.app`
- Mach-O `LC_LOAD_DYLIB`/`LC_RPATH` не содержит Homebrew, Xcode, user или temp путей
- source/docs/app bundle не содержат известных внутренних smoke URL/domain/IP/login markers
- zip распакован в temp directory и прошел `codesign --verify --deep --strict`
- bundle version: `1.0.0`, build: `1`
- подпись ad-hoc; `spctl` отклоняет app без Developer ID/notarization, поэтому для бесшовной установки другими пользователями нужен отдельный Developer ID release pipeline
- vendor-бинарники могут содержать compile-time optional config/locale path strings, но это не dynamic dependency load path и не должно требовать Homebrew для запуска

## Этап 1. CLI smoke без Swift

Цель: доказать, что текущие `openconnect` и `ocproxy` реально подключаются.

Задачи:

1. Сделать redacted parser для ignored legacy profile.
2. Составить команду `openconnect --protocol=anyconnect --script-tun --script "<ocproxy ...>"`.
3. Подключиться вручную через локальный SOCKS.
4. Проверить positive URLs через `curl --socks5-hostname`.
5. Проверить, что negative URL через SOCKS недоступен.
6. Зафиксировать рабочие флаги в `docs/ARCHITECTURE.md`.

Acceptance:

- `ocproxy` слушает `127.0.0.1:<port>`
- внутренний test URL доступен через SOCKS
- disconnect корректно завершает `openconnect` и `ocproxy`
- секреты не попали в терминальный вывод и docs

Текущий статус 2026-07-05:

- профиль переведен в dotenv
- TLS до VPN-сервера работает
- `servercert` pin найден и используется без вывода значения
- authgroup найден и добавлен
- после исправления username аутентификация работает
- SOCKS поднимается
- positive smoke URLs через SOCKS возвращают HTTP 200
- negative smoke URL через SOCKS недоступен
- после stop SOCKS-порт освобождается
- подробности в `docs/SMOKE_RESULTS.md`

Статус: готово.

Команда для пользователя:

```text
Задание 1: проверь CLI smoke по профилю, не выводя секреты.
```

## Этап 2. Swift package skeleton

Цель: создать поддерживаемую основу проекта.

Задачи:

1. Создать `Package.swift`.
2. Создать `VPNCore`.
3. Создать `OpenConnectRuntime`.
4. Создать первые unit-тесты.

Acceptance:

- `swift test` проходит
- есть typed models: `VPNProfile`, `VPNCredentials`, `ConnectionState`, `SocksEndpoint`, `ConnectionHistoryEvent`
- есть `OpenConnectCommandBuilderTests`
- command builder не кладет password/token в argv
- multi-profile model валидирует уникальность SOCKS-порта

Текущий статус 2026-07-05:

- создан `Package.swift`
- создан модуль `VPNCore`
- создан модуль `OpenConnectRuntime`
- `OpenConnectCommandBuilder` строит форму команды, подтвержденную CLI smoke
- пароль не передается в builder и не попадает в argv
- `servercert` pin редактируется в user-facing command description
- `VPNProfileCatalog` запрещает два профиля на одном SOCKS endpoint
- `swift test` проходит: 8 tests, 0 failures

Статус: готово.

Команда для пользователя:

```text
Задание 2: создай Swift package skeleton и command builder.
```

## Этап 3. Process runner

Цель: управлять `openconnect` из Swift.

Задачи:

1. Реализовать actor/service для запуска процесса.
2. Передавать password через stdin.
3. Читать stdout/stderr как stream.
4. Реализовать cancel/disconnect.
5. Парсить базовые состояния: connecting, authenticating, connected, reconnecting, disconnected, failed.

Acceptance:

- runtime запускает `openconnect --help` в тестовом режиме
- smoke command строится и запускается без shell
- disconnect завершает процесс
- logs проходят через redactor

Текущий статус 2026-07-05:

- создан `OpenConnectProcess` actor как единый владелец lifecycle внешнего процесса
- `Process` запускается без shell: executable path + arguments
- stdin поддержан отдельным параметром, подходит для `--passwd-on-stdin`
- stdout/stderr идут как `AsyncStream<OpenConnectProcessEvent>`
- logs проходят через `Redactor` перед выдачей наружу
- `OpenConnectLogParser` мапит базовые строки OpenConnect в `ConnectionState`
- `stop()` завершает процесс через terminate, затем SIGKILL после grace period
- тестово запускается реальный `openconnect --help`
- `swift test` проходит: 12 tests, 0 failures

Статус: готово.

Команда для пользователя:

```text
Задание 3: реализуй Swift process runner для OpenConnect.
```

## Этап 4. ocproxy lifecycle

Цель: приложение поднимает локальный SOCKS вместе с VPN для каждого профиля.

Задачи:

1. Хранить SOCKS-порт в профиле.
2. Собрать `--script` для ocproxy.
3. Проверять, что SOCKS порт слушает.
4. Добавить health check.
5. Не разрешать запуск двух профилей на одном порту.

Acceptance:

- connect поднимает SOCKS
- health check видит порт
- disconnect освобождает порт

Текущий статус 2026-07-05:

- `SocksEndpoint` уже хранится в профиле
- `OcproxyCommandBuilder` собирает `--script` для `openconnect --script-tun`
- создан `SocksHealthCheck`, проверяет endpoint реальным TCP connect без shell/lsof
- создан `ActiveSocksEndpointRegistry`, не дает зарезервировать один SOCKS endpoint дважды
- создан `OpenConnectSession`, связывает command builder, process runner, credentials stdin и ожидание SOCKS readiness
- session отказывает в старте, если SOCKS endpoint уже слушает
- session освобождает endpoint при stop/exit
- `swift test` проходит: 16 tests, 0 failures

Статус: готово.

Команда для пользователя:

```text
Задание 4: добавь ocproxy lifecycle и health check.
```

## Этап 5. Menu bar app

Цель: рабочий минимальный UI.

Задачи:

1. Создать macOS app target.
2. Добавить menu bar status item.
3. Connect/disconnect/reconnect по профилю.
4. Показывать состояние и последние redacted logs.
5. Добавить settings для server, protocol, username, authgroup, port.
6. Добавить состояния tray icon: gray, pulsing, green, red.

Acceptance:

- пользователь может подключиться из UI
- видно состояние
- можно отключиться
- ошибки понятны

Текущий статус 2026-07-05:

- создан executable product `AnyConnectClientApp`
- приложение запускается как macOS accessory/menu bar app
- tray/menu показывает профиль, SOCKS endpoint, состояние и последние redacted события
- есть действия `Connect`, `Disconnect`, `Reconnect`, `Quit`
- состояние иконки:
  - gray: stopped
  - pulsing gray/green: connecting/authenticating/reconnecting
  - green: connected
  - red: failed
- UI читает локальный dotenv legacy profile
- UI использует `OpenConnectSession`, `OpenConnectProcess`, `SocksHealthCheck`
- пароль передается только через stdin внутри session
- servercert pin больше не хранится в runtime settings; он перенесен в credential vault
- ошибки runtime теперь показываются user-facing текстом, без Swift enum dump
- servercert mismatch распознается как отдельный сценарий `serverCertificateChanged`
- `ocproxy` запускается через временный wrapper с pidfile, чтобы `stop`/ошибки чистили оба процесса
- `swift build --product AnyConnectClientApp` проходит
- `swift test` проходит: 20 tests, 0 failures
- live smoke после смены порта: OpenConnect connected и SOCKS ready, cleanup закрывает порт
- открытый вопрос live smoke: internal FQDN через SOCKS сейчас падает на DNS resolution, хотя `INTERNAL_IP4_DNS` приходит в `ocproxy`

Статус: dev-run работает; DNS/FQDN smoke исправлен в этапе 5.1.

Команда для пользователя:

```text
Задание 5: сделай menu bar UI для connect/disconnect.
```

## Этап 5.1. DNS через SOCKS

Цель: добиться стабильного открытия внутренних FQDN через SOCKS5.

Задачи:

1. Проверить DNS-поведение `ocproxy` при `INTERNAL_IP4_DNS`.
2. Добавить runtime diagnostics без вывода DNS/IP значений: DNS present/count, domain present/len, curl error class.
3. Если VPN DNS не резолвит FQDN, добавить per-profile host overrides.
4. Smoke: локально заданные positive URLs и negative URL.

Acceptance:

- positive URLs открываются через SOCKS по FQDN или через явно заданные host overrides
- negative URL остается недоступен через этот SOCKS
- disconnect закрывает OpenConnect и `ocproxy`

Текущий статус 2026-07-05:

- причина найдена: `NO_PROXY/no_proxy` исключали внутренний доменный suffix, поэтому `curl` обходил SOCKS
- правильный smoke использует `curl --noproxy "" --socks5-hostname 127.0.0.1:<port> ...`
- добавлен `Scripts/smoke-socks.sh`
- live smoke проходит:
  - `positive[0]=http_200`
  - `positive[1]=http_200`
  - `negative[0]=failed_as_expected`
  - `cleanup=port_closed`

Статус: готово.

Команда для пользователя:

```text
Задание 5.1: почини DNS/FQDN smoke через SOCKS.
```

## Этап 5.2. Server certificate rotation

Цель: обрабатывать первый/новый pin от VPN-сервера без вывода значения пользователю.

Задачи:

1. Детектить отсутствующий/сменившийся `--servercert` как `serverCertificateChanged`.
2. Не показывать новый pin в menu/logs.
3. Забрать `pin-sha256` как structured secret до redaction.
4. Сохранить pin в vault и выполнить один retry.
5. Писать history event без значения pin.

Acceptance:

- при первом connect нового профиля приложение само сохраняет присланный OpenConnect pin
- при ротации сертификата приложение обновляет trusted pin и делает один retry
- старый/новый pin не попадает в logs/docs/diff

## Этап 6. Credentials, Keychain и Touch ID Vault

Цель: убрать секреты из файлового профиля.

Задачи:

1. Реализовать `KeychainCredentialStore`.
2. Импортировать текущий локальный профиль.
3. Хранить пароль/token/cookie только в Touch ID vault.
4. Добавить redacted diagnostics export.

Acceptance:

- секреты не лежат в git
- приложение не печатает секреты
- после restart приложения credentials доступны через Touch ID vault

Текущий статус 2026-07-05:

- добавлен модуль `AnyConnectClientSupport`
- реализован `KeychainCredentialStore` для legacy-записей и `TouchIDVaultCredentialStore` как основной credential store
- основной режим хранения: один Touch ID-защищенный vault key в Keychain + `credential-vault.json` с AES-GCM ciphertext
- если dev-build получает Keychain `-34018` на strict biometry-bound key, включается application-gated fallback: ключ в обычном Keychain item, Touch ID prompt перед чтением после restart
- добавлен per-profile unsafe local storage: `Store without Touch ID (unsafe)` в settings, warning-confirmation прямо при включении галочки, без отображения в tray menu
- если пользователь отменяет Touch ID при переходе Touch ID vault -> unsafe storage, app предлагает ввести VPN password заново
- unsafe credentials лежат отдельно в `unsafe-credential-vault.json`, AES-GCM app-key + `0600`; это intentionally marked unsafe, не strong security
- password/servercert pin всех профилей хранятся в одном vault-документе; после первого Touch ID unlock secrets кэшируются только в памяти app-процесса
- старые per-profile Keychain items лениво мигрируются в vault при первом чтении и удаляются после успешной записи в vault
- runtime-настройки профиля перенесены в `~/Library/Application Support/AnyConnectClient/profile-settings.json`
- ignored legacy profile используется только как explicit legacy-import
- legacy merge с существующим settings JSON удален: если settings JSON есть, legacy profile не читается и не подмешивается
- после успешного импорта legacy secret keys удаляются из legacy profile
- приложение продолжает работать, если legacy profile удален после миграции
- добавлен `AnyConnectCredentialTool` для безопасной миграции/проверки без вывода секретов
- `AnyConnectCredentialTool status` не читает secret bytes; для locked vault показывает `locked`
- `AnyConnectCredentialTool migrate` делает legacy import явно
- `AnyConnectCredentialTool smoke/diagnose` читает vault интерактивно, потому это явные пользовательские команды
- menu bar UI открывает настройки профиля прямым кликом по строке профиля в секции `Profiles`
- password в settings UI сохраняется только в Touch ID vault
- settings UI получил per-profile `Auto-start / On app launch`; при старте приложения такие профили подключаются автоматически после crash-recovery pass, default для старых и новых профилей: off
- просмотр сохраненного password в profile settings идет через vault unlock; если vault уже разблокирован в этой app-сессии, повторного prompt нет
- запуск приложения и открытие settings не читают password/servercert bytes из vault
- `Save` в settings пишет изменения, но не читает секреты обратно из vault
- `Connect`, `Test` и `Routes / Fetch` могут один раз разблокировать vault через Touch ID; повторные connect/reconnect в этой же app-сессии не ходят в Keychain повторно
- `profile-settings.json` поддерживает несколько профилей и `selectedProfileID`
- legacy profile может содержать несколько повторяющихся блоков; новый профиль начинается с очередного `PROFILE_NAME=...`
- если несколько legacy-блоков имеют одинаковый `PROFILE_NAME`, второй получает уникальный profile id по SOCKS port, например `<name>-<port>`
- tray menu получил плоскую секцию `Connections`: первый клик по tray, второй клик сразу `Connect <profile>` или `Disconnect <profile>`
- статус профиля виден прямо в строке действия: profile name, state и SOCKS endpoint
- секция `Profiles` больше не выбирает профиль промежуточно: клик по профилю сразу открывает его settings
- окно settings содержит `Test`: временно поднимает профиль с текущими значениями полей, проверяет авторизацию и готовность SOCKS, затем останавливает тестовую сессию; `Save` для этого не требуется
- окно settings содержит `Routes / Fetch`: показывает route import в отдельном selectable/copyable окне; если профиль уже подключен текущей app-сессией, используются снятые при connect route-переменные, иначе поднимается временная test-сессия и сразу останавливается
- app target не содержит hardcoded smoke-адреса; проверки конкретных URL держать только в CLI/tests/docs
- каждый профиль имеет независимый runtime/session и может быть подключен одновременно с другими профилями
- `selectedProfileID` остается внутренней деталью settings-store, но не показывается как отдельный user-facing режим
- отключение одного профиля не останавливает остальные
- shutdown приложения через Quit, `SIGINT` или `SIGTERM` централизованно останавливает все active sessions и не оставляет `openconnect`/`ocproxy` сиротами; `SIGKILL` не перехватывается ОС
- добавлен гибридный recovery после crash/`kill -9`: app хранит registry без секретов, на старте подхватывает здоровые orphaned `openconnect`/`ocproxy` PID как connected runtime, а stale-записи чистит
- для lifecycle smoke есть debug env `ANYCONNECTCLIENT_AUTOCONNECT_ALL=1`, который поднимает все профили при старте app
- добавлен `Add Profile...`
- удаление профиля находится внутри окна settings конкретного профиля, разрешено даже для последнего профиля, запрещено пока профиль подключен/подключается, и чистит его vault credentials после удаления settings
- добавлен `Reset All Data...`: спрашивает подтверждение, disconnect всех профилей, очищает settings до нуля профилей, удаляет vault и legacy Keychain credentials приложения
- верхний пункт tray menu показывает версию приложения: `AnyConnectClient 0.0.0 (build 1)`; перед стабильным релизом поднять на `1.0.0` и актуальный build
- общий `ActiveSocksEndpointRegistry` не дает двум активным профилям занять один SOCKS endpoint
- settings JSON валидируется на уникальные profile id и SOCKS endpoint
- при первом connect/ротации сертификата OpenConnectProcess извлекает `pin-sha256` из raw stderr как structured secret, redacted output не содержит pin
- app и `AnyConnectCredentialTool smoke` сохраняют предложенный servercert pin в vault и делают один retry без вывода значения pin
- реальный smoke по локальному профилю: servercert сохранен из OpenConnect, positive URLs вернули HTTP 200, negative URL failed as expected, cleanup закрыл SOCKS port
- `Scripts/smoke-socks.sh` теперь читает settings JSON и credential store, а не legacy profile
- миграция текущего профиля выполнена: password present, servercert present, legacy secret keys absent
- `swift test` проходит: 34 tests, 0 failures

Статус: готово.

Команда для пользователя:

```text
Задание 6: перенеси credentials в Keychain.
```

## Этап 7. System proxy/PAC

Статус: исключено из текущего scope.

System proxy не включать. Пользователь настраивает приложения на SOCKS5 профиля вручную.

Команда для пользователя:

```text
Задание 7: пропусти system proxy и обнови документацию scope.
```

## Этап 8. Packaging runtime

Цель: приложение стабильно работает на текущем Mac без ручного запуска из терминала.

Задачи:

1. Сделать build scripts для OpenConnect и ocproxy.
2. Положить runtime binaries в app bundle.
3. Проверить `otool -L`.
4. Исправить rpath/install_name.
5. Добавить signing flow.

Acceptance:

- app запускается без ручного terminal setup
- bundled binaries находятся через `Bundle.main`
- `otool -L` проверен и зависимости понятны для текущего Mac

Текущий статус 2026-07-05:

- добавлен `Scripts/package-release-app.sh`
- release package собирает `AnyConnectClient.app` с `CFBundleShortVersionString=1.0.0` и build number
- `openconnect` и `ocproxy` копируются в `Contents/Resources`
- Homebrew dylib dependencies копируются в `Contents/Frameworks`, load commands переписываются на bundle-relative paths
- итоговый zip пишется в `build/release/`

Команда для пользователя:

```text
Задание 8: упакуй openconnect/ocproxy runtime в приложение.
```

## Этап 9. Надежность

Цель: ежедневная эксплуатация.

Задачи:

1. Reconnect policy.
2. Sleep/wake handling.
3. Network reachability.
4. Stats polling.
5. Structured diagnostics.
6. Crash-safe cleanup.
7. Connection history store.

Acceptance:

- после сна приложение восстанавливается или честно показывает ошибку
- disconnect всегда чистит процессы и proxy
- user-facing ошибки понятны
- история показывает connect/disconnect/reconnect/fail события без секретов

Команда для пользователя:

```text
Задание 9: добавь надежность для daily use.
```

## Этап 10. Полноценный system VPN

Не входит в текущую цель.

Варианты:

- `NEPacketTunnelProvider`
- bridge к `libopenconnect`
- гибрид: auth через `libopenconnect`, transport через Packet Tunnel

Acceptance будет отдельным, потому что зависит от Apple Developer entitlement и выбранного routing режима.

Команда для пользователя, только если цель изменится:

```text
Задание 10: спроектируй и начни Network Extension/system VPN режим.
```
