#!/bin/bash
# =============================================================================
# Билет №12 — Добавление DNS A-записей для Moodle и Wiki на BR-SRV
# Запускать на BR-SRV после поднятия Samba AD DC (ticket01).
# Добавляет записи moodle.au-team.irpo и wiki.au-team.irpo → HQ-SRV.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

echo
echo "============================================================"
echo "  Билет №12 — DNS A-записи для Moodle и Wiki (BR-SRV)"
echo "============================================================"
echo

read -rp "Зона DNS [au-team.irpo]: "             ZONE;      ZONE="${ZONE:-au-team.irpo}"
read -rp "IP HQ-SRV (куда указывают записи) [192.168.1.2]: " HQSRV_IP; HQSRV_IP="${HQSRV_IP:-192.168.1.2}"
read -rp "Пароль администратора домена [P@ssw0rd]: " ADMINPASS; ADMINPASS="${ADMINPASS:-P@ssw0rd}"

echo
info "Зона: $ZONE  →  HQ-SRV: $HQSRV_IP"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

echo
for rec in moodle wiki; do
    info "Добавляю запись: $rec.$ZONE → $HQSRV_IP"
    if samba-tool dns add 127.0.0.1 "$ZONE" "$rec" A "$HQSRV_IP" \
        -U "administrator%${ADMINPASS}" 2>/dev/null; then
        ok "$rec.$ZONE → $HQSRV_IP добавлена"
    else
        warn "$rec.$ZONE уже существует или ошибка — проверяю текущее значение:"
        samba-tool dns query 127.0.0.1 "$ZONE" "$rec" A \
            -U "administrator%${ADMINPASS}" 2>/dev/null || true
    fi
done

echo
info "Проверка записей:"
for rec in moodle wiki; do
    res="$(samba-tool dns query 127.0.0.1 "$ZONE" "$rec" A \
        -U "administrator%${ADMINPASS}" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
    if [[ -n "$res" ]]; then
        ok "DNS: $rec.$ZONE → $res"
    else
        warn "DNS: $rec.$ZONE — запись не найдена"
    fi
done

echo
echo "============================================================"
ok "Готово. Теперь на HQ-CLI должно резолвиться:"
echo "  getent hosts moodle.$ZONE"
echo "  getent hosts wiki.$ZONE"
echo "============================================================"

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
[BR-SRV | DNS в Samba AD]
samba-tool dns query 127.0.0.1 au-team.irpo moodle A -U administrator   # A-запись moodle
samba-tool dns query 127.0.0.1 au-team.irpo wiki A -U administrator     # A-запись wiki

[HQ-CLI | Проверка резолвинга]
getent hosts moodle.au-team.irpo                                         # moodle резолвится в нужный IP
getent hosts wiki.au-team.irpo                                           # wiki резолвится в нужный IP
EOF
