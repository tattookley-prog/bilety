#!/bin/bash
# =============================================================================
# Минимальная настройка HQ-SRV — Билет №10
# Запускает Apache (httpd2 / apache2) на порту 80, чтобы nginx на HQ-RTR
# мог проксировать запросы moodle.au-team.irpo → HQ-SRV:80
#
# Поддерживает: ALT Linux (httpd2) и Debian/Ubuntu (apache2)
# Логика взята из ticket08_moodle.sh
# Запуск: sudo bash scripts/min_setup_hq-srv_t10.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "Запуск только от root (sudo)"; exit 1; }

echo
echo "============================================================"
echo "  Минимальная настройка HQ-SRV для Билета №10"
echo "============================================================"
echo

# ── Установка Apache ──────────────────────────────────────────────
# На ALT Linux: пакет apache2, сервис httpd2
# На Debian/Ubuntu: пакет apache2, сервис apache2
info "Обновляю список пакетов..."
apt-get update -y

info "Устанавливаю apache2..."
# Порядок как в ticket08: сначала httpd2 (ALT), затем apache2 (Debian)
if apt-get install -y httpd2 2>/dev/null; then
    ok "Установлено: httpd2 (ALT Linux)"
elif apt-get install -y apache2 2>/dev/null; then
    ok "Установлено: apache2"
else
    fail "Не удалось установить Apache — проверьте репозитории"
    exit 1
fi

# ── Запуск — пробуем httpd2 и apache2 (как в ticket08) ───────────
info "Запускаю Apache..."
APACHE_SVC=""
for svc in httpd2 apache2; do
    if systemctl enable --now "$svc" 2>/dev/null && systemctl restart "$svc" 2>/dev/null; then
        ok "$svc запущен"
        APACHE_SVC="$svc"
        break
    fi
done

if [[ -z "$APACHE_SVC" ]]; then
    fail "Не удалось запустить ни httpd2, ни apache2"
    warn "Попробуйте вручную: systemctl status httpd2 или systemctl status apache2"
    exit 1
fi

# ── ServerName — убираем предупреждения AH00557 / AH00558 ─────────
FQDN="hq-srv.au-team.irpo"
if [[ -d /etc/httpd2/conf/sites-available ]]; then
    info "Задаю ServerName ($FQDN)..."
    echo "ServerName $FQDN" > /etc/httpd2/conf/sites-available/000-servername.conf
    ln -sf /etc/httpd2/conf/sites-available/000-servername.conf \
           /etc/httpd2/conf/sites-enabled/000-servername.conf
    grep -q "$FQDN" /etc/hosts || echo "127.0.0.1   $FQDN hq-srv" >> /etc/hosts
    systemctl reload "$APACHE_SVC" 2>/dev/null || true
    ok "ServerName задан: $FQDN"
fi

# ── Индексная страница — устраняем HTTP 403 ───────────────────────
WEBROOT="/var/www/html"
info "Создаю индексную страницу в $WEBROOT..."
mkdir -p "$WEBROOT"
if [[ ! -f "$WEBROOT/index.html" ]]; then
    echo "<h1>HQ-SRV OK - Bilet 10</h1>" > "$WEBROOT/index.html"
fi
chmod 644 "$WEBROOT/index.html"
ok "Индексная страница готова: $WEBROOT/index.html"

# ── Проверка ─────────────────────────────────────────────────────
info "Проверяю ответ на порту 80..."
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
if echo "$CODE" | grep -Eq "^(200|301|302|303)$"; then
    ok "Apache отвечает на порту 80 (HTTP $CODE)"
else
    fail "Apache не отвечает корректно (HTTP $CODE)"
    warn "Проверьте статус: systemctl status ${APACHE_SVC}"
fi

echo
echo "============================================================"
echo "  Готово. HQ-SRV слушает на порту 80 (сервис: ${APACHE_SVC})."
echo "  Теперь на HQ-RTR запустите check_all.sh → билет 10."
echo "============================================================"
