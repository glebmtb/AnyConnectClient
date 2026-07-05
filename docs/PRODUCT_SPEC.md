# Product spec

## Назначение

AnyConnectClient - macOS tray-приложение для подключения к AnyConnect VPN в режиме SOCKS5 через OpenConnect и ocproxy.

## Не цели

- Не system-wide VPN.
- Не Network Extension.
- Не system proxy/PAC.
- Не universal binary и не notarized distribution на первом этапе.

## Профили

Пользователь может создать несколько профилей.

Каждый профиль:

- использует протокол `anyconnect`
- имеет server
- имеет username
- может иметь authgroup
- имеет уникальный SOCKS5 port
- может хранить servercert pin после первого подключения

По умолчанию секреты профиля хранятся в Touch ID credential vault: один ключ в Keychain, сами password/servercert pin в зашифрованном локальном vault-файле. В profile settings есть явный unsafe режим без Touch ID; он включается только после предупреждения и не считается strong security.

Локальный bootstrap-профиль для разработки может храниться в ignored dotenv-файле. Его имя и значения считаются локальными секретами и не должны попадать в релизный bundle.

## Подключение

Для профиля приложение запускает:

```text
openconnect --protocol=anyconnect --script-tun --script "<ocproxy ...>"
```

Пароль передается через stdin.

## Smoke criteria

Через SOCKS5 успешного подключения:

- positive smoke URLs задаются только локально пользователем или тестовым окружением
- negative smoke URLs задаются только локально пользователем или тестовым окружением
- конкретные внутренние домены и адреса не хранятся в app bundle и не зашиваются в helper

## Tray states

- stopped: gray icon
- connecting/reconnecting: pulsing icon
- connected: green icon
- failed/degraded: red icon

## Надежность

Приложение должно:

- автоматически переподключать профиль при временной потере сети
- поднимать ранее активные профили после wake
- показывать историю подключений, разрывов и ошибок
- корректно завершать процессы при stop/quit
