#!/bin/bash
# =============================================================================
# Минимальная настройка HQ-SRV — Билет №10
# Запускает Apache (apache2 / httpd2) на порту 80, чтобы nginx на HQ-RTR
# мог проксировать запросы moodle.au-team.irpo → HQ-SRV:80
#
# Поддерживает: Debian/Ubuntu (apache2) и ALT Linux (httpd2)
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

# ── Определяем пакетный менеджер и имя пакета/сервиса ────────────
if command -v apt-get >/dev/null 2>&1; then
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y"
elif command -v apt-rpm >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
    # ALT Linux использует apt-get тоже, но на всякий случай
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y"
else
    warn "Неизвестный пакетный менеджер — попробую apt-get"
    PKG_UPDATE="apt-get update -y"
    PKG_INSTALL="apt-get install -y"
fi

# Определяем имя пакета и сервиса Apache
# ALT Linux: пакет apache2, сервис httpd2
# Debian/Ubuntu: пакет apache2, сервис apache2
if systemctl list-unit-files 2>/dev/null | grep -q "^httpd2"; then
    APACHE_SVC="httpd2"
    APACHE_PKG="apache2"
    info "Обнаружен ALT Linux — используем httpd2"
elif systemctl list-unit-files 2>/dev/null | grep -q "^apache2"; then
    APACHE_SVC="apache2"
    APACHE_PKG="apache2"
    info "Используем apache2"
else
    # Пробуем определить по наличию пакета после установки
    APACHE_SVC=""
    APACHE_PKG="apache2"
    info "Сервис Apache не найден — попробую установить и определить"
fi

# ── Установка Apache ──────────────────────────────────────────────
info "Обновляю список пакетов..."
$PKG_UPDATE

info "Устанавливаю ${APACHE_PKG}..."
$PKG_INSTALL "$APACHE_PKG" || { fail "Не удалось установить ${APACHE_PKG}"; exit 1; }
ok "${APACHE_PKG} установлен"

# Переопределяем имя сервиса после установки если не определили ранее
if [[ -z "$APACHE_SVC" ]]; then
    if systemctl list-unit-files 2>/dev/null | grep -q "^httpd2"; then
        APACHE_SVC="httpd2"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^apache2"; then
        APACHE_SVC="apache2"
    else
        fail "Не удалось определить имя сервиса Apache (httpd2/apache2)"
        exit 1
    fi
fi

info "Имя сервиса: ${APACHE_SVC}"

# ── Запуск ───────────────────────────────────────────────────────
info "Запускаю ${APACHE_SVC}..."
systemctl enable "$APACHE_SVC"
systemctl restart "$APACHE_SVC"
ok "${APACHE_SVC} запущен"

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
