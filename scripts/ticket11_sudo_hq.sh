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

read -rp "Доменная группа [hq]: " GRP
GRP="${GRP:-hq}"

read -rp "NetBIOS-имя домена (Enter — без домена, локальная группа) []: " DOM

# Автоопределение реальных путей команд
resolve_cmd() {
    command -v "$1" 2>/dev/null || echo "/usr/bin/$1"
}
DEFAULT_CAT="$(resolve_cmd cat)"
DEFAULT_GREP="$(resolve_cmd grep)"
DEFAULT_ID="$(resolve_cmd id)"
DEFAULT_CMDS="${DEFAULT_CAT}, ${DEFAULT_GREP}, ${DEFAULT_ID}"

read -rp "Разрешённые команды [${DEFAULT_CMDS}]: " CMDS
CMDS="${CMDS:-${DEFAULT_CMDS}}"

# Формирование имени группы в sudoers
if [[ -n "$DOM" ]]; then
    SUDO_GROUP="%${DOM}\\${GRP}"
    DISPLAY_GROUP="${DOM}\\${GRP}"
else
    SUDO_GROUP="%${GRP}"
    DISPLAY_GROUP="${GRP}"
fi

echo
info "Группа в sudoers: ${SUDO_GROUP}"
info "Разрешённые команды: ${CMDS}"
read -rp "Продолжить? [y/N]: " C
[[ "${C,,}" =~ ^y ]] || exit 0

SUDO_FILE="/etc/sudoers.d/${GRP}"
mkdir -p /etc/sudoers.d

# Убедиться что /etc/sudoers включает директорию
if [[ -f /etc/sudoers ]] && ! grep -qE '^#?includedir /etc/sudoers.d' /etc/sudoers; then
    echo '#includedir /etc/sudoers.d' >> /etc/sudoers
    info "Добавлен #includedir /etc/sudoers.d в /etc/sudoers"
fi

info "Запись ${SUDO_FILE}..."

printf '# Билет №11 — повышение привилегий только для cat, grep, id\nCmnd_Alias HQ_ALLOWED = %s\n%s ALL=(ALL) NOPASSWD: HQ_ALLOWED\n' \
    "${CMDS}" "${SUDO_GROUP}" > "${SUDO_FILE}"

chmod 440 "${SUDO_FILE}"
ok "Правило sudo записано в ${SUDO_FILE}"

info "Содержимое файла:"
cat "${SUDO_FILE}"
echo

# Проверка синтаксиса — только нашего файла, с таймаутом 10с
info "Проверка синтаксиса файла (visudo -c -f)..."
if timeout 10 visudo -c -f "${SUDO_FILE}" >/dev/null 2>&1; then
    ok "Синтаксис файла корректен"
    STATUS[sudoers]=OK
else
    VSOUT="$(timeout 10 visudo -c -f "${SUDO_FILE}" 2>&1 || true)"
    if [[ -z "$VSOUT" ]]; then
        # visudo не поддерживает -f или завис — делаем базовую проверку сами
        warn "visudo -c -f недоступен, проверяю структуру вручную..."
        if grep -qE '^Cmnd_Alias' "${SUDO_FILE}" && grep -qE '^%' "${SUDO_FILE}"; then
            ok "Структура файла выглядит корректной"
            STATUS[sudoers]=OK
        else
            error "Файл выглядит некорректным"; STATUS[sudoers]=ERROR
        fi
    else
        error "Ошибка синтаксиса: ${VSOUT}"
        error "Удаляю файл ${SUDO_FILE}"
        rm -f "${SUDO_FILE}"
        STATUS[sudoers]=ERROR
    fi
fi

echo
info "Проверка под доменным пользователем (примеры):"
echo "  Разрешено:  sudo cat /etc/hostname"
echo "              sudo id"
echo "              sudo grep root /etc/passwd"
echo "  Запрещено:  sudo systemctl restart sshd   → Sorry, user ... is not allowed"
echo
warn "Проверьте на HQ-CLI: su - user1hq, затем sudo id и sudo systemctl status"

echo
echo "============================================================"
echo "  Итог — Билет №11"
echo "============================================================"
for k in sudoers; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k" ;;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k" ;;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k" ;;
    esac
done
echo "============================================================"
ok "Готово. Файл: ${SUDO_FILE}"
