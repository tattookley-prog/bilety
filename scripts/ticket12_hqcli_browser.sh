#!/bin/bash
# =============================================================================
# Билет №12 — Подготовка рабочего места администратора (HQ-CLI)
# Установка Яндекс Браузера для организаций, проверка moodle/wiki через прокси.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

declare -A STATUS

echo
echo "============================================================"
echo "  Билет №12 — Яндекс Браузер + проверка веб-сервисов (HQ-CLI)"
echo "============================================================"
echo
read -rp "Адрес Moodle [moodle.au-team.irpo]: " MOODLE; MOODLE="${MOODLE:-moodle.au-team.irpo}"
read -rp "Адрес Wiki [wiki.au-team.irpo]: " WIKI; WIKI="${WIKI:-wiki.au-team.irpo}"
read -rp "DNS-сервер AD DC (BR-SRV) для resolv.conf [192.168.3.2]: " DNS_NS; DNS_NS="${DNS_NS:-192.168.3.2}"

echo
info "Будет установлен Яндекс Браузер для организаций, проверка $MOODLE и $WIKI"
info "DNS для HQ-CLI: nameserver ${DNS_NS}"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

# ─── Установка Яндекс Браузера ─────────────────────────────────────────────[...]
install_browser() {
    # 1. Попытка из репозитория ALT (разные варианты имени пакета)
    apt-get update -y || true
    for PKG in yandex-browser-corporate yandex-browser yandex-browser-stable; do
        if apt-get install -y "$PKG" 2>/dev/null; then
            ok "$PKG установлен из репозитория"; STATUS[browser]=OK; return 0
        fi
    done

    warn "Пакета нет в APT-репозитории. Пробую скачать DEB/RPM напрямую..."

    # 2. Попытка скачать DEB с зеркала Яндекса
    DEB_URLS=(
        "https://repo.yandex.ru/yandex-browser/deb/pool/main/y/yandex-browser-corporate/yandex-browser-corporate_latest_amd64.deb"
        "https://browser.yandex.ru/download?os=linux&type=deb_enterprise"
    )
    for URL in "${DEB_URLS[@]}"; do
        info "Пробую: $URL"
        if command -v curl >/dev/null 2>&1; then
            if curl -fL --max-time 60 -o /tmp/yandex-browser.deb "$URL" 2>/dev/null && \
               [[ -s /tmp/yandex-browser.deb ]]; then
                break
            fi
        elif command -v wget >/dev/null 2>&1; then
            if wget -q --timeout=60 -O /tmp/yandex-browser.deb "$URL" 2>/dev/null && \
               [[ -s /tmp/yandex-browser.deb ]]; then
                break
            fi
        fi
    done

    if [[ -s /tmp/yandex-browser.deb ]]; then
        if apt-get install -y /tmp/yandex-browser.deb 2>/dev/null || \
           dpkg -i /tmp/yandex-browser.deb 2>/dev/null; then
            ok "Яндекс Браузер установлен из DEB-файла"; STATUS[browser]=OK; return 0
        fi
    fi

    # 3. Попытка добавить репозиторий Яндекса и установить
    info "Добавляю репозиторий Яндекс Браузера..."
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG" \
            -o /etc/apt/trusted.gpg.d/yandex-browser.gpg 2>/dev/null || true
    fi
    echo "deb [arch=amd64] https://repo.yandex.ru/yandex-browser/deb/ stable main" \
        > /etc/apt/sources.list.d/yandex-browser.list
    apt-get update -y 2>/dev/null || true
    for PKG in yandex-browser-corporate yandex-browser yandex-browser-stable; do
        if apt-get install -y "$PKG" 2>/dev/null; then
            ok "$PKG установлен из репозитория Яндекса"; STATUS[browser]=OK; return 0
        fi
    done

    # 4. Ничего не помогло
    error "Не удалось установить Яндекс Браузер автоматически"
    warn "Установите вручную:"
    warn "  1. Скачайте DEB с https://browser.yandex.ru/download?os=linux&type=deb_enterprise"
    warn "  2. apt-get install -y ./yandex-browser-corporate*.deb"
    STATUS[browser]=ERROR
    return 1
}

install_browser

