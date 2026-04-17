<!--
Name: Xray Reality Bundle Guide
Description: Documentation for the automated VPN/DNS bundle (Xray Reality, AmneziaWG, AdGuardHome).
Usage: Read before running setup.sh or uninstall.sh.
Behavior: Explains the direct Xray install flow, generated outputs, and cleanup path.
Returns: Operator reference for the current bundle layout.
Fails: N/A.
-->

# 3x-awg-adg-bundle

Auto-deploys a compact VPN/DNS stack for a VPS: **AmneziaWG**, **Xray Reality**, and **AdGuardHome**.
The installer configures Xray directly. Panel-based management is not part of the default path anymore.

[🇷🇺 Перейти к русской версии](#russian) | [🇺🇸 Switch to English version](#english)

---

## <span id="russian"></span>🇷🇺 Русский

Этот проект превращает чистый VPS в связку из трёх компонентов:
- AmneziaWG для VPN-доступа.
- Xray Reality на `443`.
- AdGuardHome для DNS-фильтрации и SafeSearch.
- Опциональный каскад через внешний `VLESS Reality` upstream для DNS-выхода AdGuardHome, при этом AWG-трафик идёт direct.

### Топология

```mermaid
graph TD
    User([Устройства])

    subgraph VPS [VPS Сервер]
        AWG[AmneziaWG]
        XR[Xray Reality]
        AGH[AdGuardHome]

        AWG -->|Direct NAT| Net((Интернет))
        AWG -.->|DNS DNAT 53| AGH
        XR -.->|Remote DNS| AGH
    end

    XR -->|VLESS / Reality| Net((Интернет))
    AGH -->|DoH / DoT / UDP| DNS((Публичный DNS))

    User -->|UDP| AWG
    User -->|TCP 443| XR
    User -->|Web UI / DNS| AGH
```

### Что делает `setup.sh`

- Устанавливает `Xray-core 25.1.30` через официальный installer и не откатывается обратно на `latest` при повторном запуске.
- Пишет конфиг в `/usr/local/etc/xray/config.json`.
- Сам `setup.sh` теперь собирается из модулей в `src/setup/` через [`tools/build-setup.ps1`](tools/build-setup.ps1); `src/setup/README.md` описывает порядок и назначение частей.
- Удаляет legacy `x-ui`, если он остался от предыдущих версий, чтобы не было split-brain control plane.
- Поднимает `VLESS + Reality + Vision` inbound на `443`.
- AWG-клиенты выходят в интернет напрямую через MASQUERADE, без Xray/TProxy на dataplane.
- Опционально включает cascade mode через `--cascade-vless`, где внешний `VLESS Reality` upstream может использоваться только для DNS-выхода AdGuardHome, а доменный upstream на этапе установки резолвится в IP, чтобы не ловить DNS-лупы.
- Проксирует upstream DNS AdGuardHome через локальный Xray HTTP proxy и DoH.
- Генерирует и печатает `vless://` ссылку.
- Настраивает AmneziaWG direct egress, DNS DNAT и AdGuardHome.
- Оставляет клиентский профиль AmneziaWG IPv4-only (`AllowedIPs = 0.0.0.0/0`) до полноценной реализации IPv6-маршрутизации.
- Включает базовое hardening: `UFW`, `Fail2Ban`, `BBR`, `sysctl`, SSH на `2244`.

### Установка

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
```

### Установка с каскадом

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | \
  sudo bash -s -- --cascade-vless 'vless://UUID@host:443?type=tcp&security=reality&encryption=none&pbk=...&sni=...&sid=...'
```

- В `v1` принимается только `vless://` c `type=tcp`, `security=reality`, `encryption=none`.
- `--cascade-mode auto` можно передать явно, но это единственный поддерживаемый режим и он же включается по умолчанию вместе с `--cascade-vless`.
- Каскад больше не затрагивает AWG-выход и влияет только на DNS-выход AdGuardHome.

### Повторный запуск с ротацией

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash -s -- --rotate
```

- Повторный запуск без `--rotate` должен переиспользовать текущие credentials `Xray`, `AdGuardHome` и `AmneziaWG`, а не пересоздавать клиентский AWG-профиль.
- При повторном запуске сохранённые credentials и восстановленные значения из существующих конфигов нормализуются от `CRLF`, чтобы Windows-переносы строк не попадали внутрь `Xray` JSON и `AWG`/`AGH` runtime-конфигов.
- Если повторный запуск делается без `--cascade-vless`, скрипт отключает optional DNS cascade и переписывает `CASCADE_*` поля в credentials.

### Удаление

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/uninstall.sh | sudo bash
```

### Важные заметки

- Ссылки, пароли и QR-коды сохраняются в `/root/.vpn-credentials`.
- Дефолтная `VLESS` ссылка печатается самим `setup.sh` после генерации Reality-ключей.
- `Hysteria2` не входит в автоматический inbound-путь этого репозитория. Если нужен именно он, добавляй его отдельно, вне базового сценария.
- После первой установки нужен `sudo reboot`.

---

## <span id="english"></span>🇺🇸 English

This repo turns a clean VPS into a three-part stack:
- AmneziaWG for VPN access.
- Xray Reality on port `443`.
- AdGuardHome for DNS filtering and SafeSearch.
- An optional `VLESS Reality` cascade upstream for AdGuardHome DNS egress, while AWG traffic stays direct.

### Topology

```mermaid
graph TD
    User([Devices])

    subgraph VPS [VPS Server]
        AWG[AmneziaWG]
        XR[Xray Reality]
        AGH[AdGuardHome]

        AWG -->|Direct NAT| Net((Internet))
        AWG -.->|DNS DNAT 53| AGH
        XR -.->|Remote DNS| AGH
    end

    XR -->|VLESS / Reality| Net((Internet))
    AGH -->|DoH / DoT / UDP| DNS((Public DNS))

    User -->|UDP| AWG
    User -->|TCP 443| XR
    User -->|Web UI / DNS| AGH
```

### What `setup.sh` does

- Installs `Xray-core 25.1.30` using the official installer and keeps that pinned version on re-runs.
- Writes the config to `/usr/local/etc/xray/config.json`.
- The public `setup.sh` is assembled from modules under `src/setup/` by [`tools/build-setup.ps1`](tools/build-setup.ps1); `src/setup/README.md` documents the module order and responsibilities.
- Removes legacy `x-ui` leftovers on re-runs so the host keeps a single Xray control plane.
- Creates a `VLESS + Reality + Vision` inbound on port `443`.
- AWG clients exit directly through MASQUERADE, without Xray/TProxy in the dataplane.
- Optionally enables cascade mode through `--cascade-vless`, where AdGuardHome DNS egress can use an upstream `VLESS Reality` exit and the upstream hostname is resolved to an IP during install to avoid DNS loops.
- Proxies AdGuardHome upstream DNS through a local Xray HTTP proxy and DoH.
- Prints a `vless://` link.
- Sets up AmneziaWG direct egress, DNS DNAT, and AdGuardHome.
- Ships the AmneziaWG client profile as IPv4-only (`AllowedIPs = 0.0.0.0/0`) until IPv6 routing is implemented intentionally.
- Enables baseline hardening: `UFW`, `Fail2Ban`, `BBR`, `sysctl`, SSH on `2244`.

### Install

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash
```

### Install with cascade

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | \
  sudo bash -s -- --cascade-vless 'vless://UUID@host:443?type=tcp&security=reality&encryption=none&pbk=...&sni=...&sid=...'
```

- `v1` only accepts `vless://` links with `type=tcp`, `security=reality`, and `encryption=none`.
- `--cascade-mode auto` is the only supported mode and is implied when `--cascade-vless` is present.
- Cascade no longer affects AWG traffic; it only changes AdGuardHome DNS egress.

### Re-run with rotation

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/setup.sh | sudo bash -s -- --rotate
```

- A re-run without `--rotate` is expected to reuse the current `Xray`, `AdGuardHome`, and `AmneziaWG` credentials instead of replacing the active AWG client profile.
- A re-run without `--cascade-vless` disables the optional DNS cascade and rewrites the persisted `CASCADE_*` values.

### Uninstall

```bash
sudo curl -fsSL https://raw.githubusercontent.com/SpIvanM/3x-awg-adg-bundle/main/uninstall.sh | sudo bash
```

### Notes

- Links, passwords, and QR codes are stored in `/root/.vpn-credentials`.
- The default `VLESS` link is printed by `setup.sh` after Reality keys are generated.
- `Hysteria2` is not part of the automated inbound flow in this repo. If you need it, add it separately outside the default path.
- A `sudo reboot` is required after the first install.
