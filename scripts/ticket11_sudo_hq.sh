#!/bin/bash
# =============================================================================
# Билет №11 — sudo для доменной группы hq (HQ-CLI)
# Разрешить группе hq повышение привилегий только для cat, grep, id.
# Остальные команды с sudo для hq запрещены.
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
echo "  Билет №11 — sudo для группы hq (cat, grep, id)"
echo "============================================================"
echo
read -rp "Доменная группа [hq]: " GRP; GRP="${GRP:-hq}"
read -rp "NetBIOS-имя домена (для sudo, или Enter для локальной группы) [AU-TEAM]: " DOM; DOM="${DOM:-AU-TEAM}"
read -rp "Разрешённые команды [/bin/cat, /bin/grep, /usr/bin/id]: " CMDS
CMDS="${CMDS:-/bin/cat, /bin/grep, /usr/bin/id}"

# Имя группы в sudoers: для доменной — "%DOMAIN\\group" (с экранированием)
if [[ -n "$DOM" ]]; then
    SUDO_GROUP="%${DOM}\\\\${GRP}"
    DISPLAY_GROUP="${DOM}\\${GRP}"
else
    SUDO_GROUP="%${GRP}"
    DISPLAY_GROUP="${GRP}"
fi

echo
info "Группа: ${DISPLAY_GROUP}"
info "Разрешённые команды: ${CMDS}"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

SUDO_FILE="/etc/sudoers.d/${GRP}"
mkdir -p /etc/sudoers.d
chmod 750 /etc/sudoers.d
if [[ -f /etc/sudoers ]] && ! grep -qE '^#?includedir /etc/sudoers.d' /etc/sudoers; then
    echo '#includedir /etc/sudoers.d' >> /etc/sudoers
fi

info "Запись $SUDO_FILE..."
cat > "$SUDO_FILE" <<EOF
# Билет №11 — повышение привилегий только для cat, grep, id
Cmnd_Alias HQ_ALLOWED = ${CMDS}
${SUDO_GROUP} ALL=(ALL) HQ_ALLOWED
EOF
chmod 440 "$SUDO_FILE"
ok "Правило sudo записано"

info "Проверка синтаксиса (visudo -c)..."
if visudo -c >/dev/null 2>&1; then
    ok "Синтаксис sudoers корректен"; STATUS[sudoers]=OK
else
    error "Ошибка синтаксиса sudoers — удаляю файл"
    rm -f "$SUDO_FILE"
    STATUS[sudoers]=ERROR
fi

echo
info "Проверка под доменным пользователем (примеры):"
echo "  Разрешено:  sudo cat /etc/hostname"
echo "             sudo id"
echo "             sudo grep root /etc/passwd"
echo "  Запрещено:  sudo systemctl restart sshd   → Sorry, user ... is not allowed"
echo "             sudo cat /etc/shadow         (если разрешён только cat — работает)"
echo
warn "Проверьте на HQ-CLI: su - user1hq, затем sudo id и sudo systemctl status"

echo
echo "============================================================"
echo "  Итог — Билет №11"
echo "============================================================"
for k in sudoers; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Файл: ${SUDO_FILE}"
