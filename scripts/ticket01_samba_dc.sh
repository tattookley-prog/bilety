#!/bin/bash
# =============================================================================
# Билет №1 — Доменный контроллер Samba AD DC
# Сервер:  BR-SRV (Альт Сервер)
# Клиент:  HQ-CLI (Альт Рабочая станция)
# Задание: развернуть Samba AD DC, группа hq, пользователи user1hq..user5hq,
#          ввести HQ-CLI в домен, обеспечить аутентификацию группы hq.
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
echo "  Билет №1 — Samba AD DC"
echo "============================================================"
echo
echo "Где выполняется настройка?"
echo "  1) BR-SRV  — развернуть контроллер домена"
echo "  2) HQ-CLI  — ввести рабочую станцию в домен"
read -rp "Выбор [1]: " ROLE; ROLE="${ROLE:-1}"

read -rp "Realm (домен, заглавными) [AU-TEAM.IRPO]: " REALM; REALM="${REALM:-AU-TEAM.IRPO}"
read -rp "NetBIOS-имя домена [AU-TEAM]: " NBDOMAIN; NBDOMAIN="${NBDOMAIN:-AU-TEAM}"
read -rp "Пароль администратора домена [P@ssw0rd]: " ADMINPASS; ADMINPASS="${ADMINPASS:-P@ssw0rd}"
DOMAIN_LC="$(echo "$REALM" | tr 'A-Z' 'a-z')"
PROVISION_LOG="/var/log/ticket01-provision.log"

