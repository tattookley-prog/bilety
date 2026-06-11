#!/bin/bash
# =============================================================================
# Билет №10 — Обратный прокси nginx
# moodle.au-team.irpo → Moodle на HQ-SRV (Apache :8081, Alias /moodle)
# wiki.au-team.irpo   → MediaWiki на BR-SRV:8080
# Передаёт Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto.
#
# v2:
#   - сам освобождает порт 80, если его держит Apache (httpd2/apache2):
#     комментирует «Listen 80» (и «Listen *:80» / «Listen 0.0.0.0:80»)
#     во всех конфигах /etc/httpd2 и /etc/apache2 (резервные копии .bak),
#     перезапускает Apache — Moodle остаётся на :8081;
#   - проверяет, что порт 80 слушает именно nginx, при ошибке показывает журнал;
#   - для moodle корень / отвечает 302 → /moodle/ (Apache отдаёт Moodle по Alias);
#   - в конце сам проверяет ответы moodle/wiki через прокси (curl).
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
echo "  Билет №10 — nginx reverse proxy"
echo "============================================================"
echo
read -rp "Имя для Moodle [moodle.au-team.irpo]: " MOODLE_NAME; MOODLE_NAME="${MOODLE_NAME:-moodle.au-team.irpo}"
read -rp "Upstream Moodle (HQ-SRV) [192.168.1.2]: " MOODLE_UP; MOODLE_UP="${MOODLE_UP:-192.168.1.2}"
read -rp "Порт Moodle upstream [8081]: " MOODLE_PORT; MOODLE_PORT="${MOODLE_PORT:-8081}"
read -rp "Имя для Wiki [wiki.au-team.irpo]: " WIKI_NAME; WIKI_NAME="${WIKI_NAME:-wiki.au-team.irpo}"
read -rp "Upstream MediaWiki (BR-SRV) [192.168.3.2]: " WIKI_UP; WIKI_UP="${WIKI_UP:-192.168.3.2}"
read -rp "Порт MediaWiki upstream [8080]: " WIKI_PORT; WIKI_PORT="${WIKI_PORT:-8080}"

echo
info "$MOODLE_NAME → ${MOODLE_UP}:${MOODLE_PORT};  $WIKI_NAME → ${WIKI_UP}:${WIKI_PORT}"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Установка nginx..."
if ! command -v nginx >/dev/null 2>&1; then
    info "Обновляю список пакетов..."
    apt-get update -y
    info "Устанавливаю nginx..."
    apt-get install -y nginx || warn "Проверьте пакет nginx"
fi
command -v nginx >/dev/null 2>&1 && { ok "nginx доступен"; STATUS[install]=OK; } || STATUS[install]=ERROR

# ─── Освобождение порта 80 (обычно его держит Apache с Moodle, билет 8) ──────
# Кто слушает порт 80 (колонка 4 у ss — локальный адрес вида *:80 / 0.0.0.0:80)
port80_listeners() { ss -tlnp 2>/dev/null | awk '$4 ~ /[:.]80$/'; }

free_port_80() {
    local listeners files f main_conf
    local LISTEN80_RE='^[[:space:]]*Listen[[:space:]]+([^[:space:]]+:)?80[[:space:]]*$'

    listeners="$(port80_listeners)"
    if [[ -z "$listeners" ]]; then
        ok "Порт 80 свободен"
        STATUS[port80]=OK
        return 0
    fi

    if echo "$listeners" | grep -q nginx; then
        ok "Порт 80 уже занят самим nginx"
        STATUS[port80]=OK
        return 0
    fi

    if ! echo "$listeners" | grep -Eq 'httpd|apache'; then
        warn "Порт 80 занят НЕ Apache и не nginx:"
        echo "$listeners"
        warn "Освободите порт вручную, затем: systemctl restart nginx"
        STATUS[port80]=ERROR
        return 0
    fi

    warn "Порт 80 занят Apache — комментирую «Listen 80», Moodle остаётся на :8081"

    files="$(grep -rlE "$LISTEN80_RE" /etc/httpd2 /etc/apache2 2>/dev/null || true)"
    if [[ -z "$files" ]]; then
        warn "Строка «Listen 80» не найдена в /etc/httpd2 и /etc/apache2."
        warn "Найдите её вручную: grep -rnE 'Listen' /etc/httpd2 /etc/apache2"
    fi
    for f in $files; do
        cp -n "$f" "${f}.bak" 2>/dev/null || true
        sed -riE "s|$LISTEN80_RE|#Listen 80  # отключено билетом 10: порт 80 занимает nginx|" "$f"
        ok "Закомментирован Listen 80 в $f (копия: ${f}.bak)"
    done

    # Страховка: у Apache должен остаться хотя бы один Listen (Moodle на 8081)
    main_conf=""
    [[ -f /etc/httpd2/conf/httpd2.conf ]] && main_conf="/etc/httpd2/conf/httpd2.conf"
    [[ -z "$main_conf" && -f /etc/apache2/ports.conf ]] && main_conf="/etc/apache2/ports.conf"
    if [[ -n "$main_conf" ]] && \
       ! grep -rEq '^[[:space:]]*Listen[[:space:]]+' /etc/httpd2 /etc/apache2 2>/dev/null; then
        echo "Listen 8081" >> "$main_conf"
        warn "У Apache не осталось ни одного Listen — добавлен «Listen 8081» в $main_conf"
    fi

    info "Перезапускаю Apache..."
    systemctl restart httpd2 2>/dev/null || systemctl restart apache2 2>/dev/null || true
    sleep 1

    if port80_listeners | grep -Eq 'httpd|apache'; then
        error "Apache всё ещё слушает порт 80!"
        error "Смотрите: grep -rnE '^[[:space:]]*Listen' /etc/httpd2 /etc/apache2"
        STATUS[port80]=ERROR
    else
        ok "Порт 80 освобождён, Apache работает на своих портах (:8081)"
        STATUS[port80]=OK
    fi
    return 0
}