# Проверка — браузер установлен?
if command -v yandex-browser yandex-browser-corporate yandex_browser 2>/dev/null | head -n1 | grep -q .; then
    ok "Яндекс Браузер найден: $(command -v yandex-browser yandex-browser-corporate yandex_browser 2>/dev/null | head -n1)"
    STATUS[browser]=OK
fi

# ─── DNS резолвер HQ-CLI (/etc/resolv.conf) ─────────────────────────────
ensure_resolver() {
    local current
    current="$(grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null || true)"
    if echo "$current" | grep -Eq "^[[:space:]]*nameserver[[:space:]]+${DNS_NS}([[:space:]]|\$)"; then
        ok "/etc/resolv.conf уже содержит nameserver ${DNS_NS}"
        STATUS[dns_cfg]=OK
        return 0
    fi

    warn "/etc/resolv.conf не содержит nameserver ${DNS_NS}"
    if [[ -n "$current" ]]; then
        echo "$current"
    else
        warn "Текущие nameserver не найдены"
    fi
    read -rp "Добавить nameserver ${DNS_NS} в /etc/resolv.conf (с backup .bak)? [y/N]: " FIX_DNS
    if [[ ! "${FIX_DNS,,}" =~ ^y ]]; then
        warn "Автоправка DNS пропущена"
        STATUS[dns_cfg]=SKIP
        return 0
    fi

    cp -n /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    {
        echo "nameserver ${DNS_NS}"
        grep -E '^[[:space:]]*nameserver[[:space:]]+' /etc/resolv.conf 2>/dev/null | awk -v ns="${DNS_NS}" '$2 != ns' || true
        grep -E '^[[:space:]]*(search|domain|options)[[:space:]]+' /etc/resolv.conf 2>/dev/null || true
    } > "/tmp/resolv.conf.ticket12.$$"
    mv "/tmp/resolv.conf.ticket12.$$" /etc/resolv.conf

    if grep -Eq "^[[:space:]]*nameserver[[:space:]]+${DNS_NS}([[:space:]]|\$)" /etc/resolv.conf; then
        ok "DNS настроен: nameserver ${DNS_NS} (копия: /etc/resolv.conf.bak)"
        STATUS[dns_cfg]=OK
    else
        warn "Не удалось подтвердить настройку DNS"
        STATUS[dns_cfg]=ERROR
    fi
}

ensure_resolver

# ─── DNS ────────────────────────────────────────────────────────────[...]
echo; info "Диагностика DNS-имён..."
for name in "$MOODLE" "$WIKI"; do
    res="$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [[ -n "$res" ]]; then
        ok "DNS: $name → $res"
    else
        warn "DNS: $name не резолвится — проверьте DNS Samba AD DC на BR-SRV и /etc/resolv.conf"
    fi
done

# ─── HTTP ───────────────────────────────────────────────────────────[...]
echo; info "Проверка HTTP-доступности через обратный прокси..."
check_http() {
    local url="$1" code
    code="$(curl -s -o /dev/null -w '%{http_code}' -L --max-time 10 "$url" 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
        ok "$url → HTTP $code"; return 0
    else
        warn "$url → HTTP $code"; return 1
    fi
}
if check_http "http://${MOODLE}/"; then STATUS[moodle]=OK; else STATUS[moodle]=ERROR; fi
if check_http "http://${WIKI}/";   then STATUS[wiki]=OK;   else STATUS[wiki]=ERROR;   fi

# ─── Итог ──────────────────────────────────────────────────────────[...]
echo
echo "============================================================"
echo "  Итог — Билет №12"
echo "============================================================"
for k in browser dns_cfg moodle wiki; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Откройте в браузере http://${MOODLE} и http://${WIKI}"

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
command -v yandex-browser yandex_browser yandex-browser-corporate      # Браузер установлен
cat /etc/resolv.conf                                                    # DNS указывает на BR-SRV
getent hosts moodle.au-team.irpo                                        # DNS-резолв moodle
getent hosts wiki.au-team.irpo                                          # DNS-резолв wiki
curl -I http://moodle.au-team.irpo                                      # Доступ к Moodle
curl -I http://wiki.au-team.irpo                                        # Доступ к MediaWiki
EOF
