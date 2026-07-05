# Архитектура AnyConnectClient

Дата исследования: 2026-07-04.

## Что уже есть

- Репозиторий пока без Swift-проекта.
- `ThirdParty/openconnect-9.21/` содержит OpenConnect 9.21, уже собранный под macOS arm64.
- `ThirdParty/ocproxy/` содержит ocproxy 1.70, уже собранный под macOS arm64.
- Локальные profile/credentials файлы считаем секретными и ignored.
- Текущий `openconnect` собран с `--with-vpnc-script=ocproxy_capture_env.sh --disable-shared --enable-static`.
- Текущий `openconnect` динамически зависит от Homebrew-библиотек: `gnutls`, `p11-kit`, `stoken`, `lz4`, `nettle`, `gmp`, `gettext`.
- Текущий `ocproxy` динамически зависит от Homebrew `libevent`.
- Целевой протокол: `anyconnect`.
- Целевой продукт: только SOCKS5-клиент, без system proxy и без system-wide VPN.
- Целевая платформа: только текущий Mac arm64.

## Вывод по OpenConnect

OpenConnect поддерживает:

- `--protocol=anyconnect|nc|gp|pulse|f5|fortinet|array`
- `--passwd-on-stdin`
- `--authenticate`, `--cookie`, `--cookieonly`, `--printcookie`
- `--servercert`, `--resolve`, `--sni`
- `--script-tun`
- `--script=<command>`
- `--os=mac-intel`
- `--no-dtls`, `--disable-ipv6`, `--authgroup`

`libopenconnect` также имеет публичный C API в `openconnect.h`: создание `vpninfo`, callbacks для auth form, cert validation, progress logs, `openconnect_setup_tun_script`, `openconnect_mainloop`, command pipe и stats handler.

## Стратегия

### Решение 1: рабочий режим через CLI и ocproxy

Production-useful вариант делаем как macOS menu bar app, который управляет процессом:

```text
Swift App
  -> VPNCore
  -> AnyConnectClientSupport
  -> OpenConnectRuntime
  -> openconnect --script-tun --script "<ocproxy -D 11080 ...>"
  -> local SOCKS5 127.0.0.1:11080
```

Почему так:

- Это соответствует целевому продукту: нужен именно SOCKS5, а не system-wide VPN.
- `ocproxy` штатно предназначен для `openconnect --script-tun`.
- Не нужен root для TUN, route и DNS.
- Можно подключать браузер, терминал и отдельные приложения через SOCKS.
- Каждый профиль может иметь свой локальный SOCKS-порт.

Ограничение:

- Это не полноценный system-wide VPN. Приложения должны использовать SOCKS вручную.
- System proxy специально не включаем.

### Multi-profile runtime

