#!/bin/bash
# =============================================================================
# Билет №7 — Статический проброс портов (DNAT)
# HQ-RTR: TCP 2024 → HQ-SRV:2024
# BR-RTR: TCP 2024 → BR-SRV:2024  и  внешний TCP 80 → BR-SRV:8080 (MediaWiki)
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
echo "  Билет №7 — Проброс портов (DNAT)"
echo "============================================================"
echo
echo "Где выполняется настройка?"
echo "  1) HQ-RTR — проброс 2024 → HQ-SRV:2024"
echo "  2) BR-RTR — проброс 2024 → BR-SRV:2024 и 80 → BR-SRV:8080"
read -rp "Выбор [1]: " ROLE; ROLE="${ROLE:-1}"

read -rp "Внешний (WAN) интерфейс роутера [ens18]: " WAN; WAN="${WAN:-ens18}"

ensure_persist() {
    # Сохраняем правила iptables для автозагрузки
    mkdir -p /etc/iptables 2>/dev/null || true
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
    cat > /etc/systemd/system/iptables-restore.service <<'EOF'
[Unit]
Description=Restore iptables rules
Before=network-pre.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables-restore < /etc/iptables/rules.v4'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable iptables-restore.service 2>/dev/null || true
}

info "Включаю ip_forward..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf 2>/dev/null || true
echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
ok "ip_forward = 1"

if [[ "$ROLE" == "1" ]]; then
    read -rp "IP HQ-SRV [192.168.1.2]: " SRV; SRV="${SRV:-192.168.1.2}"
    read -rp "Порт SSH (пробрасываемый) [2024]: " P; P="${P:-2024}"

    echo; info "HQ-RTR: TCP $P (на $WAN) → ${SRV}:${P}"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    iptables -t nat -A PREROUTING -i "$WAN" -p tcp --dport "$P" -j DNAT --to-destination "${SRV}:${P}"
    iptables -A FORWARD -p tcp -d "$SRV" --dport "$P" -j ACCEPT
    iptables -t nat -A POSTROUTING -p tcp -d "$SRV" --dport "$P" -j MASQUERADE
    ok "Проброс TCP $P → ${SRV}:${P} настроен"
    STATUS[ssh_fwd]=OK
else
    read -rp "IP BR-SRV [192.168.3.2]: " SRV; SRV="${SRV:-192.168.3.2}"
    read -rp "Порт SSH (пробрасываемый) [2024]: " P; P="${P:-2024}"
    read -rp "Внешний HTTP-порт [80]: " WP; WP="${WP:-80}"
    read -rp "Порт MediaWiki на BR-SRV [8080]: " WIKI; WIKI="${WIKI:-8080}"

    echo; info "BR-RTR: TCP $P → ${SRV}:${P};  TCP $WP → ${SRV}:${WIKI}"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    # SSH проброс
    iptables -t nat -A PREROUTING -i "$WAN" -p tcp --dport "$P" -j DNAT --to-destination "${SRV}:${P}"
    iptables -A FORWARD -p tcp -d "$SRV" --dport "$P" -j ACCEPT
    iptables -t nat -A POSTROUTING -p tcp -d "$SRV" --dport "$P" -j MASQUERADE
    ok "Проброс SSH TCP $P → ${SRV}:${P}"
    STATUS[ssh_fwd]=OK

    # MediaWiki проброс 80 → 8080
    iptables -t nat -A PREROUTING -i "$WAN" -p tcp --dport "$WP" -j DNAT --to-destination "${SRV}:${WIKI}"
    iptables -A FORWARD -p tcp -d "$SRV" --dport "$WIKI" -j ACCEPT
    iptables -t nat -A POSTROUTING -p tcp -d "$SRV" --dport "$WIKI" -j MASQUERADE
    ok "Проброс HTTP TCP $WP → ${SRV}:${WIKI}"
    STATUS[web_fwd]=OK
fi

ensure_persist
ok "Правила сохранены (автозагрузка)"
STATUS[persist]=OK

echo; info "Текущие правила nat PREROUTING:"
iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null | grep -E 'DNAT|Chain' || true
echo
info "Проверка (с внешнего узла):"
echo "  ssh -p 2024 sshuser@<WAN-IP роутера>"
[[ "$ROLE" == "2" ]] && echo "  curl http://<WAN-IP BR-RTR>/   # → MediaWiki"

echo
echo "============================================================"
echo "  Итог — Билет №7"
echo "============================================================"
for k in "${!STATUS[@]}"; do
    v="${STATUS[$k]}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово."
