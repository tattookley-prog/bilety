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

echo
info "Будет установлен Яндекс Браузер для организаций, проверка $MOODLE и $WIKI"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Установка Яндекс Браузера для организаций..."
apt-get update -y || true
if apt-get install -y yandex-browser-corporate; then
    ok "yandex-browser-corporate установлен из репозитория"; STATUS[browser]=OK
else
    warn "Пакета нет в репозитории. Пробую через RPM с сайта Яндекса..."
    RPM_URL="https://repo.yandex.ru/yandex-browser/rpm/stable/x86_64/yandex-browser-corporate.rpm"
    if command -v wget >/dev/null 2>&1; then
        wget -O /tmp/yandex-browser-corporate.rpm "$RPM_URL" || true
    elif command -v curl >/dev/null 2>&1; then
        curl -o /tmp/yandex-browser-corporate.rpm "$RPM_URL" || true
    fi
    if [[ -s /tmp/yandex-browser-corporate.rpm ]] && apt-get install -y /tmp/yandex-browser-corporate.rpm; then
        ok "Яндекс Браузер установлен из RPM"; STATUS[browser]=OK
    else
        error "Не удалось установить браузер (нужен интернет/репозиторий)"; STATUS[browser]=ERROR
    fi
fi

echo; info "Диагностика DNS-имён..."
for name in "$MOODLE" "$WIKI"; do
    res="$(getent hosts "$name" 2>/dev/null | awk '{print $1}' | head -n1)"
    if [[ -n "$res" ]]; then
        ok "DNS: $name → $res"
    else
        warn "DNS: $name не резолвится — проверьте DNS на HQ-SRV"
    fi
done

echo; info "Проверка HTTP-доступности через обратный прокси..."
check_http() {
    local url="$1" code
    code="$(curl -s -o /dev/null -w '%{http_code}' -L "$url" 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
        ok "$url → HTTP $code"; return 0
    else
        warn "$url → HTTP $code"; return 1
    fi
}
if check_http "http://${MOODLE}/"; then STATUS[moodle]=OK; else STATUS[moodle]=ERROR; fi
if check_http "http://${WIKI}/"; then STATUS[wiki]=OK; else STATUS[wiki]=ERROR; fi

echo
echo "============================================================"
echo "  Итог — Билет №12"
echo "============================================================"
for k in browser moodle wiki; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Откройте в браузере http://${MOODLE} и http://${WIKI}"