- Каждый профиль имеет собственный `OpenConnectSession`, собственный `Process` и собственный `ocproxy` lifecycle.
- Menu bar app хранит активные runtime-сессии в словаре по `VPNProfileID`.
- `selectedProfileID` не является user-facing режимом; это внутренняя деталь settings-store для сохранения изменений профиля.
- Tray menu держит плоскую секцию `Connections`, где каждая строка профиля сразу является действием `Connect <profile>` или `Disconnect <profile>`.
- Секция `Profiles` открывает настройки конкретного профиля прямым кликом по строке профиля.
- `Add Profile...` создает новый профиль.
- Удаление находится внутри окна settings конкретного профиля через кнопку `Delete`, с отдельным подтверждением.
- В settings конкретного профиля есть `Auto-start / On app launch`: если включено, приложение автоматически подключает этот профиль при запуске. Флаг хранится в profile settings JSON, старые settings без поля читаются как `false`.
- Последний профиль можно удалить; empty settings document является валидным состоянием и блокирует автоматическое восстановление legacy-профилей.
- Legacy import выполняется только когда settings JSON отсутствует; legacy merge с существующим settings JSON запрещен.
- `Reset All Data...` останавливает активные сессии, очищает settings до нуля профилей, удаляет Touch ID credential vault и старые Keychain credentials сервиса `AnyConnectClient`.
- Удаление профиля разрешено только в stopped/failed состоянии и удаляет его credentials из Touch ID vault после успешного удаления settings.
- Два профиля могут быть подключены одновременно, если у них разные SOCKS endpoint.
- Общий `ActiveSocksEndpointRegistry` резервирует endpoint на время активной сессии и освобождает его при stop/exit.
- Settings document валидируется на уникальные profile id и SOCKS endpoint, чтобы конфликт портов ловился до connect.
- Для crash/`kill -9` recovery app пишет `runtime-registry.json` в Application Support. В нем хранятся только profile id, SOCKS port, PID `openconnect`, PID `ocproxy` и timestamp. При следующем старте приложение проверяет, что PID живы и SOCKS port слушает; здоровую сессию помечает как `connected`, протухшую запись чистит вместе с известными PID. Это не attach к старому `Process`, поэтому старые logs не восстанавливаются, но `Disconnect`/`Quit` снова управляют процессами.
- Startup flow сначала выполняет crash recovery, затем подключает профили с `autoStartOnLaunch=true`; уже recovered/connected профили повторно не стартуют.
- `ocproxy-wrapper` снимает route import из script environment OpenConnect в отдельный временный файл. Сохраняются только `CISCO_SPLIT_INC`, `CISCO_SPLIT_EXC`, `CISCO_IPV6_SPLIT_INC`, `CISCO_IPV6_SPLIT_EXC` и их route-поля; общий env, cookie, DNS и credentials не копируются. Settings UI показывает эти маршруты только по явному нажатию `Fetch`.

### Решение 2: полноценный VPN после MVP

Сейчас не входит в цель. Если когда-нибудь понадобится system-wide VPN, есть два варианта:

- `Network Extension` / `NEPacketTunnelProvider` для system VPN.
- Прямой Swift/C bridge к `libopenconnect`, чтобы получить callbacks, auth forms и packet flow без shell-wrapper.

Этот этап требует Apple Developer entitlements, signing, app extension target, routing/DNS settings и отдельной диагностики. Не начинать без нового явного решения.

## Целевая структура каталогов

```text
AnyConnectClient/
  Package.swift
  AGENTS.md
  docs/
    ARCHITECTURE.md
    TASK_PLAN.md
    DECISIONS.md
  Apps/
    AnyConnectClient/
      AnyConnectClientApp.swift
      AppDelegate.swift
      MenuBar/
      Views/
      Assets.xcassets/
  Sources/
    VPNCore/
      Domain/
        VPNProfile.swift
        VPNProfileID.swift
        VPNCredentials.swift
        VPNProtocol.swift
        SocksEndpoint.swift
        ConnectionState.swift
        VPNConnectionError.swift
        ConnectionHistoryEvent.swift
      UseCases/
        ConnectVPN.swift
        DisconnectVPN.swift
        ReconnectVPN.swift
      State/
        VPNConnectionStateMachine.swift
      Logging/
        VPNLogEntry.swift
        Redactor.swift
    OpenConnectRuntime/
      OpenConnectCommandBuilder.swift
      OpenConnectProcess.swift
      OpenConnectLogParser.swift
      OcproxyCommandBuilder.swift
      RuntimePaths.swift
      RuntimeHealthCheck.swift
    AnyConnectClientSupport/
      KeychainCredentialStore.swift
      TouchIDVaultCredentialStore.swift
      ProfileConfigurationLoader.swift
      VPNProfileSettings.swift
    AppSupport/
      DiagnosticsStore.swift
      SettingsStore.swift
  Tests/
    VPNCoreTests/
    OpenConnectRuntimeTests/
    CredentialsTests/
  ThirdParty/
    openconnect-9.21/
    ocproxy/
  BuildSupport/
    build-openconnect.sh
    build-ocproxy.sh
    package-runtime.sh
```

На старте можно создать только `Package.swift`, `Sources/VPNCore`, `Sources/OpenConnectRuntime`, `Tests` и минимальный app target. `SystemProxy` и `Extensions/PacketTunnelProvider` не создавать, пока цель остается "только SOCKS5".

## Модули

### `VPNCore`

Чистая бизнес-логика без UI и без `Process`.

Отвечает за:

