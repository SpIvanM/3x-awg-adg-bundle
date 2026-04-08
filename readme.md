<!--
Name: vps-vpn-triad (3x-ui + AWG + AdGuard)
Description: Configures OS networking, 3x-ui, AmneziaWG and AdGuardHome on Debian 11 and Ubuntu.
Usage: bash <(curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh)
Behavior: Updates sysctl, installs OS packages, compiles AmneziaWG kernel module, sets up AdGuard.
Returns: Complete VPN and DNS server proxy routing.
Fails: If run without root privileges.
-->

# 3x-awg-adg-bundle

[🇷🇺 Русский](#russian) | [🇺🇸 English](#english)

---

`<a name="russian"></a>`

## 🇷🇺 Русский

**Комплексный VPN-бандл** для автоматической инициализации и защиты VPS.
Объединяет **3x-ui**, **AmneziaWG** и **AdGuardHome**.

### Состав

- **3x-ui**: Управление Xray прокси.
- **AmneziaWG**: VPN с обфускацией (защита от DPI).
- **AdGuardHome**: DNS-фильтрация и блокировка рекламы.

### Поддерживаемые ОС

- **Debian 11+**
- **Ubuntu 20.04+**

### Установка

Выполните одну команду для полной установки:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh)
```

### После установки

**ВАЖНО: Обязательно выполните перезагрузку:**

```bash
sudo reboot
```

---

`<a name="english"></a>`

## 🇺🇸 English

**Comprehensive VPN bundle** for automated VPS initialization and security.
Combines **3x-ui**, **AmneziaWG**, and **AdGuardHome**.

### Components

- **3x-ui**: Xray proxy management.
- **AmneziaWG**: VPN with obfuscation (DPI protection).
- **AdGuardHome**: DNS filtering and ad blocking.

### Supported OS

- **Debian 11+**
- **Ubuntu 20.04+**

### Installation

Run a single command for a complete installation:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh)
```

### After Installation

**IMPORTANT: A reboot is mandatory:**

```bash
sudo reboot
```

---
