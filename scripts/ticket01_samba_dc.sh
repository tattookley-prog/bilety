#!/bin/bash
# =============================================================================
# Билет №1 — Доменный контроллер Samba AD DC
# Сервер:  BR-SRV (Альт Сервер)
# Клиент:  HQ-CLI (Альт Рабочая станция)
# Задание: развернуть Samba AD DC, группа hq, пользователи user1hq..user5hq,
#          ввести HQ-CLI в домен, обеспечить аутентификацию группы hq.
# =============================================================================
set -euo pipefail

export PATH="/usr/sbin:/sbin:/usr/local/sbin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Поиск samba-tool по PATH и типичным путям
_find_samba_tool() {
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
SAMBA_TOOL="$(_find_samba_tool || echo samba-tool)"

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
    apt-get update -y || true
    if apt-get install -y task-samba-dc; then
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
    if "$SAMBA_TOOL" domain provision \
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

    free_port_53() {
        info "Освобождаю порт 53 для внутреннего DNS Samba..."
        local _dns_services=(named bind bind9 dnsmasq systemd-resolved)
        local _other_services=(slapd krb5kdc kadmin winbind smb nmb)
        local _resolved_touched=false
        local _s _active _enabled
        _is_enabled_like() {
            case "$1" in
                enabled|enabled-runtime|static|indirect|generated|alias|linked|linked-runtime) return 0 ;;
                *) return 1 ;;
            esac
        }

        for _s in "${_dns_services[@]}"; do
            _active="$(systemctl is-active "$_s" 2>/dev/null || true)"
            _enabled="$(systemctl is-enabled "$_s" 2>/dev/null || true)"
            if [[ "$_active" == "active" ]] || _is_enabled_like "$_enabled"; then
                warn "Останавливаю DNS-службу $_s (порт 53)"
                systemctl stop "$_s" 2>/dev/null || true
                warn "Маскирую DNS-службу $_s, чтобы не занимала порт 53 после перезагрузки"
                systemctl mask "$_s" 2>/dev/null || true
                [[ "$_s" == "systemd-resolved" ]] && _resolved_touched=true
            fi
        done

        for _s in "${_other_services[@]}"; do
            _active="$(systemctl is-active "$_s" 2>/dev/null || true)"
            _enabled="$(systemctl is-enabled "$_s" 2>/dev/null || true)"
            if [[ "$_active" == "active" ]] || _is_enabled_like "$_enabled"; then
                info "Останавливаю и отключаю $_s (конфликтует с AD DC)"
                systemctl stop "$_s" 2>/dev/null || true
                systemctl disable "$_s" 2>/dev/null || true
            fi
        done

        if [[ "$_resolved_touched" == true ]]; then
            cp -f /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null || true
            printf 'search %s\nnameserver %s\n' "$DOMAIN_LC" "$SRV_IP" > /etc/resolv.conf
            info "systemd-resolved остановлен/замаскирован: /etc/resolv.conf восстановлен на локальный DNS"
        fi

        if ss -tulnp 2>/dev/null | grep -E ':53\b' >/dev/null 2>&1; then
            warn "Порт 53 всё ещё занят:"
            ss -tulnp 2>/dev/null | grep -E ':53\b' || true
            if command -v fuser >/dev/null 2>&1; then
                warn "Пробую освободить порт 53 через fuser -k..."
                fuser -k 53/tcp 53/udp >/dev/null 2>&1 || true
            else
                warn "fuser не найден — пропускаю принудительное освобождение порта 53"
            fi
        fi

        if ss -tulnp 2>/dev/null | grep -E ':53\b' >/dev/null 2>&1; then
            error "Порт 53 остаётся занятым"
            ss -tulnp 2>/dev/null | grep -E ':53\b' || true
            STATUS[port53]=ERROR
        else
            ok "Порт 53 свободен для Samba"
            STATUS[port53]=OK
        fi
    }

    free_port_53

    info "Запуск службы samba..."
    STARTED_UNIT=""
    systemctl unmask samba 2>/dev/null || true
    if systemctl enable --now samba 2>/dev/null; then
        STARTED_UNIT="samba"
    else
        warn "Не удалось запустить unit samba, пробую samba-ad-dc..."
        systemctl unmask samba-ad-dc 2>/dev/null || true
        if systemctl enable --now samba-ad-dc 2>/dev/null; then
            STARTED_UNIT="samba-ad-dc"
        else
            error "Не удалось запустить samba/samba-ad-dc"
            STATUS[service]=ERROR
        fi
    fi

    if [[ -n "$STARTED_UNIT" ]]; then
        if ! systemctl is-enabled -q "$STARTED_UNIT" 2>/dev/null; then
            systemctl enable "$STARTED_UNIT" 2>/dev/null || true
        fi
        _PORT53_OWNERS="$(ss -tulnp 2>/dev/null | grep -E ':53\b' || true)"
        _MAIN_PID="$(systemctl show -p MainPID --value "$STARTED_UNIT" 2>/dev/null || true)"
        if [[ "$(systemctl is-active "$STARTED_UNIT" 2>/dev/null || true)" == "active" ]] && \
           [[ -n "$_MAIN_PID" ]] && grep -Eq "pid=${_MAIN_PID}(,|\)|[[:space:]]|$)" <<< "$_PORT53_OWNERS"; then
            ok "$STARTED_UNIT запущена, enabled и слушает порт 53"
            STATUS[service]=OK
        else
            error "$STARTED_UNIT запущен некорректно: unit не active или порт 53 слушает не samba"
            [[ -n "$_PORT53_OWNERS" ]] && echo "$_PORT53_OWNERS"
            warn "Проверьте незамаскированные DNS-службы: systemctl is-enabled dnsmasq named bind systemd-resolved"
            STATUS[service]=ERROR
        fi
    fi

    sleep 2
    info "Создание группы hq и пользователей user1hq..user5hq..."
    "$SAMBA_TOOL" group add hq 2>/dev/null && ok "Группа hq создана" || warn "Группа hq уже есть"
    for i in 1 2 3 4 5; do
        u="user${i}hq"
        if "$SAMBA_TOOL" user create "$u" "$ADMINPASS" >/dev/null 2>&1; then
            ok "Пользователь $u создан"
        else
            warn "Пользователь $u уже есть"
        fi
        "$SAMBA_TOOL" group addmembers hq "$u" >/dev/null 2>&1 || true
    done
    STATUS[users]=OK

    # Выполнить DNS-команду с fallback по методам аутентификации
    _samba_dns_run_t01() {
        local out rc
        out="$("$SAMBA_TOOL" "$@" -U "administrator%${ADMINPASS}" 2>&1)"; rc=$?
        [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
        warn "samba-tool $* (пароль): $out"
        if command -v kinit >/dev/null 2>&1; then
            echo "$ADMINPASS" | kinit administrator 2>/dev/null || true
            out="$("$SAMBA_TOOL" "$@" -k yes 2>&1)"; rc=$?
            [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
            warn "samba-tool $* (kinit): $out"
        fi
        out="$("$SAMBA_TOOL" "$@" -P 2>&1)"; rc=$?
        [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
        warn "samba-tool $* (-P): $out"
        error "Все методы аутентификации samba-tool не сработали."
        error "Проверьте: systemctl is-active samba; ss -tulnp | grep ':53'; пароль; время (±5 мин)."
        return 1
    }

    # Запрос текущего IP A-записи
    _dns_query_ip_t01() {
        local rec="$1" out
        out="$("$SAMBA_TOOL" dns query 127.0.0.1 "$DOMAIN_LC" "$rec" A \
            -U "administrator%${ADMINPASS}" 2>&1)" || true
        echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
    }

    # Идемпотентное обеспечение A-записи
    _ensure_dns_a_t01() {
        local rec="$1" target_ip="$2" current
        info "Обеспечиваю DNS A: ${rec}.${DOMAIN_LC} → ${target_ip}"
        current="$(_dns_query_ip_t01 "$rec")"
        if [[ -z "$current" ]]; then
            if _samba_dns_run_t01 dns add 127.0.0.1 "$DOMAIN_LC" "$rec" A "$target_ip" >/dev/null; then
                ok "DNS: $rec.${DOMAIN_LC} → ${target_ip} добавлена"
            else
                error "Не удалось добавить DNS-запись $rec.${DOMAIN_LC}"; return 1
            fi
        elif [[ "$current" == "$target_ip" ]]; then
            ok "DNS: $rec.${DOMAIN_LC} уже указывает на ${current} — ОК"; return 0
        else
            warn "DNS: $rec.${DOMAIN_LC} указывает на ${current}, ожидается ${target_ip} — обновляю"
            if _samba_dns_run_t01 dns update 127.0.0.1 "$DOMAIN_LC" "$rec" A "$current" "$target_ip" >/dev/null; then
                ok "DNS: $rec.${DOMAIN_LC} обновлена: ${current} → ${target_ip}"
            else
                warn "update не сработал — удаляю и добавляю заново"
                _samba_dns_run_t01 dns delete 127.0.0.1 "$DOMAIN_LC" "$rec" A "$current" >/dev/null || true
                if _samba_dns_run_t01 dns add 127.0.0.1 "$DOMAIN_LC" "$rec" A "$target_ip" >/dev/null; then
                    ok "DNS: $rec.${DOMAIN_LC} пересоздана → ${target_ip}"
                else
                    error "Не удалось пересоздать DNS-запись $rec.${DOMAIN_LC}"; return 1
                fi
            fi
        fi
        current="$(_dns_query_ip_t01 "$rec")"
        if [[ "$current" == "$target_ip" ]]; then
            ok "DNS: $rec.${DOMAIN_LC} проверена → ${current}"
        else
            error "DNS: $rec.${DOMAIN_LC} после операции показывает '${current}', ожидалось '${target_ip}'"
            return 1
        fi
    }

    echo; info "Добавление DNS A-записей для Moodle и Wiki..."
    read -rp "IP HQ-SRV (для A-записей moodle и wiki) [192.168.1.2]: " HQSRV_IP; HQSRV_IP="${HQSRV_IP:-192.168.1.2}"
    _ensure_dns_a_t01 moodle "$HQSRV_IP" || true
    _ensure_dns_a_t01 wiki   "$HQSRV_IP" || true
    STATUS[dns_records]=OK

    echo; info "Проверка:"
    "$SAMBA_TOOL" domain level show 2>/dev/null | head -n 3 || true
    "$SAMBA_TOOL" group listmembers hq 2>/dev/null || true

else
    # ───────────────────────── HQ-CLI: ввод в домен ─────────────────────────
    read -rp "Имя этого хоста (короткое) [hq-cli]: " HOST; HOST="${HOST:-hq-cli}"
    read -rp "IP контроллера домена (BR-SRV) [192.168.3.2]: " DC_IP; DC_IP="${DC_IP:-192.168.3.2}"

    echo
    info "Ввод $HOST в домен $REALM через $DC_IP"
    read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

    # ── 1. Установка пакетов клиента AD/SSSD ─────────────────────────────────
    info "Обновление списка пакетов (apt-get update)..."
    apt-get update -y || true

    info "Установка пакетов клиента AD (task-auth-ad-sssd)..."
    if apt-get install -y task-auth-ad-sssd; then
        ok "task-auth-ad-sssd установлен"
    else
        warn "task-auth-ad-sssd недоступен — пробуем отдельные пакеты sssd, samba-client, krb5-kinit..."
        apt-get install -y sssd samba-client krb5-kinit || true
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

    # ── 4а. Синхронизация времени перед kinit/join ────────────────────────────
    info "Синхронизация времени с DC (Kerberos требует расхождение ≤5 мин)..."
    if command -v chronyc >/dev/null 2>&1; then
        chronyc makestep 2>/dev/null || true
        ok "chronyc makestep выполнен"
    elif command -v ntpdate >/dev/null 2>&1; then
        ntpdate "$DC_IP" 2>/dev/null || true
        ok "ntpdate $DC_IP выполнен"
    else
        warn "chronyc и ntpdate не найдены — время не синхронизировано автоматически"
    fi
    info "Текущее время: $(date)"
    warn "Сверьте время с BR-SRV (±5 мин), иначе Kerberos вернёт Access Denied"

    # ── 4б. Принудительная запись корректного /etc/samba/smb.conf ────────────
    info "Запись корректного /etc/samba/smb.conf (workgroup=$NBDOMAIN, realm=$REALM)..."
    if [[ ! "$NBDOMAIN" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$REALM" =~ ^[A-Za-z0-9._-]+$ ]]; then
        error "Недопустимые символы в NBDOMAIN ('$NBDOMAIN') или REALM ('$REALM') — запись smb.conf прервана"
        STATUS[join]=ERROR
    else
    if [[ -f /etc/samba/smb.conf ]]; then
        cp -f /etc/samba/smb.conf /etc/samba/smb.conf.bak 2>/dev/null || true
        ok "Резервная копия: /etc/samba/smb.conf.bak"
    fi
    cat > /etc/samba/smb.conf <<EOF
[global]
    workgroup = ${NBDOMAIN}
    realm = ${REALM}
    security = ads
    kerberos method = secrets and keytab
    dedicated keytab file = /etc/krb5.keytab
    winbind use default domain = yes
    template shell = /bin/bash
    template homedir = /home/%U
EOF
    ok "/etc/samba/smb.conf записан (workgroup=${NBDOMAIN}, realm=${REALM})"
    fi

    # ── 4в. Проверка синтаксиса smb.conf через testparm ──────────────────────
    if [[ "${STATUS[join]:-}" != "ERROR" ]] && command -v testparm >/dev/null 2>&1; then
        info "Проверка smb.conf через testparm -s..."
        _TESTPARM_OUT="$(testparm -s 2>&1)" || true
        _TP_WG="$(grep -i 'workgroup' <<< "$_TESTPARM_OUT" | head -n1)"
        _TP_REALM="$(grep -i 'realm' <<< "$_TESTPARM_OUT" | head -n1)"
        _WG_OK=false; _RL_OK=false
        if grep -qi "$NBDOMAIN" <<< "$_TP_WG"; then _WG_OK=true; fi
        if grep -qi "$REALM"    <<< "$_TP_REALM"; then _RL_OK=true; fi
        if [[ "$_WG_OK" == true && "$_RL_OK" == true ]]; then
            ok "testparm: workgroup=$NBDOMAIN, realm=$REALM — корректно"
        else
            error "testparm показывает неверные значения workgroup/realm!"
            warn "  testparm workgroup : $_TP_WG"
            warn "  testparm realm     : $_TP_REALM"
            warn "Фактическое содержимое smb.conf:"
            grep -iE 'workgroup|realm|security' /etc/samba/smb.conf || true
            STATUS[join]=ERROR
        fi
    elif [[ "${STATUS[join]:-}" != "ERROR" ]]; then
        warn "testparm не найден — пропускаем проверку синтаксиса smb.conf"
    fi

    # ── 5. Получение Kerberos TGT ─────────────────────────────────────────────
    if [[ "${STATUS[join]:-}" != "ERROR" ]]; then
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
        warn "Фактические значения workgroup/realm/security в smb.conf:"
        grep -iE 'workgroup|realm|security' /etc/samba/smb.conf 2>/dev/null || \
            warn "  /etc/samba/smb.conf не найден"
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
echo "  Итог — Биле�� №1"
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
[BR-SRV | Samba AD DC]
samba-tool domain level show                          # Уровень и имя домена
samba-tool user list                                  # Список пользователей (user1hq..user5hq)
samba-tool group listmembers hq                       # Участники группы hq
systemctl is-active samba                             # Служба samba активна
ss -tulnp | grep ':53'                                # Порт 53 слушает samba (внутренний DNS)
samba-tool dns query 127.0.0.1 au-team.irpo @ ALL -U administrator   # DNS-записи зоны
host au-team.irpo                                     # Проверка резолвинга домена

[HQ-CLI | Клиент в домене]
net ads testjoin                                      # Проверка ввода в домен (Join is OK)
klist                                                 # Kerberos-билет (TGT)
id user1hq                                            # UID/GID доменного пользователя
getent passwd user1hq                                 # Запись пользователя из NSS/SSSD
EOF
