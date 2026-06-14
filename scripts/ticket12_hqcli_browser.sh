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

# =============================================================================
# Установка Яндекс Браузера (ALT Workstation)
# На ALT Linux пакет называется yandex-browser-stable, репозиторий отдельный.
# =============================================================================
info "Установка Яндекс Браузера для организаций..."

# ── Шаг 1: добавить репозиторий Яндекса для ALT Linux ────────────────────────
YANDEX_REPO_FILE="/etc/apt/sources.list.d/yandex-browser.list"
YANDEX_REPO_LINE="rpm http://repo.yandex.ru yandex-browser/alt/x86_64 yandex-browser"

if [[ ! -f "$YANDEX_REPO_FILE" ]] || ! grep -qF "repo.yandex.ru" "$YANDEX_REPO_FILE" 2>/dev/null; then
    info "Добавляю репозиторий Яндекса: $YANDEX_REPO_LINE"
    echo "$YANDEX_REPO_LINE" > "$YANDEX_REPO_FILE"
    # Импорт GPG-ключа Яндекса (ALT использует rpm --import)
    if command -v rpm >/dev/null 2>&1; then
        if command -v wget >/dev/null 2>&1; then
            wget -qO /tmp/yandex-browser.key \
                "https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG" 2>/dev/null && \
                rpm --import /tmp/yandex-browser.key 2>/dev/null || true
        elif command -v curl >/dev/null 2>&1; then
            curl -fsSLo /tmp/yandex-browser.key \
                "https://repo.yandex.ru/yandex-browser/YANDEX-BROWSER-KEY.GPG" 2>/dev/null && \
                rpm --import /tmp/yandex-browser.key 2>/dev/null || true
        fi
    fi
    apt-get update -y 2>/dev/null || true
else
    ok "Репозиторий Яндекса уже подключён"
    apt-get update -y 2>/dev/null || true
fi

# ── Шаг 2: попробовать оба возможных имени пакета ────────────────────────────
BROWSER_INSTALLED=false
for PKG in yandex-browser-stable yandex-browser-corporate; do
    if apt-get install -y "$PKG" 2>/dev/null; then
        ok "$PKG установлен из репозитория Яндекса"
        STATUS[browser]=OK
        BROWSER_INSTALLED=true
        break
    fi
done

# ── Шаг 3: fallback — прямое скачивание RPM с индексной страницы ─────────────
if [[ "$BROWSER_INSTALLED" == false ]]; then
    warn "Пакет не найден в репозитории. Пробую прямую загрузку RPM..."
    # Актуальный путь к rpm-пакетам для ALT x86_64
    RPM_BASE="https://repo.yandex.ru/yandex-browser/alt/x86_64"
    RPM_FILE="/tmp/yandex-browser-stable.rpm"

    # Определяем имя последнего RPM через HTML-индекс
    DL_URL=""
    if command -v curl >/dev/null 2>&1; then
        DL_URL=$(curl -fsSL "$RPM_BASE/" 2>/dev/null \
            | grep -oP 'href="yandex-browser-stable[^"]+\.x86_64\.rpm"' \
            | tail -n1 | grep -oP '(?<=href=")[^"]+' || true)
        [[ -n "$DL_URL" ]] && DL_URL="${RPM_BASE}/${DL_URL}"
        [[ -n "$DL_URL" ]] && curl -fsSL -o "$RPM_FILE" "$DL_URL" || true
    elif command -v wget >/dev/null 2>&1; then
        DL_URL=$(wget -qO- "$RPM_BASE/" 2>/dev/null \
            | grep -oP 'href="yandex-browser-stable[^"]+\.x86_64\.rpm"' \
            | tail -n1 | grep -oP '(?<=href=")[^"]+' || true)
        [[ -n "$DL_URL" ]] && DL_URL="${RPM_BASE}/${DL_URL}"
        [[ -n "$DL_URL" ]] && wget -qO "$RPM_FILE" "$DL_URL" || true
    fi

    if [[ -s "$RPM_FILE" ]]; then
        if apt-get install -y "$RPM_FILE" 2>/dev/null || \
           rpm -i --nodeps "$RPM_FILE" 2>/dev/null; then
            ok "Яндекс Браузер установлен из RPM ($DL_URL)"
            STATUS[browser]=OK
        else
            error "Не удалось установить RPM: $RPM_FILE"
            STATUS[browser]=ERROR
        fi
    else
        error "Не удалось скачать RPM. URL: ${DL_URL:-не определён}. Проверьте интернет и репозиторий."
        STATUS[browser]=ERROR
    fi
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

echo; info "Диагностика DNS-имён..."
for name in "$MOODLE" "$WIKI"; do
    res="$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [[ -n "$res" ]]; then
        ok "DNS: $name → $res"
    else
        warn "DNS: $name не резолвится — проверьте DNS Samba AD DC на BR-SRV и /etc/resolv.conf"
    fi
done

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
command -v yandex-browser yandex_browser yandex-browser-stable yandex-browser-corporate  # Браузер установлен
cat /etc/apt/sources.list.d/yandex-browser.list                                           # Репозиторий Яндекса
cat /etc/resolv.conf                                                                       # DNS указывает на BR-SRV
getent hosts moodle.au-team.irpo                                                           # DNS-резолв moodle
getent hosts wiki.au-team.irpo                                                             # DNS-резолв wiki
curl -I http://moodle.au-team.irpo                                                         # Доступ к Moodle
curl -I http://wiki.au-team.irpo                                                           # Доступ к MediaWiki
EOF