- профиль VPN
- несколько профилей
- SOCKS endpoint на профиль
- состояние подключения
- ошибки
- redaction
- use cases
- state machine
- историю connect/disconnect/reconnect/fail событий

Не импортирует:

- SwiftUI
- AppKit
- NetworkExtension
- Security

### `OpenConnectRuntime`

Один слой вокруг OpenConnect и ocproxy.

Отвечает за:

- построение argv
- запуск и остановку процессов
- stdin для пароля
- stdout/stderr stream
- parsing состояния из logs
- проверку runtime paths
- запрет shell-string там, где можно executable + arguments

### `AnyConnectClientSupport`

Отвечает за:

- чтение runtime profile settings из `~/Library/Application Support/AnyConnectClient/profile-settings.json`
- явный одноразовый legacy import из ignored local profile
- перенос пароля и servercert pin в Touch ID credential vault
- очистку legacy secret keys из legacy profile после успешного импорта
- выдачу runtime credentials только на время connect

Не отвечает за:

- lifecycle `openconnect`/`ocproxy`
- UI/AppKit
- хранение секретов в JSON/settings

### `App`

Тонкий UI:

- status
- connect/disconnect
- profile selector
- compact logs
- diagnostics export с redaction

## Runtime-команда MVP

Форма команды:

```text
openconnect
  --protocol=anyconnect
  --user=<username>
  --passwd-on-stdin
  --script-tun
  --script=<absolute path to ocproxy> -D 127.0.0.1:<port> -k <seconds>
  --os=mac-intel
  <server>
```

Дополнительные флаги включать только по профилю:

- `--authgroup=<group>`
- `--servercert=<fingerprint>`
- `--no-dtls`
- `--disable-ipv6`
- `--cafile=<path>`
- `--resolve=<host:ip>`
- `--sni=<host>`

Пароль передается только через stdin. Команда в логах redacted.

## Профили

Runtime profile settings хранит:

- display name
- server URL/host
- username
- authgroup
- SOCKS host, обычно `127.0.0.1`
- SOCKS port, уникальный для профиля
- reconnect policy

Runtime profile settings не хранит:

- password
- OTP/token
- cookie
- servercert pin

Секреты хранятся в Touch ID credential vault:

- password
- servercert pin
- future cookie/token values

Vault состоит из одного случайного AES-GCM ключа в Keychain service `AnyConnectClient` и зашифрованного файла:

```text
~/Library/Application Support/AnyConnectClient/credential-vault.json
```

Keychain item в signed-capable режиме защищен Touch ID (`biometryCurrentSet`). В SwiftPM/dev-build macOS может вернуть Keychain `-34018` при создании такого item; тогда включается fallback: vault key хранится обычным app Keychain item, но чтение после restart gated явным Touch ID prompt на уровне приложения. После первого unlock приложение держит расшифрованный vault только в памяти текущего app-процесса, чтобы connect/reconnect нескольких профилей не вызывали повторные Keychain prompts.

Per-profile можно включить unsafe local storage через галочку `Store without Touch ID (unsafe)` в окне профиля. В момент включения галочки UI показывает предупреждение и требует явное подтверждение; если пользователь нажал Cancel, галочка возвращается в off. Если для миграции из Touch ID vault пользователь отменил Touch ID, UI предлагает ввести VPN password заново и сохраняет уже его. Unsafe secrets лежат в:

```text
~/Library/Application Support/AnyConnectClient/unsafe-credential-vault.json
```

Файл шифруется AES-GCM с app-key и правами `0600`, но это не strong security: ключ поставляется вместе с приложением, поэтому этот режим защищает только от случайного просмотра файла, а не от пользователя/процесса с доступом к app и user data. В tray menu storage mode не показывается, чтобы не засорять меню; менять и видеть его можно только в profile settings.

Старые per-profile Keychain items (`<profileID>.password`, `<profileID>.servercert`) считаются legacy. При первом чтении профиль лениво мигрируется в vault, после успешной записи старая запись профиля удаляется.

Legacy profile считается import-only источником. После миграции приложение должно работать без него; settings screen пишет server, login и SOCKS port в app settings, а password в vault.

## Server certificate pin

На первом подключении OpenConnect может вернуть fingerprint/pin. Его можно сохранить и дальше передавать как `--servercert`.