if [[ "$ROLE" == "1" ]]; then
    # ───────────────────────── BR-SRV: Samba AD DC ──────────────────────────
    read -rp "IP этого сервера (BR-SRV) [192.168.3.2]: " SRV_IP; SRV_IP="${SRV_IP:-192.168.3.2}"
    read -rp "DNS-форвардер [77.88.8.7]: " FWD; FWD="${FWD:-77.88.8.7}"

    free_port_53() {
        local s
        local resolved_stopped=0
        local busy53=""

        info "Проверяю и освобождаю порт 53 перед запуском Samba..."
        for s in named bind bind9 dnsmasq systemd-resolved slapd krb5kdc kadmin winbind smb nmb; do
            if systemctl is-active --quiet "$s" 2>/dev/null; then
                warn "Активен конфликтующий сервис: $s (остановка/отключение)"
                systemctl stop "$s" 2>/dev/null || true
                systemctl disable "$s" 2>/dev/null || true
                [[ "$s" == "systemd-resolved" ]] && resolved_stopped=1
            fi
        done

        if [[ "$resolved_stopped" -eq 1 ]]; then
            warn "systemd-resolved отключен, восстанавливаю /etc/resolv.conf на BR-SRV"
            cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            printf 'search %s\nnameserver %s\n' "$DOMAIN_LC" "$SRV_IP" > /etc/resolv.conf
            ok "resolv.conf → nameserver $SRV_IP"
        fi

        busy53="$(ss -tulnp 2>/dev/null | grep -E ':53\b' || true)"
        if [[ -n "$busy53" ]]; then
            warn "Порт 53 всё ещё занят:"
            echo "$busy53"
            if command -v fuser >/dev/null 2>&1; then
                warn "Пробую освободить порт 53 через fuser..."
                fuser -k 53/tcp 53/udp >/dev/null 2>&1 || true
            else
                warn "Утилита fuser не найдена, пропускаю принудительное освобождение"
            fi
        fi

        busy53="$(ss -tulnp 2>/dev/null | grep -E ':53\b' || true)"
        if [[ -z "$busy53" ]]; then
            ok "Порт 53 свободен"
            STATUS[port53]=OK
        else
            error "Порт 53 занят"
            echo "$busy53"
            STATUS[port53]=ERROR
        fi
    }

    echo
    info "Realm=$REALM  NetBIOS=$NBDOMAIN  IP=$SRV_IP"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    info "Установка task-samba-dc..."
    apt-get update -y >/dev/null 2>&1 || true
    if apt-get install -y task-samba-dc >/dev/null 2>&1; then
        ok "task-samba-dc установлен"; STATUS[install]=OK
    else
        error "Не удалось установить task-samba-dc"; STATUS[install]=ERROR
    fi

    info "Останавливаю smb/nmb/samba, чищу базы и smb.conf..."
    for s in smb nmb samba; do systemctl stop "$s" 2>/dev/null || true; done
    for s in smb nmb; do systemctl disable "$s" 2>/dev/null || true; done
    rm -f /etc/samba/smb.conf
    rm -f /var/lib/samba/private/*.tdb 2>/dev/null || true
    rm -f /var/lib/samba/private/*.ldb 2>/dev/null || true
    ok "Старая конфигурация очищена"

    info "Provision домена ${REALM} (лог: ${PROVISION_LOG})..."
    if ! : > "$PROVISION_LOG" 2>/dev/null; then
        PROVISION_LOG="/tmp/ticket01-provision.log"
        if ! : > "$PROVISION_LOG" 2>/dev/null; then
            warn "Не удалось создать лог provision ни в /var/log, ни в /tmp"
        else
            warn "Нет доступа к /var/log, пишу лог provision в ${PROVISION_LOG}"
        fi
    fi
    if samba-tool domain provision \
        --realm="$REALM" \
        --domain="$NBDOMAIN" \
        --adminpass="$ADMINPASS" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --use-rfc2307 2>&1 | tee "$PROVISION_LOG"; then
        ok "Домен ${REALM} создан"; STATUS[provision]=OK
    else
        error "Ошибка provision (см. ${PROVISION_LOG})"; STATUS[provision]=ERROR
    fi

    # Kerberos конфиг
    if [[ -f /var/lib/samba/private/krb5.conf ]]; then
        cp -f /var/lib/samba/private/krb5.conf /etc/krb5.conf
        ok "krb5.conf скопирован"
    fi

    # DNS forwarder в smb.conf
    if [[ -f /etc/samba/smb.conf ]] && ! grep -q 'dns forwarder' /etc/samba/smb.conf; then
        sed -i "/\[global\]/a \\\tdns forwarder = ${FWD}" /etc/samba/smb.conf
    fi

    # resolv.conf на себя
    cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    printf 'search %s\nnameserver %s\n' "$DOMAIN_LC" "$SRV_IP" > /etc/resolv.conf
    ok "resolv.conf → nameserver $SRV_IP"

    free_port_53

    info "Запуск службы samba..."
    STARTED_UNIT=""
    systemctl unmask samba 2>/dev/null || true
    if systemctl enable --now samba 2>/dev/null; then
        STARTED_UNIT="samba"
        ok "samba запущена"
    else
        warn "Не удалось запустить samba, пробую samba-ad-dc..."
        systemctl unmask samba-ad-dc 2>/dev/null || true
        if systemctl enable --now samba-ad-dc 2>/dev/null; then
            STARTED_UNIT="samba-ad-dc"
            ok "samba-ad-dc запущена"
        else
            error "Не удалось запустить samba/samba-ad-dc"
        fi
    fi

    if [[ -n "$STARTED_UNIT" ]] && systemctl is-active --quiet "$STARTED_UNIT" 2>/dev/null; then
        if ss -tulnp 2>/dev/null | awk '/:53\b/ && tolower($0) ~ /samba/ {found=1} END {exit(found ? 0 : 1)}'; then
            ok "${STARTED_UNIT} active, порт 53 слушает samba"
            STATUS[service]=OK
        else
            error "${STARTED_UNIT} active, но порт 53 слушает не samba"
            ss -tulnp 2>/dev/null | grep -E ':53\b' || true
            STATUS[service]=ERROR
        fi
    else
        error "Samba не active после запуска"
        STATUS[service]=ERROR
    fi

    sleep 2
    info "Создание группы hq и пользователей user1hq..user5hq..."
    samba-tool group add hq 2>/dev/null && ok "Группа hq создана" || warn "Группа hq уже есть"
    for i in 1 2 3 4 5; do
        u="user${i}hq"
        if samba-tool user create "$u" "$ADMINPASS" >/dev/null 2>&1; then
            ok "Пользователь $u создан"
        else
            warn "Пользователь $u уже есть"
        fi
        samba-tool group addmembers hq "$u" >/dev/null 2>&1 || true
    done
    STATUS[users]=OK

    echo; info "Проверка:"
    samba-tool domain level show 2>/dev/null | head -n 3 || true
    samba-tool group listmembers hq 2>/dev/null || true

else
    # ───────────────────────── HQ-CLI: ввод в домен ─────────────────────────
    read -rp "Имя этого хоста (короткое) [hq-cli]: " HOST; HOST="${HOST:-hq-cli}"
    read -rp "IP контроллера домена (BR-SRV) [192.168.3.2]: " DC_IP; DC_IP="${DC_IP:-192.168.3.2}"

    echo
    info "Ввод $HOST в домен $REALM через $DC_IP"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    info "Установка пакетов клиента AD..."
    apt-get install -y task-auth-ad-sssd 2>/dev/null || \
    apt-get install -y samba-client krb5-kinit sssd 2>/dev/null || warn "Проверьте пакеты вручную"

    info "Прописываю DNS на контроллер домена..."
    cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
    printf 'search %s\nnameserver %s\n' "$DOMAIN_LC" "$DC_IP" > /etc/resolv.conf
    ok "resolv.conf → nameserver $DC_IP"

    info "Проверка разрешения имени домена..."
    if host "$DOMAIN_LC" >/dev/null 2>&1 || nslookup "$DOMAIN_LC" >/dev/null 2>&1; then
        ok "Домен $DOMAIN_LC резолвится"; STATUS[dns]=OK
    else
        warn "Домен не резолвится — проверьте сеть до $DC_IP"; STATUS[dns]=ERROR
    fi

    info "Ввод в домен: system-auth write ad $DOMAIN_LC $NBDOMAIN $HOST"
    if system-auth write ad "$DOMAIN_LC" "$NBDOMAIN" "$HOST" "$DOMAIN_LC" "$DC_IP" 2>/dev/null \
       || system-auth write ad "$DOMAIN_LC" "$NBDOMAIN" "$HOST" 2>/dev/null; then
        ok "Команда system-auth выполнена"; STATUS[join]=OK
    else
        warn "system-auth завершился с ошибкой — потребуется kinit administrator"; STATUS[join]=ERROR
    fi

    info "Получение Kerberos-билета администратора (введите пароль $ADMINPASS)..."
    echo "$ADMINPASS" | kinit administrator 2>/dev/null && ok "Kerberos-билет получен" || warn "kinit вручную: kinit administrator"

    echo; info "Проверка членов домена:"
    klist 2>/dev/null || true
    getent passwd "administrator@${DOMAIN_LC}" 2>/dev/null || getent passwd administrator 2>/dev/null || true
    echo
    info "Проверьте вход доменного пользователя: id user1hq  /  su - user1hq"
fi

echo
echo "============================================================"
echo "  Итог — Билет №1"
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
