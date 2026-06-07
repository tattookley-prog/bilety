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

if [[ "$ROLE" == "1" ]]; then
    # ───────────────────────── BR-SRV: Samba AD DC ──────────────────────────
    read -rp "IP этого сервера (BR-SRV) [192.168.3.2]: " SRV_IP; SRV_IP="${SRV_IP:-192.168.3.2}"
    read -rp "DNS-форвардер [77.88.8.7]: " FWD; FWD="${FWD:-77.88.8.7}"

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

    info "Provision домена ${REALM}..."
    if samba-tool domain provision \
        --realm="$REALM" \
        --domain="$NBDOMAIN" \
        --adminpass="$ADMINPASS" \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --use-rfc2307 >/dev/null 2>&1; then
        ok "Домен ${REALM} создан"; STATUS[provision]=OK
    else
        error "Ошибка provision (возможно домен уже создан)"; STATUS[provision]=ERROR
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

    info "Запуск службы samba..."
    if systemctl enable --now samba 2>/dev/null; then
        ok "samba запущена"; STATUS[service]=OK
    else
        error "Не удалось запустить samba"; STATUS[service]=ERROR
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

    # ── 1. Установка пакетов клиента AD/SSSD ─────────────────────────────────
    info "Установка пакетов клиента AD (task-auth-ad-sssd)..."
    if apt-get install -y task-auth-ad-sssd 2>/dev/null; then
        ok "task-auth-ad-sssd установлен"
    else
        warn "task-auth-ad-sssd недоступен — пробуем отдельные пакеты sssd, samba-client, krb5-kinit..."
        apt-get install -y sssd samba-client krb5-kinit 2>/dev/null || true
    fi

    # Проверка наличия необходимых команд
    _PKG_OK=true
    for _cmd in net sssd kinit; do
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            error "Команда '$_cmd' не найдена — пакеты клиента AD не установлены"
            _PKG_OK=false
        fi
    done
    if [[ "$_PKG_OK" == false ]]; then
        error "Установка пакетов AD-клиента не удалась (нет репозитория или офлайн-стенд)"
        error "Установите вручную: apt-get install task-auth-ad-sssd"
        STATUS[join]=ERROR
    else

    # ── 2. Настройка FQDN и /etc/hosts ───────────────────────────────────────
    FQDN="${HOST}.${DOMAIN_LC}"
    info "Установка FQDN: $FQDN"
    hostnamectl set-hostname "$FQDN" 2>/dev/null || true
    _CLIENT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')" || _CLIENT_IP=""
    if [[ -n "$_CLIENT_IP" ]] && ! grep -qF "$FQDN" /etc/hosts 2>/dev/null; then
        cp -f /etc/hosts /etc/hosts.bak 2>/dev/null || true
        printf '%s\t%s %s\n' "$_CLIENT_IP" "$FQDN" "$HOST" >> /etc/hosts
        ok "/etc/hosts: добавлена запись $_CLIENT_IP $FQDN $HOST"
    fi

    # ── 3. Настройка DNS ──────────────────────────────────────────────────────
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

    # ── 4. Запись конфигурации AD-клиента (только конфиги, не join) ───────────
    info "Запись конфигурации AD-клиента (system-auth write ad)..."
    if system-auth write ad "$DOMAIN_LC" "$NBDOMAIN" "$HOST" "$DOMAIN_LC" "$DC_IP" 2>/dev/null \
       || system-auth write ad "$DOMAIN_LC" "$NBDOMAIN" "$HOST" 2>/dev/null; then
        ok "Конфигурация AD-клиента записана"
    else
        warn "system-auth завершился с ошибкой — продолжаем (конфиги могут быть частичными)"
    fi

    # ── 5. Получение Kerberos TGT ─────────────────────────────────────────────
    info "Получение Kerberos-билета администратора..."
    if echo "$ADMINPASS" | kinit "administrator@${REALM}" 2>/dev/null || \
       echo "$ADMINPASS" | kinit administrator 2>/dev/null; then
        ok "Kerberos-билет получен"
    else
        warn "kinit не получил билет — попробуйте вручную: kinit administrator"
    fi

    # ── 6. Реальный ввод в домен (net ads join) ───────────────────────────────
    info "Ввод машины в домен (net ads join)..."
    if net ads join -U "administrator%${ADMINPASS}" 2>/dev/null; then
        ok "net ads join выполнен"
    elif net ads join -k 2>/dev/null; then
        ok "net ads join -k выполнен (по Kerberos-билету)"
    else
        warn "net ads join завершился с ошибкой — см. диагностику ниже"
    fi

    # ── 7. Перезапуск и включение SSSD ───────────────────────────────────────
    info "Запуск и включение SSSD..."
    systemctl restart sssd 2>/dev/null || true
    systemctl enable --now sssd 2>/dev/null || true
    sleep 2

    # ── 8. Проверка статуса join по net ads testjoin ──────────────────────────
    info "Проверка членства в домене (net ads testjoin)..."
    _TESTJOIN="$(net ads testjoin 2>&1)" || true
    if echo "$_TESTJOIN" | grep -qi "Join is OK"; then
        ok "Вступление в домен подтверждено"
        STATUS[join]=OK
    else
        error "Вступление в домен НЕ подтверждено"
        echo "$_TESTJOIN"
        warn "Диагностика:"
        warn "  net ads testjoin"
        warn "  klist"
        warn "  systemctl status sssd"
        warn "  ping $DC_IP  — проверьте связность до DC"
        warn "  Kerberos требует синхронизацию времени ±5 мин (проверьте NTP)"
        warn "  host $DOMAIN_LC  — проверьте DNS"
        warn "  На BR-SRV: samba-tool user list | grep hq"
        STATUS[join]=ERROR
    fi

    # ── 9. Настройка коротких имён пользователей (use_fully_qualified_names) ──
    if [[ "${STATUS[join]}" == "OK" ]]; then
        info "Проверка доступности доменных пользователей по короткому имени..."
        sleep 2
        if ! id "user1hq" >/dev/null 2>&1; then
            if id "user1hq@${DOMAIN_LC}" >/dev/null 2>&1; then
                ok "Пользователи видны по FQDN-имени (user1hq@${DOMAIN_LC})"
                info "Настройка коротких имён в sssd.conf (use_fully_qualified_names = False)..."
                _SSSD_CONF="/etc/sssd/sssd.conf"
                if [[ -f "$_SSSD_CONF" ]]; then
                    cp -f "$_SSSD_CONF" "${_SSSD_CONF}.bak" 2>/dev/null || true
                    if grep -q 'use_fully_qualified_names' "$_SSSD_CONF"; then
                        sed -i 's/use_fully_qualified_names[[:space:]]*=.*/use_fully_qualified_names = False/' \
                            "$_SSSD_CONF"
                    else
                        sed -i '/^\[domain\//a use_fully_qualified_names = False' "$_SSSD_CONF"
                    fi
                    systemctl restart sssd 2>/dev/null || true
                    sleep 2
                    ok "sssd.conf обновлён: use_fully_qualified_names = False"
                else
                    warn "Файл $_SSSD_CONF не найден — настройте use_fully_qualified_names вручную"
                fi
            else
                warn "Доменные пользователи не видны (ни по короткому, ни по FQDN-имени)"
                warn "Убедитесь, что на BR-SRV созданы пользователи:"
                warn "  samba-tool user list | grep hq"
                warn "Если список пуст — запустите скрипт на BR-SRV (ROLE=1) для создания пользователей"
            fi
        else
            ok "Доменные пользователи доступны по короткому имени (user1hq)"
        fi
    fi

    fi  # конец блока _PKG_OK

    # ── 10. Итоговая диагностика HQ-CLI ──────────────────────────────────────
    echo; info "Итоговая диагностика (HQ-CLI):"
    net ads testjoin 2>/dev/null || true
    klist 2>/dev/null || true
    echo
    info "Проверка пользователей:"
    if id user1hq >/dev/null 2>&1; then
        ok "id user1hq — $(id user1hq)"
    elif id "user1hq@${DOMAIN_LC}" >/dev/null 2>&1; then
        ok "id user1hq@${DOMAIN_LC} — $(id "user1hq@${DOMAIN_LC}")"
    else
        warn "Пользователь user1hq не найден"
        warn "Проверьте на BR-SRV: samba-tool user list | grep hq"
        warn "Если пользователей нет — создайте их на BR-SRV (запустите скрипт с ROLE=1)"
    fi
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
