#!/bin/bash
# =============================================================================
# Билет №12 — Добавление DNS A-записей для Moodle и Wiki на BR-SRV
# Запускать на BR-SRV после поднятия Samba AD DC (ticket01).
# Добавляет записи moodle.au-team.irpo и wiki.au-team.irpo → HQ-SRV.
# =============================================================================
set -euo pipefail

export PATH="/usr/sbin:/sbin:/usr/local/sbin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

# Поиск samba-tool по PATH и типичным путям
find_samba_tool() {
    local p
    if p="$(command -v samba-tool 2>/dev/null)"; then
        echo "$p"; return 0
    fi
    for p in /usr/sbin/samba-tool /usr/bin/samba-tool \
              /usr/local/sbin/samba-tool /usr/local/bin/samba-tool; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}
SAMBA_TOOL="$(find_samba_tool || true)"
if [[ -z "$SAMBA_TOOL" ]]; then
    error "samba-tool не найден. Установите task-samba-dc и повторите запуск."
    exit 1
fi
info "Найден samba-tool: $SAMBA_TOOL"

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
# Проверка активности службы samba
_samba_active=false
for _svc in samba samba-ad-dc; do
    if systemctl is-active -q "$_svc" 2>/dev/null; then
        _samba_active=true; break
    fi
done
if ! $_samba_active; then
    warn "Служба samba не активна — пытаюсь запустить..."
    for _svc in samba samba-ad-dc; do
        if systemctl start "$_svc" 2>/dev/null; then
            sleep 2
            if systemctl is-active -q "$_svc" 2>/dev/null; then
                ok "Служба $_svc запущена"
                _samba_active=true; break
            fi
        fi
    done
    if ! $_samba_active; then
        warn "Не удалось запустить samba. Проверьте: systemctl status samba"
    fi
fi

# Выполнить DNS-команду с fallback по методам аутентификации
_samba_dns_run() {
    local out rc
    # метод 1: пароль
    out="$("$SAMBA_TOOL" "$@" -U "administrator%${ADMINPASS}" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
    warn "samba-tool $* (пароль): $out"
    # метод 2: Kerberos
    if command -v kinit >/dev/null 2>&1; then
        kinit administrator <<< "$ADMINPASS" 2>/dev/null || true
        out="$("$SAMBA_TOOL" "$@" -k yes 2>&1)"; rc=$?
        [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
        warn "samba-tool $* (kinit): $out"
    fi
    # метод 3: машинный аккаунт DC
    out="$("$SAMBA_TOOL" "$@" -P 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
    warn "samba-tool $* (-P): $out"
    error "Все методы аутентификации samba-tool не сработали."
    error "Проверьте: systemctl is-active samba; ss -tulnp | grep ':53';"
    error "  пароль administrator, синхронизацию времени (±5 мин для Kerberos)."
    return 1
}

# Запрос текущего IP записи
_dns_query_ip() {
    local rec="$1" out
    out="$("$SAMBA_TOOL" dns query 127.0.0.1 "$ZONE" "$rec" A \
        -U "administrator%${ADMINPASS}" 2>&1)" || true
    echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# Идемпотентное обеспечение A-записи
ensure_dns_a() {
    local rec="$1" target_ip="$2" current
    info "Обеспечиваю DNS A: ${rec}.${ZONE} → ${target_ip}"
    current="$(_dns_query_ip "$rec")"
    if [[ -z "$current" ]]; then
        if _samba_dns_run dns add 127.0.0.1 "$ZONE" "$rec" A "$target_ip" >/dev/null; then
            ok "${rec}.${ZONE} → ${target_ip} добавлена"
        else
            error "Не удалось добавить ${rec}.${ZONE}"; return 1
        fi
    elif [[ "$current" == "$target_ip" ]]; then
        ok "${rec}.${ZONE} уже указывает на ${current} — ОК"; return 0
    else
        warn "${rec}.${ZONE} указывает на ${current}, ожидается ${target_ip} — обновляю"
        if _samba_dns_run dns update 127.0.0.1 "$ZONE" "$rec" A "$current" "$target_ip" >/dev/null; then
            ok "${rec}.${ZONE} обновлена: ${current} → ${target_ip}"
        else
            warn "update не сработал — удаляю и добавляю заново"
            _samba_dns_run dns delete 127.0.0.1 "$ZONE" "$rec" A "$current" >/dev/null || true
            if _samba_dns_run dns add 127.0.0.1 "$ZONE" "$rec" A "$target_ip" >/dev/null; then
                ok "${rec}.${ZONE} пересоздана: → ${target_ip}"
            else
                error "Не удалось пересоздать ${rec}.${ZONE}"; return 1
            fi
        fi
    fi
    # Финальная проверка
    current="$(_dns_query_ip "$rec")"
    if [[ "$current" == "$target_ip" ]]; then
        ok "${rec}.${ZONE} проверена → ${current}"
    else
        error "${rec}.${ZONE} после операции показывает '${current}', ожидалось '${target_ip}'"
        return 1
    fi
}

for rec in moodle wiki; do
    ensure_dns_a "$rec" "$HQSRV_IP" || true
done

echo
info "Итоговая проверка записей:"
for rec in moodle wiki; do
    res="$(_dns_query_ip "$rec")"
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
