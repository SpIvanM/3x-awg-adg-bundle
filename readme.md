<!--
Name: vps-vpn-triad (3x-ui + AWG + AdGuard)
Description: Configures OS networking, 3x-ui, AmneziaWG and AdGuardHome on Debian 11 and Ubuntu.
Usage: curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up AdGuard.
Returns: Complete VPN and DNS server proxy routing.
Fails: If run without root privileges.
Stability: Do not wrap HTML anchors/spans in backticks; keep IDs inside headers.
-->

# 3x-awg-adg-bundle

[🇷🇺 Русский](#russian) | [🇺🇸 English](#english)

---

## <span id="russian"></span>🇷🇺 Русский

**Комплексный VPN-бандл** для автоматической инициализации и защиты VPS.  
Объединяет **3x-ui**, **AmneziaWG** и **AdGuardHome** в одну экосистему.

### Особенности

- **Идемпотентность**: Скрипт можно запускать повторно. Он подхватит существующие пароли/порты и не будет переустанавливать то, что уже работает.
- **DPI Protection**: AmneziaWG с настроенными параметрами обфускации (защита от блокировок ТСПУ).
- **DNS Security**: AdGuardHome блокирует рекламу и трекеры. Включен **Безопасный поиск** (Google, YT, Yandex).
- **Auto-Config**: Автоматическое создание VLESS-Reality инбаунда и AmneziaWG конфига с QR-кодом.

### Поддерживаемые ОС

- **Debian 11+**
- **Ubuntu 20.04+**

### Установка

Выполните одну команду для полной установки:

```bash
curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
```

### Удаление

Если нужно полностью очистить сервер:

```bash
curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/uninstall.sh | sudo bash
```

### Важно

- **Рестарт**: После первой установки обязателен `sudo reboot`.
- **Доступ**: Все пароли и ссылки сохраняются в файле `/root/.vpn-credentials`.
- **SSH**: Порт меняется на **2244**.

---

## <span id="english"></span>🇺🇸 English

**Comprehensive VPN bundle** for automated VPS initialization and security.  
Integrates **3x-ui**, **AmneziaWG**, and **AdGuardHome** into a single ecosystem.

### Features

- **Idempotency**: The script can be run multiple times safely. It preserves existing credentials/ports and skips already installed components.
- **DPI Protection**: AmneziaWG with pre-configured obfuscation parameters to bypass DPI filters.
- **DNS Security**: AdGuardHome for ad-blocking and tracking protection. **SafeSearch** is enabled (Google, YT, Yandex).
- **Auto-Config**: Automatic creation of VLESS-Reality inbound and AmneziaWG config with QR code.

### Supported OS

- **Debian 11+**
- **Ubuntu 20.04+**

### Installation

Run a single command for a complete installation:

```bash
curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
```

### Uninstallation

To completely remove all components from the server:

```bash
curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/uninstall.sh | sudo bash
```

### Important

- **Reboot**: A `sudo reboot` is mandatory after the initial installation.
- **Credentials**: All passwords and links are stored in `/root/.vpn-credentials`.
- **SSH**: The default port is changed to **2244**.
