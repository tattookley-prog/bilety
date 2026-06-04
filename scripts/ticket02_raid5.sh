#!/bin/bash
# =============================================================================
# Билет №2 — RAID 5 на HQ-SRV
# Из трёх дисков по 1 ГБ создать RAID5 /dev/md0, ext4, автомонтирование /raid5,
# конфигурация в /etc/mdadm.conf.
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
echo "  Билет №2 — RAID 5 (/dev/md0) на HQ-SRV"
echo "============================================================"
echo
info "Доступные блочные устройства:"
lsblk -d -o NAME,SIZE,TYPE | grep -v loop || true
echo

read -rp "Диск 1 [/dev/sdb]: " D1; D1="${D1:-/dev/sdb}"
read -rp "Диск 2 [/dev/sdc]: " D2; D2="${D2:-/dev/sdc}"
read -rp "Диск 3 [/dev/sdd]: " D3; D3="${D3:-/dev/sdd}"
read -rp "Имя массива [/dev/md0]: " MD; MD="${MD:-/dev/md0}"
read -rp "Точка монтирования [/raid5]: " MNT; MNT="${MNT:-/raid5}"

echo
warn "ВНИМАНИЕ: диски $D1 $D2 $D3 будут полностью очищены!"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Установка mdadm..."
if ! command -v mdadm >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y mdadm >/dev/null 2>&1 || { error "mdadm не установлен"; STATUS[install]=ERROR; }
fi
command -v mdadm >/dev/null 2>&1 && { ok "mdadm доступен"; STATUS[install]=OK; }

for d in "$D1" "$D2" "$D3"; do
    [[ -b "$d" ]] || { error "Устройство $d не найдено"; exit 1; }
    wipefs -a "$d" >/dev/null 2>&1 || true
    mdadm --zero-superblock "$d" >/dev/null 2>&1 || true
done
ok "Диски очищены"

info "Создаю RAID5 $MD из $D1 $D2 $D3..."
if mdadm --create --verbose "$MD" --level=5 --raid-devices=3 "$D1" "$D2" "$D3" --run >/dev/null 2>&1; then
    ok "Массив $MD создан"; STATUS[create]=OK
else
    error "Не удалось создать массив"; STATUS[create]=ERROR
fi

info "Файловая система ext4 на $MD..."
if mkfs.ext4 -F "$MD" >/dev/null 2>&1; then
    ok "ext4 создана"; STATUS[mkfs]=OK
else
    error "Ошибка mkfs.ext4"; STATUS[mkfs]=ERROR
fi

mkdir -p "$MNT"
UUID="$(blkid -s UUID -o value "$MD" 2>/dev/null || true)"

info "Автомонтирование в /etc/fstab..."
cp -f /etc/fstab /etc/fstab.bak 2>/dev/null || true
sed -i "\|[[:space:]]$MNT[[:space:]]|d" /etc/fstab
if [[ -n "$UUID" ]]; then
    echo "UUID=$UUID  $MNT  ext4  defaults  0 0" >> /etc/fstab
else
    echo "$MD  $MNT  ext4  defaults  0 0" >> /etc/fstab
fi
if mount -a 2>/dev/null && mountpoint -q "$MNT"; then
    ok "$MNT смонтирован"; STATUS[mount]=OK
else
    warn "Проверьте монтирование вручную: mount -a"; STATUS[mount]=ERROR
fi

info "Сохраняю конфигурацию в /etc/mdadm.conf..."
cp -f /etc/mdadm.conf /etc/mdadm.conf.bak 2>/dev/null || true
{
    echo "DEVICE partitions"
    mdadm --detail --scan
} > /etc/mdadm.conf
if grep -q 'ARRAY' /etc/mdadm.conf; then
    ok "/etc/mdadm.conf обновлён"; STATUS[conf]=OK
else
    warn "ARRAY не найден в /etc/mdadm.conf"; STATUS[conf]=ERROR
fi
update-initramfs -u >/dev/null 2>&1 || true

echo
info "Состояние массива:"
mdadm --detail "$MD" 2>/dev/null | grep -E 'State|Raid Level|Active|Working|Failed' || true
echo
df -h "$MNT" 2>/dev/null || true

echo
echo "============================================================"
echo "  Итог — Билет №2"
echo "============================================================"
for k in install create mkfs mount conf; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Проверка: cat /proc/mdstat"
