<!--
Name: 3x Bundle Guide
Description: Документация по поэтапному инсталлятору 3x-awg-adg-bundle. На этапе 3 скрипт поднимает AmneziaWG и AdGuardHome, запускает официальный интерактивный installer 3x-ui и передаёт дальнейшую настройку панели оператору вручную.
Usage: Read before running setup.sh or uninstall.sh.
Behavior: Explains the current target-only stage, manual 3x-ui handoff, generated outputs, and cleanup path.
Returns: Operator reference for the current bundle layout.
Fails: N/A.
-->

# 3x-awg-adg-bundle

Stage-based installer for a compact VPS stack: **3x-ui**, **AmneziaWG**, and **AdGuardHome**.
At the current stage, `setup.sh` supports `target` only. `relay` intentionally stops early with a clear error until the next migration stage.

[🇷🇺 Перейти к русской версии](#russian) | [🇺🇸 Switch to English version](#english)

---

## <span id="russian"></span>🇷🇺 Русский

### Что сейчас умеет проект

- Запускает официальный интерактивный installer `3x-ui`.
- Не делает silent install и не конфигурирует `3x-ui` автоматически.
- Поднимает `AmneziaWG` и `AdGuardHome` как direct-стек текущего этапа.
- Сохраняет credentials для `AWG` и `AdGuardHome` в `/root/.vpn-credentials`.
- Оставляет порт `443` зарезервированным под `Reality`, но сам inbound и клиентские ссылки оператор настраивает вручную уже внутри `3x-ui`.

### Ограничения этапа 3

- Поддерживается только `--mode target`.
- `--mode relay` специально завершает работу до начала настройки сервисов с понятным fail-fast сообщением.
- `setup.sh` больше не хранит и не генерирует legacy `Xray/cascade` конфиг, `CASCADE_*`, `VLESS_LINK` и `ADG_HTTP_PROXY_PORT`.

### Что делает `setup.sh`

- Обновляет базовую систему и ставит обязательные пакеты.
- Готовит `sysctl`, `BBR`, `swapfile`, `UFW`, `Fail2Ban`, SSH на `2244`.
- Собирает и настраивает `AmneziaWG`.
- Устанавливает и настраивает `AdGuardHome` без HTTP proxy-зависимости от `Xray`.
- Запускает официальный installer `3x-ui` через `/dev/tty`, чтобы оператор прошёл ручной интерактивный flow.
- После installer-а выводит handoff: дальнейшая настройка панели, `Reality` inbound и клиентских ссылок выполняется вручную вне скрипта.

Официальная команда installer-а `3x-ui` сверена с первичным источником: [MHSanaei/3x-ui Wiki](https://github.com/MHSanaei/3x-ui/wiki/Installation) и [репозиторием MHSanaei/3x-ui](https://github.com/MHSanaei/3x-ui).

### Установка

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
```

### Повторный запуск с ротацией

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash -s -- --rotate
```

### Что настроить вручную после installer-а `3x-ui`

1. Завершить мастер installer-а `3x-ui`.
2. Создать и настроить `Reality` inbound внутри панели.
3. Выпустить клиентские ссылки или подписки уже средствами `3x-ui`.
4. Если панель использует отдельный порт, открыть его в `UFW` вручную.

### Удаление

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/uninstall.sh | sudo bash
```

### Важные заметки

- Источник истины по логике установки: `src/setup`, а не собранный `setup.sh`.
- Публичный `setup.sh` собирается через [`tools/build-setup.ps1`](tools/build-setup.ps1).
- Порядок и назначение модулей описаны в [`src/setup/README.md`](src/setup/README.md).
- После первой установки нужен `sudo reboot`.

---

## <span id="english"></span>🇺🇸 English

### Current project scope

- Runs the official interactive `3x-ui` installer.
- Does not perform silent install and does not auto-configure `3x-ui`.
- Brings up `AmneziaWG` and `AdGuardHome` as the direct stack for the current stage.
- Stores `AWG` and `AdGuardHome` credentials in `/root/.vpn-credentials`.
- Keeps port `443` reserved for `Reality`, but the inbound and client links are configured manually by the operator inside `3x-ui`.

### Stage-3 limitations

- Only `--mode target` is supported.
- `--mode relay` intentionally exits before service setup with a clear fail-fast error.
- `setup.sh` no longer stores or generates the legacy `Xray/cascade` config, `CASCADE_*`, `VLESS_LINK`, or `ADG_HTTP_PROXY_PORT`.

### What `setup.sh` does

- Updates the base OS and installs required packages.
- Prepares `sysctl`, `BBR`, `swapfile`, `UFW`, `Fail2Ban`, and SSH on `2244`.
- Builds and configures `AmneziaWG`.
- Installs and configures `AdGuardHome` without any `Xray` HTTP proxy dependency.
- Launches the official `3x-ui` installer through `/dev/tty` so the operator completes the interactive flow manually.
- Prints a handoff after the installer: panel setup, `Reality` inbound creation, and client link generation are handled manually outside the script.

The `3x-ui` installer command was verified against the primary sources: [MHSanaei/3x-ui Wiki](https://github.com/MHSanaei/3x-ui/wiki/Installation) and the [MHSanaei/3x-ui repository](https://github.com/MHSanaei/3x-ui).

### Install

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
```

### Re-run with rotation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash -s -- --rotate
```

### Manual steps after the `3x-ui` installer

1. Finish the `3x-ui` installer wizard.
2. Create and configure the `Reality` inbound inside the panel.
3. Generate client links or subscriptions from `3x-ui`.
4. If the panel uses a dedicated port, open it in `UFW` manually.

### Uninstall

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/uninstall.sh | sudo bash
```

### Notes

- The source of truth for installer logic is `src/setup`, not the assembled `setup.sh`.
- The public `setup.sh` is built through [`tools/build-setup.ps1`](tools/build-setup.ps1).
- Module order and responsibilities are documented in [`src/setup/README.md`](src/setup/README.md).
- A `sudo reboot` is required after the first install.
