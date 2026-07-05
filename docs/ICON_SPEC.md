# Icon spec

## Идея

Образ: компактный тоннель/порт как знак локального SOCKS5-шлюза. Не щит и не глобус, чтобы не обещать system-wide VPN. Форма должна читаться в menu bar при 16-18 pt.

## App icon

Концепт:

- темный округлый квадрат macOS-style
- внутри минимальный знак: три connected nodes и дуга тоннеля
- акцентный зеленый connection marker внутри тоннеля
- без текста

Визуальный смысл:

- "локальный порт"
- "туннель"
- "соединение активно"

## Tray icon

Одна и та же монохромная форма, меняется состояние:

- stopped: gray
- connecting/reconnecting: gray/green pulsing animation
- connected: green
- failed/degraded: red

Пульсация:

- не менять форму
- плавно менять opacity или glow
- период около 1.2 секунды

## Asset rules

- Tray icon должна работать как template/vector-like asset.
- Не использовать мелкие детали, текст, замки, глобусы и щиты.
- Цвета состояния должны быть различимы на dark и light menu bar.

## Build assets

- App icon генерируется скриптом `Scripts/generate-app-icon.swift`.
- Source: `Assets/AppIconSource.png`.
- Preview: `Assets/AppIcon.png`.
- macOS bundle icon: `Assets/AppIcon.icns`.
- Release packaging копирует `Assets/AppIcon.icns` в `Contents/Resources/AppIcon.icns` и прописывает `CFBundleIconFile`.