Pin не считаем вечным: VPN-сторона может прислать новый fingerprint при ротации сертификата. Для этого клиента принято auto-trust поведение: если OpenConnect сам прислал новый `pin-sha256` в диагностике сертификата, runtime забирает pin как structured secret, сохраняет его в vault и повторяет connect один раз.

Правило UI:

- pin не показывать пользователю по умолчанию
- в логах pin redacted
- в diagnostics показывать только наличие pin: `present: true`
- если OpenConnect сообщает, что нужен/сменился `--servercert`, не показывать значение, сохранить pin в vault и выполнить один retry
- новый pin не писать в обычные логи и не показывать в menu item
- если retry тоже не поднялся, оставить профиль в failed-состоянии с redacted причиной

## Tray UI

Приложение живет в tray/menu bar.

Состояния и иконки:

- stopped: серая статичная
- connecting/reconnecting: пульсирующая
- connected: зеленая
- failed/degraded: красная

Ожидаемые действия:

- start profile
- stop profile
- reconnect profile
- open connection history
- open settings
- quit

Если несколько профилей запущены одновременно, главный статус:

- red, если хотя бы один профиль failed
- pulsing, если хотя бы один профиль connecting/reconnecting и нет failed
- green, если есть connected и нет failed/connecting
- gray, если все stopped

## Надежность

Клиент должен:

- держать соединение постоянно
- переподключаться при временной потере интернета
- переподключаться после wake ноутбука
- сохранять историю подключений и разрывов
- очищать процессы при stop/quit
- запускать `ocproxy` через контролируемый wrapper/pidfile, потому что `openconnect --script-tun` может оставить `ocproxy` живым после stop/error

История хранит redacted события:

- profile id/name
- timestamp
- state transition
- technical error code/message без секретов
- reconnect attempt number

## Smoke tests

Через SOCKS5 профиля должны открываться:

- positive smoke URLs, заданные локально пользователем или тестовым окружением

Через этот же SOCKS5 не должен открываться:

- negative smoke URLs, заданные локально пользователем или тестовым окружением

Текущий diagnostic note:

- OpenConnect connected и `ocproxy` ready подтверждаются.
- `INTERNAL_IP4_DNS` приходит в script env.
- Для CLI smoke использовать SOCKS5h-форму: `curl --noproxy "" --socks5-hostname 127.0.0.1:<port> ...`.
- `NO_PROXY/no_proxy` может содержать внутренний доменный suffix и заставить `curl` обходить SOCKS до DNS-запроса.
- `Scripts/smoke-socks.sh` читает runtime settings JSON и пароль/servercert из credential store; legacy profile нужен только для первого import.

## Риски

- Абсолютные Homebrew dylib пути сломают переносимость `.app`; release packaging должен копировать Homebrew dylibs в `Contents/Frameworks` и переписывать load commands через `install_name_tool`.
- CLI interactive auth может потребовать parser prompts. Если сервер использует сложные auth forms или SSO, быстрее перейти к `libopenconnect` callbacks.
- System-wide VPN намеренно не входит в scope.
- Сертификаты и servercert pinning надо решить до production-use.
- Servercert pin может ротироваться; mismatch должен блокировать silent reconnect и требовать explicit trust/update.
- CLI smoke должен явно отключать `NO_PROXY`, иначе можно получить ложный DNS-fail вне SOCKS.
- Multi-profile runtime требует аккуратного port allocation и process lifecycle на профиль.

## Источники

- Локально: `ThirdParty/openconnect-9.21/README.md`
- Локально: `ThirdParty/openconnect-9.21/openconnect.h`
- Локально: `ThirdParty/openconnect-9.21/config.log`
- Локально: `ThirdParty/ocproxy/README.md`
- Локально: `ThirdParty/ocproxy/src/ocproxy.c`
- OpenConnect build docs: https://www.infradead.org/openconnect/building.html
- OpenConnect GUI/front-end docs: https://www.infradead.org/openconnect/gui.html
- Apple Network Extension docs: https://developer.apple.com/documentation/networkextension/nepackettunnelprovider
- Swift Package Manager docs: https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html
