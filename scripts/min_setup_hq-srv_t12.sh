#!/bin/bash
# =============================================================================
# Минимальная настройка HQ-SRV — Билет №12
# Поднимает Apache (httpd2 / apache2) на порту 8081 для moodle.au-team.irpo
# через nginx reverse proxy на HQ-RTR.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

declare -A STATUS

echo
echo "============================================================"
echo "  Минимальная настройка HQ-SRV для Билета №12"
echo "============================================================"
echo

read -rp "ServerName для Apache [hq-srv.au-team.irpo]: " FQDN; FQDN="${FQDN:-hq-srv.au-team.irpo}"
read -rp "Порт Apache для backend Moodle [8081]: " AP_PORT; AP_PORT="${AP_PORT:-8081}"
read -rp "Каталог Moodle в DocumentRoot [/var/www/html/moodle]: " MOODLE_DIR; MOODLE_DIR="${MOODLE_DIR:-/var/www/html/moodle}"

echo
info "ServerName=$FQDN, Apache порт=$AP_PORT, каталог Moodle=$MOODLE_DIR"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Обновляю список пакетов..."
apt-get update -y

info "Устанавливаю Apache..."
if apt-get install -y httpd2; then
    ok "Установлено: httpd2 (ALT Linux)"; STATUS[install]=OK
elif apt-get install -y apache2; then
    ok "Установлено: apache2"; STATUS[install]=OK
else
    fail "Не удалось установить Apache"; STATUS[install]=ERROR; exit 1
fi

info "Запускаю Apache..."
APACHE_SVC=""
for svc in httpd2 apache2; do
    if systemctl enable --now "$svc" 2>/dev/null && systemctl restart "$svc" 2>/dev/null; then
        APACHE_SVC="$svc"
        ok "$svc запущен"
        STATUS[service]=OK
        break
    fi
done
if [[ -z "$APACHE_SVC" ]]; then
    fail "Не удалось запустить ни httpd2, ни apache2"
    STATUS[service]=ERROR
    exit 1
fi

set_servername() {
    local conf=""
    if [[ -d /etc/httpd2/conf/sites-available ]]; then
        conf="/etc/httpd2/conf/sites-available/000-servername.conf"
        echo "ServerName ${FQDN}" > "$conf"
        mkdir -p /etc/httpd2/conf/sites-enabled
        ln -sf "$conf" /etc/httpd2/conf/sites-enabled/000-servername.conf
    elif [[ -d /etc/apache2/conf-available ]]; then
        conf="/etc/apache2/conf-available/000-servername.conf"
        echo "ServerName ${FQDN}" > "$conf"
        mkdir -p /etc/apache2/conf-enabled
        ln -sf "$conf" /etc/apache2/conf-enabled/000-servername.conf
    fi

    if [[ -n "$conf" ]]; then
        cp -n /etc/hosts /etc/hosts.bak 2>/dev/null || true
        grep -q "[[:space:]]${FQDN}\b" /etc/hosts || echo "127.0.0.1   ${FQDN} hq-srv" >> /etc/hosts
        ok "ServerName задан: ${FQDN}"
        STATUS[servername]=OK
    else
        warn "Не найден каталог конфигов ServerName — пропускаю"
        STATUS[servername]=SKIP
    fi
}

ensure_listen_port() {
    local port="$1" changed=0 f
    local files=(/etc/httpd2/conf/httpd2.conf /etc/apache2/ports.conf)

    for f in "${files[@]}"; do
        [[ -f "$f" ]] || continue
        cp -n "$f" "${f}.bak" 2>/dev/null || true
        if ! grep -Eq "^[[:space:]]*Listen[[:space:]]+([^[:space:]]+:)?${port}[[:space:]]*$" "$f"; then
            echo "Listen ${port}" >> "$f"
            changed=1
            ok "Добавлен Listen ${port} в $f"
        fi
    done

    if [[ $changed -eq 0 ]]; then
        ok "Listen ${port} уже настроен"
    fi
}

set_servername
ensure_listen_port "$AP_PORT"
if systemctl restart "$APACHE_SVC" 2>/dev/null; then
    ok "Apache перезапущен после настройки порта $AP_PORT"
    STATUS[listen8081]=OK
else
    fail "Не удалось перезапустить $APACHE_SVC"
    STATUS[listen8081]=ERROR
fi

WEBROOT="/var/www/html"
info "Готовлю веб-каталоги: $WEBROOT и $MOODLE_DIR"
mkdir -p "$WEBROOT" "$MOODLE_DIR"

cat > "$WEBROOT/index.html" <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><title>HQ-SRV Moodle Backend</title></head>
<body><h1>HQ-SRV OK - Bilet 12</h1><p><a href="/moodle/">Open /moodle/</a></p></body></html>
HTML

cat > "$MOODLE_DIR/index.html" <<HTML
<!doctype html>
<html><head><meta charset="utf-8"><title>Moodle Backend</title></head>
<body><h1>Moodle backend path is ready</h1></body></html>
HTML

chmod 644 "$WEBROOT/index.html" "$MOODLE_DIR/index.html"
ok "Индексные страницы созданы"
STATUS[root]=OK
STATUS[moodle]=OK

check_http() {
    local path="$1" code
    code="$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${AP_PORT}${path}" 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
        ok "HTTP ${path} на :${AP_PORT} → ${code}"
        return 0
    fi
    warn "HTTP ${path} на :${AP_PORT} → ${code}"
    return 1
}

echo
info "Проверяю ответы Apache на :${AP_PORT}..."
if ! check_http "/"; then STATUS[root]=ERROR; fi
if ! check_http "/moodle/"; then STATUS[moodle]=ERROR; fi

echo
echo "============================================================"
echo "  Итог — Билет №12 (HQ-SRV)"
echo "============================================================"
for k in install service servername listen8081 root moodle; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. HQ-SRV должен отвечать на http://<HQ-SRV>:${AP_PORT}/ и /moodle/"