free_port_80

# ─── Конфиг nginx ────────────────────────────────────────────────────────────
# Каталог конфигов (Альт: /etc/nginx/sites-available.d или conf.d)
CONF_DIR="/etc/nginx/sites-available.d"
[[ -d /etc/nginx/sites-available ]] && CONF_DIR="/etc/nginx/sites-available"
[[ -d /etc/nginx/conf.d ]] && CONF_DIR="/etc/nginx/conf.d"
mkdir -p "$CONF_DIR"
CONF="${CONF_DIR}/reverse-proxy.conf"

info "Генерирую $CONF..."
cat > "$CONF" <<EOF
# Обратный прокси (Билет №10)

server {
    listen 80;
    server_name ${MOODLE_NAME};

    # Moodle живёт на upstream по Alias /moodle — корень сразу ведёт туда
    location = / {
        return 302 /moodle/;
    }

    location / {
        proxy_pass http://${MOODLE_UP}:${MOODLE_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}

server {
    listen 80;
    server_name ${WIKI_NAME};

    location / {
        proxy_pass http://${WIKI_UP}:${WIKI_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ok "Конфиг $CONF создан"
STATUS[config]=OK

# Включаем сайт, если используется sites-enabled.d
if [[ -d /etc/nginx/sites-enabled.d ]]; then
    ln -sf "$CONF" /etc/nginx/sites-enabled.d/reverse-proxy.conf 2>/dev/null || true
elif [[ -d /etc/nginx/sites-enabled ]]; then
    ln -sf "$CONF" /etc/nginx/sites-enabled/reverse-proxy.conf 2>/dev/null || true
fi

info "Проверка конфига nginx..."
if nginx -t; then
    ok "Конфиг nginx валиден"
else
    warn "nginx -t выдал ошибки — проверьте вручную"
fi

# ─── Запуск nginx ────────────────────────────────────────────────────────────
info "Запуск nginx..."
systemctl enable nginx 2>/dev/null || true
if systemctl restart nginx 2>/dev/null; then
    ok "nginx запущен"; STATUS[service]=OK
else
    error "Не удалось запустить nginx. Последние строки журнала:"
    journalctl -u nginx -n 12 --no-pager 2>/dev/null || true
    STATUS[service]=ERROR
fi

# Порт 80 должен слушать именно nginx
if port80_listeners | grep -q nginx; then
    ok "Порт 80 слушает nginx"
    STATUS[port80]=OK
else
    warn "Порт 80 слушает не nginx:"
    port80_listeners || true
    STATUS[port80]=ERROR
fi

# ─── Самопроверка через curl (как в check_all.sh) ────────────────────────────
check_proxy() {
    local host="$1" code
    code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${host}" --max-time 10 http://127.0.0.1/ 2>/dev/null || echo 000)"
    if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
        ok "$host через прокси → HTTP $code"
        return 0
    else
        warn "$host через прокси → HTTP $code (проверьте upstream)"
        return 1
    fi
}

echo
if command -v curl >/dev/null 2>&1; then
    info "Самопроверка прокси (curl с Host-заголовком на 127.0.0.1)..."
    if check_proxy "$MOODLE_NAME"; then STATUS[moodle]=OK; else STATUS[moodle]=ERROR; fi
    if check_proxy "$WIKI_NAME";   then STATUS[wiki]=OK;   else STATUS[wiki]=ERROR;   fi
else
    warn "curl не установлен — самопроверка пропущена"
    STATUS[moodle]=SKIP; STATUS[wiki]=SKIP
fi

echo; info "Проверка с HQ-CLI (при настроенном DNS, билет 12):"
echo "  curl -H 'Host: ${MOODLE_NAME}' http://<IP прокси>/   # ждём 302 → /moodle/"
echo "  curl -H 'Host: ${WIKI_NAME}'   http://<IP прокси>/   # ждём 200/301"

# ─── Итог ────────────────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог — Билет №10"
echo "============================================================"
for k in install port80 config service moodle wiki; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"

MY_IP="$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || true)"
MY_IP="${MY_IP:-<IP этой машины>}"
echo
info "A-записи DNS на BR-SRV должны указывать на ЭТУ машину (${MY_IP}):"
echo "  samba-tool dns add 127.0.0.1 au-team.irpo moodle A ${MY_IP} -U administrator"
echo "  samba-tool dns add 127.0.0.1 au-team.irpo wiki   A ${MY_IP} -U administrator"
echo "  (или запустите ticket12_dns_add_records.sh на BR-SRV и укажите ${MY_IP})"
ok "Готово."

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
nginx -t                                                               # Проверка синтаксиса nginx-конфига
systemctl is-active nginx                                              # Статус службы nginx
ss -tlnp | grep ':80'                                                  # Порт 80 слушает nginx
curl -I -H 'Host: moodle.au-team.irpo' http://127.0.0.1/              # Ожидаем 302 на /moodle/
curl -I -H 'Host: wiki.au-team.irpo' http://127.0.0.1/                # Ожидаем 200/301 для wiki
cat /etc/nginx/conf.d/reverse-proxy.conf                               # Конфиг reverse proxy (или sites-available)
EOF
