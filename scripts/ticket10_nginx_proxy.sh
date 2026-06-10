#!/bin/bash
# =============================================================================
# Билет №10 — Обратный прокси nginx
# moodle.au-team.irpo → Moodle на HQ-SRV (HTTP)
# wiki.au-team.irpo   → MediaWiki на BR-SRV:8080
# Передаёт Host, X-Real-IP, X-Forwarded-For, X-Forwarded-Proto.
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

if systemctl enable --now nginx && systemctl restart nginx; then
    ok "nginx запущен"; STATUS[service]=OK
else
    error "Не удалось запустить nginx"; STATUS[service]=ERROR
fi

echo; info "Проверка с HQ-CLI (при настроенном DNS):"
echo "  curl -H 'Host: ${MOODLE_NAME}' http://<IP прокси>/"
echo "  curl -H 'Host: ${WIKI_NAME}'   http://<IP прокси>/"

echo
echo "============================================================"
echo "  Итог — Билет №10"
echo "============================================================"
for k in install config service; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Добавьте A-записи ${MOODLE_NAME}/${WIKI_NAME} на DNS (HQ-SRV)."

echo
info "Добавьте A-записи DNS на BR-SRV (samba-tool dns add):"
echo "  samba-tool dns add 127.0.0.1 au-team.irpo moodle A ${MOODLE_UP} -U administrator"
echo "  samba-tool dns add 127.0.0.1 au-team.irpo wiki   A ${MOODLE_UP} -U administrator"
echo "  (оба имени должны указывать на HQ-SRV, где работает nginx)"
