#!/bin/bash
# =============================================================================
# Минимальная настройка HQ-RTR — Билет №12
# Тонкая обёртка: переиспользует ticket10_nginx_proxy.sh
# (moodle.au-team.irpo -> HQ-SRV:8081, wiki.au-team.irpo -> BR-SRV:8080)
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_SCRIPT="${SCRIPT_DIR}/ticket10_nginx_proxy.sh"

echo
echo "============================================================"
echo "  Минимальная настройка HQ-RTR для Билета №12"
echo "============================================================"
echo
info "Будет запущен ${BASE_SCRIPT} с дефолтами:"
info "moodle.au-team.irpo -> 192.168.1.2:8081"
info "wiki.au-team.irpo   -> 192.168.3.2:8080"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

if [[ ! -f "$BASE_SCRIPT" ]]; then
    error "Не найден $BASE_SCRIPT"
    exit 1
fi

bash "$BASE_SCRIPT"
ok "Готово. Конфиг reverse proxy для билета 12 применён."
