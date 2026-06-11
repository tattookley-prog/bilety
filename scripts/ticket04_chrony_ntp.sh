#!/bin/bash
# =============================================================================
# Билет №4 — Сервер времени NTP (chrony)
# Сервер:  HQ-RTR — local stratum 5, отдаёт время в сеть
# Клиенты: HQ-SRV, HQ-CLI, BR-RTR, BR-SRV — синхронизация с HQ-RTR
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

declare -A STATUS
CONF="/etc/chrony.conf"
[[ -f /etc/chrony/chrony.conf ]] && CONF="/etc/chrony/chrony.conf"

echo
echo "============================================================"
echo "  Билет №4 — NTP (chrony)"
echo "============================================================"
echo
echo "Роль узла:"
echo "  1) HQ-RTR — сервер времени (stratum 5)"
echo "  2) Клиент времени (HQ-SRV / HQ-CLI / BR-RTR / BR-SRV)"
read -rp "Выбор [1]: " ROLE; ROLE="${ROLE:-1}"

info "Установка chrony..."
if ! command -v chronyd >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y chrony || warn "Проверьте пакет chrony вручную"
fi
command -v chronyd >/dev/null 2>&1 && { ok "chrony доступен"; STATUS[install]=OK; } || STATUS[install]=ERROR
cp -f "$CONF" "${CONF}.bak" 2>/dev/null || true

if [[ "$ROLE" == "1" ]]; then
    read -rp "Сеть, которой разрешить синхронизацию [192.168.0.0/16]: " NET; NET="${NET:-192.168.0.0/16}"
    read -rp "GRE-туннельная сеть (BR-RTR через gre1) [10.0.0.0/30]: " TUN; TUN="${TUN:-10.0.0.0/30}"
    read -rp "Stratum [5]: " ST; ST="${ST:-5}"
    echo
    info "HQ-RTR: local stratum $ST, allow $NET, allow $TUN (GRE)"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    cat > "$CONF" <<EOF
# chrony — сервер времени HQ-RTR (Билет №4)
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync

# Локальный источник времени без выхода в интернет
local stratum ${ST}
manual

# Разрешаем клиентам синхронизироваться
allow ${NET}
# GRE-туннельная сеть (BR-RTR подключается через gre1, src=10.0.0.2)
allow ${TUN}
EOF
    ok "$CONF записан (сервер, stratum $ST, allow $NET + $TUN)"
    STATUS[config]=OK
else
    read -rp "IP сервера времени (HQ-RTR) [192.168.1.1]: " SRV; SRV="${SRV:-192.168.1.1}"
    echo
    info "Клиент: server $SRV iburst"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    cat > "$CONF" <<EOF
# chrony — клиент времени (Билет №4)
driftfile /var/lib/chrony/drift
makestep 1.0 3
rtcsync

server ${SRV} iburst
EOF
    ok "$CONF записан (клиент → $SRV)"
    STATUS[config]=OK
fi

info "Перезапуск chronyd..."
if systemctl enable --now chronyd 2>/dev/null && systemctl restart chronyd 2>/dev/null; then
    ok "chronyd запущен"; STATUS[service]=OK
else
    error "Не удалось запустить chronyd"; STATUS[service]=ERROR
fi

sleep 2
echo; info "Источники времени:"
chronyc sources -v 2>/dev/null || true
echo; info "Трекинг:"
chronyc tracking 2>/dev/null | head -n 5 || true

echo
echo "============================================================"
echo "  Итог — Билет №4"
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
ok "Готово. Проверка на клиенте: chronyc sources"

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
systemctl is-active chronyd                           # Служба chrony активна
chronyc sources -v                                    # Источники времени и их состояние
chronyc tracking                                      # Синхронизация, stratum, offset

[HQ-RTR | NTP сервер]
chronyc clients                                       # Какие клиенты синхронизируются
grep -E 'local|allow' /etc/chrony.conf               # local stratum и разрешённые сети

[Клиент времени]
grep '^server' /etc/chrony.conf                       # На какой NTP-сервер смотрит клиент
timedatectl                                           # Общий статус времени/NTP
EOF
