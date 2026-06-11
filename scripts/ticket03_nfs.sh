#!/bin/bash
# =============================================================================
# Билет №3 — NFS
# Сервер: HQ-SRV — общий каталог /raid5/nfs (rw для сети HQ-CLI)
# Клиент: HQ-CLI — автомонтирование в /mnt/nfs
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
echo "  Билет №3 — NFS"
echo "============================================================"
echo
echo "Где выполняется настройка?"
echo "  1) HQ-SRV — NFS-сервер (экспорт /raid5/nfs)"
echo "  2) HQ-CLI — клиент (монтирование /mnt/nfs)"
read -rp "Выбор [1]: " ROLE; ROLE="${ROLE:-1}"

if [[ "$ROLE" == "1" ]]; then
    # ──────────────────────────── HQ-SRV ────────────────────────────────────
    read -rp "Экспортируемый каталог [/raid5/nfs]: " EXP; EXP="${EXP:-/raid5/nfs}"
    read -rp "Сеть HQ-CLI (CIDR) [192.168.2.0/27]: " NET; NET="${NET:-192.168.2.0/27}"

    echo
    info "Экспорт $EXP → $NET (rw,sync,no_subtree_check)"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    info "Установка nfs-server (nfs-utils)..."
    apt-get update -y || true
    apt-get install -y nfs-server || apt-get install -y nfs-utils || warn "Проверьте пакет NFS"

    mkdir -p "$EXP"
    chown nobody:nobody "$EXP" 2>/dev/null || chown nfsnobody:nfsnobody "$EXP" 2>/dev/null || true
    chmod 0777 "$EXP"
    ok "Каталог $EXP готов"

    info "Запись /etc/exports..."
    cp -f /etc/exports /etc/exports.bak 2>/dev/null || true
    sed -i "\|^$EXP[[:space:]]|d" /etc/exports 2>/dev/null || true
    echo "$EXP $NET(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    ok "/etc/exports обновлён"

    info "Запуск служб NFS..."
    systemctl enable --now rpcbind 2>/dev/null || true
    if systemctl enable --now nfs-server 2>/dev/null || systemctl enable --now nfs 2>/dev/null; then
        ok "NFS-сервер запущен"; STATUS[service]=OK
    else
        error "Не удалось запустить NFS"; STATUS[service]=ERROR
    fi

    exportfs -ra 2>/dev/null && ok "exportfs -ra выполнен" || warn "Ошибка exportfs"
    echo; info "Текущие экспорты:"
    exportfs -v 2>/dev/null || true
    STATUS[export]=OK

else
    # ──────────────────────────── HQ-CLI ────────────────────────────────────
    read -rp "IP/имя сервера NFS (HQ-SRV) [192.168.1.2]: " SRV; SRV="${SRV:-192.168.1.2}"
    read -rp "Экспортируемый каталог на сервере [/raid5/nfs]: " EXP; EXP="${EXP:-/raid5/nfs}"
    read -rp "Точка монтирования [/mnt/nfs]: " MNT; MNT="${MNT:-/mnt/nfs}"

    echo
    info "Монтирование $SRV:$EXP → $MNT"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    info "Установка nfs-clients..."
    apt-get update -y || true
    apt-get install -y nfs-clients || apt-get install -y nfs-utils || warn "Проверьте пакет NFS-клиента"

    mkdir -p "$MNT"
    info "Автомонтирование в /etc/fstab..."
    cp -f /etc/fstab /etc/fstab.bak 2>/dev/null || true
    sed -i "\|[[:space:]]$MNT[[:space:]]|d" /etc/fstab
    echo "$SRV:$EXP  $MNT  nfs  defaults,_netdev  0 0" >> /etc/fstab
    ok "/etc/fstab обновлён"

    systemctl enable --now rpcbind 2>/dev/null || true
    if mount -a 2>/dev/null && mountpoint -q "$MNT"; then
        ok "$MNT смонтирован"; STATUS[mount]=OK
    else
        warn "Не удалось смонтировать — проверьте сервер и сеть"; STATUS[mount]=ERROR
    fi

    echo; info "Проверка записи файла:"
    if touch "$MNT/test_from_$(hostname -s).txt" 2>/dev/null; then
        ok "Файл создан в $MNT — проверьте его наличие на HQ-SRV"
        ls -l "$MNT" || true
        STATUS[write]=OK
    else
        warn "Не удалось записать в $MNT"; STATUS[write]=ERROR
    fi
fi

echo
echo "============================================================"
echo "  Итог — Билет №3"
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

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
[HQ-SRV | NFS сервер]
exportfs -v                                           # Активные экспорты NFS
cat /etc/exports                                      # Настройки экспорта каталогов
systemctl is-active nfs-server || systemctl is-active nfs   # Статус службы NFS
showmount -e localhost                                # Экспорты, видимые локально

[HQ-CLI | NFS клиент]
mount | grep nfs                                      # Подтверждение монтирования NFS
df -h /mnt/nfs                                        # Использование смонтированного ресурса
grep nfs /etc/fstab                                   # Автомонтирование NFS
ls -l /mnt/nfs                                        # Содержимое каталога (чтение/запись)
showmount -e 192.168.1.2                              # Экспорты сервера HQ-SRV
EOF
