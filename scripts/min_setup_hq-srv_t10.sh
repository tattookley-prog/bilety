#!/bin/bash
# =============================================================================
# Минимальная настройка HQ-SRV — Билет №10
# Запускает Apache2 на порту 80, чтобы nginx на HQ-RTR мог проксировать
# запросы moodle.au-team.irpo → HQ-SRV:80
#
# Запуск: sudo bash scripts/min_setup_hq-srv_t10.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "Запуск только от root (sudo)"; exit 1; }

echo
echo "============================================================"
echo "  Минимальная настройка HQ-SRV для Билета №10"
echo "============================================================"
echo

# ── Установка Apache2 ────────────────────────────────────────────
info "Обновляю список пакетов..."
apt-get update -y
info "Устанавливаю Apache2..."
apt-get install -y apache2 || { fail "Не удалось установить apache2"; exit 1; }
ok "Apache2 установлен"

# ── Запуск ───────────────────────────────────────────────────────
info "Запускаю Apache2..."
systemctl enable apache2
systemctl restart apache2
ok "Apache2 запущен"

# ── Проверка ─────────────────────────────────────────────────────
info "Проверяю ответ на порту 80..."
sleep 1
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
if echo "$CODE" | grep -Eq "^(200|301|302|303)$"; then
    ok "Apache2 отвечает на порту 80 (HTTP $CODE)"
else
    fail "Apache2 не отвечает корректно (HTTP $CODE)"
fi

echo
echo "============================================================"
echo "  Готово. HQ-SRV слушает на порту 80."
echo "  Теперь на HQ-RTR запустите check_all.sh → билет 10."
echo "============================================================"
