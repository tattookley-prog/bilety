#!/bin/bash
# =============================================================================
# Билет №5 — Ansible на BR-SRV
# Рабочий каталог /etc/ansible, инвентарь (HQ-SRV, HQ-CLI, HQ-RTR, BR-RTR),
# успешный ansible all -m ping → pong.
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
echo "  Билет №5 — Ansible (BR-SRV)"
echo "============================================================"
echo
read -rp "IP HQ-SRV  [192.168.1.2]: " IP_HQ_SRV; IP_HQ_SRV="${IP_HQ_SRV:-192.168.1.2}"
read -rp "IP HQ-CLI  [192.168.2.2]: " IP_HQ_CLI; IP_HQ_CLI="${IP_HQ_CLI:-192.168.2.2}"
read -rp "IP HQ-RTR  [192.168.1.1]: " IP_HQ_RTR; IP_HQ_RTR="${IP_HQ_RTR:-192.168.1.1}"
read -rp "IP BR-RTR  [192.168.3.1]: " IP_BR_RTR; IP_BR_RTR="${IP_BR_RTR:-192.168.3.1}"
read -rp "SSH-пользователь серверов [sshuser]: " SRV_USER; SRV_USER="${SRV_USER:-sshuser}"
read -rp "SSH-порт серверов [2026]: " SRV_PORT; SRV_PORT="${SRV_PORT:-2026}"
read -rp "SSH-пользователь роутеров [net_admin]: " RTR_USER; RTR_USER="${RTR_USER:-net_admin}"
read -rp "SSH-порт роутеров [22]: " RTR_PORT; RTR_PORT="${RTR_PORT:-22}"

echo
info "Инвентарь: hq-srv=$IP_HQ_SRV hq-cli=$IP_HQ_CLI hq-rtr=$IP_HQ_RTR br-rtr=$IP_BR_RTR"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

# ── Установка Ansible ────────────────────────────────────────────────────────
info "Установка Ansible и sshpass..."
apt-get update -y >/dev/null 2>&1 || true
if apt-get install -y ansible sshpass >/dev/null 2>&1; then
    ok "ansible установлен"; STATUS[install]=OK
else
    error "Не удалось установить ansible"; STATUS[install]=ERROR
fi

# ── Конфиг и инвентарь ──────────────────────────────────────────────────────
info "Создаю /etc/ansible..."
mkdir -p /etc/ansible
cp -f /etc/ansible/ansible.cfg /etc/ansible/ansible.cfg.bak 2>/dev/null || true
cp -f /etc/ansible/hosts /etc/ansible/hosts.bak 2>/dev/null || true

cat > /etc/ansible/ansible.cfg <<EOF
[defaults]
inventory = /etc/ansible/hosts
host_key_checking = False
retry_files_enabled = False
deprecation_warnings = False
EOF

cat > /etc/ansible/hosts <<EOF
[hq]
hq-srv ansible_host=${IP_HQ_SRV} ansible_user=${SRV_USER} ansible_port=${SRV_PORT}
hq-cli ansible_host=${IP_HQ_CLI} ansible_user=${SRV_USER} ansible_port=${SRV_PORT}

[routers]
hq-rtr ansible_host=${IP_HQ_RTR} ansible_user=${RTR_USER} ansible_port=${RTR_PORT}
br-rtr ansible_host=${IP_BR_RTR} ansible_user=${RTR_USER} ansible_port=${RTR_PORT}

[all:vars]
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
ansible_python_interpreter=auto_silent
EOF
ok "Инвентарь /etc/ansible/hosts создан"
STATUS[inventory]=OK

# ── SSH-ключ ─────────────────────────────────────────────────────────────────
echo
info "Проверка SSH-ключа root..."
if [[ ! -f /root/.ssh/id_rsa ]]; then
    info "Ключ не найден — генерирую /root/.ssh/id_rsa..."
    ssh-keygen -t rsa -N '' -f /root/.ssh/id_rsa
    ok "Ключ сгенерирован"
else
    ok "Ключ уже существует: /root/.ssh/id_rsa"
fi

# ── Копирование ключей ────────────────────────────────────────────────────────
echo
info "Копирование ключа на все узлы (потребуется ввод пароля для каждого хоста)..."
echo

for entry in \
    "${SRV_PORT}:${SRV_USER}:${IP_HQ_SRV}:hq-srv" \
    "${SRV_PORT}:${SRV_USER}:${IP_HQ_CLI}:hq-cli" \
    "${RTR_PORT}:${RTR_USER}:${IP_HQ_RTR}:hq-rtr" \
    "${RTR_PORT}:${RTR_USER}:${IP_BR_RTR}:br-rtr"; do

    IFS=':' read -r port user ip name <<< "$entry"
    info "ssh-copy-id → $name ($user@$ip:$port)"
    if ssh-copy-id -o StrictHostKeyChecking=no -p "$port" "${user}@${ip}"; then
        ok "Ключ скопирован на $name"
    else
        warn "Не удалось скопировать ключ на $name — проверьте пароль и доступность"
    fi
    echo
done

# ── Проверка ping ─────────────────────────────────────────────────────────────
info "Проверка: ansible all -m ping"
if ansible all -m ping 2>/dev/null | grep -q 'pong'; then
    ok "Получен pong от узлов"; STATUS[ping]=OK
else
    warn "pong не получен — проверьте SSH-доступ и повторите: ansible all -m ping"
    STATUS[ping]=ERROR
fi

echo
echo "============================================================"
echo "  Итог — Билет №5"
echo "============================================================"
for k in install inventory ping; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Команда проверки: ansible all -m ping"
