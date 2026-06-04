#!/bin/bash
# =============================================================================
# check_all.sh — интерактивная проверка выполнения билетов Модуля 2
# Демоэкзамен 09.02.06, репозиторий bilety
#
# Позволяет выбрать:
#   1) машину (роль), на которой выполняется проверка;
#   2) конкретный билет (или все билеты этой машины).
# Для двусторонних билетов (1, 3, 4, 7) спрашивает сторону (сервер/клиент/роутер).
#
# Запуск: sudo bash scripts/check_all.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo bash scripts/check_all.sh)"; exit 1; }

# ─── Хранилище результатов ──────────────────────────────────────────────
declare -a RESULT_KEYS=()
declare -A RESULT_TITLE
declare -A RESULT_STATUS

add_result() { RESULT_KEYS+=("$1"); RESULT_TITLE["$1"]="$2"; RESULT_STATUS["$1"]="$3"; }

run_ok_fail_check() {
    local key="$1" title="$2" cmd="$3"
    info "$title"
    if bash -o pipefail -c "$cmd" >/dev/null 2>&1; then
        ok "$title"; add_result "$key" "$title" "OK"
    else
        fail "$title"; add_result "$key" "$title" "FAIL"
    fi
}

# Активное ожидание: повторяет проверку каждую секунду до timeout (для асинхронных служб)
run_wait_check() {
    local key="$1" title="$2" cmd="$3" timeout="${4:-30}" i
    info "$title (ожидание до ${timeout}с)"
    for ((i = 1; i <= timeout; i++)); do
        if bash -o pipefail -c "$cmd" >/dev/null 2>&1; then
            ok "$title (за ~${i}с)"; add_result "$key" "$title" "OK"; return 0
        fi
        sleep 1
    done
    fail "$title (таймаут ${timeout}с)"; add_result "$key" "$title" "FAIL"
}

run_skip_check() { warn "$2 (SKIP: $3)"; add_result "$1" "$2" "SKIP"; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }

ask_side() {
    # $1 — текст; читает выбор в переменную REPLY_SIDE
    local prompt="$1" pick
    echo
    echo "$prompt"
    read -rp "Сторона: " pick
    REPLY_SIDE="$pick"
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 1 — Samba AD DC
# ═════════════════════════════════════════════════════════════════════════
check_ticket01() {
    info "Билет №1 — Samba AD DC"
    ask_side "Что проверяем?  1) BR-SRV (контроллер домена)   2) HQ-CLI (введён в домен)"
    if [[ "$REPLY_SIDE" == "2" ]]; then
        if check_cmd klist; then
            run_ok_fail_check "t1_krb" "Kerberos-билет получен (klist)" "klist 2>/dev/null | grep -qi 'krbtgt\|Default principal'"
        else
            run_skip_check "t1_krb" "Kerberos-билет (klist)" "нет команды klist"
        fi
        run_ok_fail_check "t1_user_resolve" "Доменный пользователь user1hq виден (getent/id)" "getent passwd user1hq >/dev/null 2>&1 || id user1hq >/dev/null 2>&1"
    else
        run_wait_check "t1_samba_active" "Служба samba активна" "systemctl is-active --quiet samba" 15
        if check_cmd samba-tool; then
            run_ok_fail_check "t1_group_hq" "Группа hq существует" "samba-tool group list | grep -qx hq"
            run_ok_fail_check "t1_members" "user1hq..user5hq состоят в hq" \
                "m=\$(samba-tool group listmembers hq 2>/dev/null); for u in user1hq user2hq user3hq user4hq user5hq; do echo \"\$m\" | grep -qx \"\$u\" || exit 1; done"
        else
            run_skip_check "t1_group_hq" "Группа hq" "нет команды samba-tool"
            run_skip_check "t1_members" "Члены группы hq" "нет команды samba-tool"
        fi
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 2 — RAID 5
# ═════════════════════════════════════════════════════════════════════════
check_ticket02() {
    info "Билет №2 — RAID 5 (/dev/md0)"
    run_ok_fail_check "t2_active" "Массив /dev/md0 активен (/proc/mdstat)" "grep -A2 'md0' /proc/mdstat | grep -qi 'active'"
    run_ok_fail_check "t2_level5" "Уровень RAID 5" "mdadm --detail /dev/md0 2>/dev/null | grep -qi 'Raid Level : raid5'"
    if check_cmd blkid; then
        run_ok_fail_check "t2_ext4" "Файловая система ext4 на /dev/md0" "blkid /dev/md0 2>/dev/null | grep -q 'TYPE=\"ext4\"'"
    else
        run_skip_check "t2_ext4" "ext4 на /dev/md0" "нет команды blkid"
    fi
    run_ok_fail_check "t2_mount" "/raid5 смонтирован" "mountpoint -q /raid5"
    run_ok_fail_check "t2_fstab" "/raid5 прописан в /etc/fstab" "grep -q '/raid5' /etc/fstab"
    run_ok_fail_check "t2_conf" "/etc/mdadm.conf содержит ARRAY" "grep -q 'ARRAY' /etc/mdadm.conf"
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 3 — NFS
# ═════════════════════════════════════════════════════════════════════════
check_ticket03() {
    info "Билет №3 — NFS"
    ask_side "Что проверяем?  1) HQ-SRV (сервер NFS)   2) HQ-CLI (клиент)"
    if [[ "$REPLY_SIDE" == "2" ]]; then
        run_ok_fail_check "t3_mount" "/mnt/nfs смонтирован" "mountpoint -q /mnt/nfs"
        run_ok_fail_check "t3_fstab" "/mnt/nfs прописан в /etc/fstab" "grep -q '/mnt/nfs' /etc/fstab"
        run_ok_fail_check "t3_write" "Запись в /mnt/nfs возможна" "touch /mnt/nfs/.checkall_test 2>/dev/null && rm -f /mnt/nfs/.checkall_test"
    else
        run_ok_fail_check "t3_service" "Служба NFS активна" "systemctl is-active --quiet nfs-server || systemctl is-active --quiet nfs"
        if check_cmd exportfs; then
            run_ok_fail_check "t3_export" "Каталог /raid5/nfs экспортируется" "exportfs -v 2>/dev/null | grep -q '/raid5/nfs'"
        else
            run_skip_check "t3_export" "Экспорт /raid5/nfs" "нет команды exportfs"
        fi
        run_ok_fail_check "t3_exports_file" "/etc/exports содержит /raid5/nfs" "grep -q '/raid5/nfs' /etc/exports"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 4 — NTP (chrony)
# ═════════════════════════════════════════════════════════════════════════
check_ticket04() {
    info "Билет №4 — NTP (chrony)"
    ask_side "Что проверяем?  1) HQ-RTR (сервер времени)   2) Клиент (HQ-SRV/HQ-CLI/BR-RTR/BR-SRV)"
    run_ok_fail_check "t4_active" "chronyd активен" "systemctl is-active --quiet chronyd"
    if [[ "$REPLY_SIDE" == "1" ]]; then
        run_ok_fail_check "t4_local_stratum" "Конфиг: local stratum 5" "grep -Eq '^[[:space:]]*local[[:space:]]+stratum[[:space:]]+5' /etc/chrony.conf /etc/chrony/chrony.conf 2>/dev/null"
        run_ok_fail_check "t4_allow" "Конфиг: allow (раздача времени)" "grep -Eq '^[[:space:]]*allow' /etc/chrony.conf /etc/chrony/chrony.conf 2>/dev/null"
        if check_cmd chronyc; then
            run_ok_fail_check "t4_stratum_run" "chronyc tracking: Stratum 5" "chronyc tracking 2>/dev/null | grep -Eq 'Stratum[[:space:]]*:[[:space:]]*5'"
        else
            run_skip_check "t4_stratum_run" "chronyc tracking" "нет команды chronyc"
        fi
    else
        if check_cmd chronyc; then
            run_wait_check "t4_synced" "Клиент синхронизирован (chronyc tracking)" "chronyc tracking 2>/dev/null | grep -Eq 'Leap status[[:space:]]*:[[:space:]]*Normal'" 20
            run_ok_fail_check "t4_source" "Есть источник времени (chronyc sources)" "chronyc sources 2>/dev/null | grep -Eq '\\^[*+]'"
        else
            run_skip_check "t4_synced" "Синхронизация клиента" "нет команды chronyc"
            run_skip_check "t4_source" "Источник времени" "нет команды chronyc"
        fi
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 5 — Ansible
# ═════════════════════════════════════════════════════════════════════════
check_ticket05() {
    info "Билет №5 — Ansible (BR-SRV)"
    run_ok_fail_check "t5_installed" "ansible установлен" "command -v ansible"
    run_ok_fail_check "t5_dir" "Рабочий каталог /etc/ansible" "test -d /etc/ansible"
    run_ok_fail_check "t5_inventory" "Инвентарь /etc/ansible/hosts существует" "test -s /etc/ansible/hosts"
    run_ok_fail_check "t5_hosts" "В инвентаре есть hq-srv/hq-cli/hq-rtr/br-rtr" \
        "for h in hq-srv hq-cli hq-rtr br-rtr; do grep -q \"\$h\" /etc/ansible/hosts || exit 1; done"
    if check_cmd ansible; then
        run_ok_fail_check "t5_ping" "ansible all -m ping → pong" "ansible all -m ping 2>/dev/null | grep -q 'pong'"
    else
        run_skip_check "t5_ping" "ansible all -m ping" "нет команды ansible"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 6 — Docker Compose (MediaWiki + MariaDB)
# ═════════════════════════════════════════════════════════════════════════
check_ticket06() {
    info "Билет №6 — Docker Compose (MediaWiki + MariaDB)"
    run_ok_fail_check "t6_docker" "docker активен" "systemctl is-active --quiet docker"
    if check_cmd docker; then
        run_ok_fail_check "t6_wiki" "Контейнер wiki запущен" "docker ps --format '{{.Names}} {{.Image}}' | grep -Eqi 'wiki|mediawiki'"
        run_ok_fail_check "t6_mariadb" "Контейнер mariadb запущен" "docker ps --format '{{.Names}} {{.Image}}' | grep -qi 'mariadb'"
    else
        run_skip_check "t6_wiki" "Контейнер wiki" "нет команды docker"
        run_skip_check "t6_mariadb" "Контейнер mariadb" "нет команды docker"
    fi
    if check_cmd curl; then
        run_wait_check "t6_http" "MediaWiki отвечает на :8080" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080 | grep -Eq '200|301|302'" 20
    else
        run_skip_check "t6_http" "MediaWiki :8080" "нет команды curl"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 7 — Проброс портов
# ═════════════════════════════════════════════════════════════════════════
check_ticket07() {
    info "Билет №7 — Проброс портов (DNAT)"
    ask_side "Что проверяем?  1) HQ-RTR (2024→HQ-SRV)   2) BR-RTR (2024→BR-SRV, 80→8080)"
    run_ok_fail_check "t7_forward" "net.ipv4.ip_forward = 1" "[[ \"\$(sysctl -n net.ipv4.ip_forward 2>/dev/null)\" == '1' ]]"
    if check_cmd iptables; then
        run_ok_fail_check "t7_dnat_2024" "DNAT для TCP 2024" "iptables -t nat -S PREROUTING | grep -E 'dport 2024' | grep -qi DNAT"
        if [[ "$REPLY_SIDE" == "2" ]]; then
            run_ok_fail_check "t7_dnat_80" "DNAT внешнего 80 → :8080" "iptables -t nat -S PREROUTING | grep -E 'dport 80' | grep -qi 'DNAT'"
        fi
    else
        run_skip_check "t7_dnat_2024" "DNAT TCP 2024" "нет команды iptables"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 8 — Moodle
# ═════════════════════════════════════════════════════════════════════════
check_ticket08() {
    info "Билет №8 — Moodle (HQ-SRV)"
    run_ok_fail_check "t8_mariadb" "MariaDB активна" "systemctl is-active --quiet mariadb || systemctl is-active --quiet mysqld"
    run_ok_fail_check "t8_apache" "Apache активен" "systemctl is-active --quiet httpd2 || systemctl is-active --quiet apache2"
    if check_cmd mysql; then
        run_ok_fail_check "t8_db" "База moodledb существует" "mysql -e 'SHOW DATABASES;' 2>/dev/null | grep -qx moodledb"
    else
        run_skip_check "t8_db" "База moodledb" "нет команды mysql"
    fi
    if check_cmd php; then
        run_ok_fail_check "t8_php" "PHP установлен" "php -v"
    else
        run_skip_check "t8_php" "PHP" "нет команды php"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 9 — MariaDB для Moodle
# ═════════════════════════════════════════════════════════════════════════
check_ticket09() {
    info "Билет №9 — MariaDB для Moodle (HQ-SRV)"
    run_ok_fail_check "t9_active" "MariaDB активна" "systemctl is-active --quiet mariadb || systemctl is-active --quiet mysqld"
    if check_cmd mysql; then
        run_ok_fail_check "t9_db" "База moodledb существует" "mysql -e 'SHOW DATABASES;' 2>/dev/null | grep -qx moodledb"
        run_ok_fail_check "t9_user" "Подключение пользователем moodle/P@ssw0rd" "mysql -umoodle -pP@ssw0rd -e 'SELECT 1;'"
        run_ok_fail_check "t9_user_db" "Пользователь moodle видит moodledb" "mysql -umoodle -pP@ssw0rd -e 'SHOW DATABASES;' 2>/dev/null | grep -qx moodledb"
    else
        run_skip_check "t9_db" "База moodledb" "нет команды mysql"
        run_skip_check "t9_user" "Пользователь moodle" "нет команды mysql"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 10 — nginx reverse proxy
# ═════════════════════════════════════════════════════════════════════════
check_ticket10() {
    info "Билет №10 — nginx reverse proxy"
    run_ok_fail_check "t10_active" "nginx активен" "systemctl is-active --quiet nginx"
    if check_cmd nginx; then
        run_ok_fail_check "t10_syntax" "Конфиг nginx валиден (nginx -t)" "nginx -t"
    else
        run_skip_check "t10_syntax" "nginx -t" "нет команды nginx"
    fi
    run_ok_fail_check "t10_proxy_pass" "В конфиге есть proxy_pass" "grep -rq 'proxy_pass' /etc/nginx/ 2>/dev/null"
    run_ok_fail_check "t10_headers" "Передаются заголовки X-Forwarded-For" "grep -rq 'X-Forwarded-For' /etc/nginx/ 2>/dev/null"
    if check_cmd curl; then
        run_ok_fail_check "t10_moodle" "moodle.au-team.irpo отвечает" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: moodle.au-team.irpo' http://localhost | grep -Eq '200|301|302|303'"
        run_ok_fail_check "t10_wiki" "wiki.au-team.irpo отвечает" "curl -s -o /dev/null -w '%{http_code}' -H 'Host: wiki.au-team.irpo' http://localhost | grep -Eq '200|301|302|303'"
    else
        run_skip_check "t10_moodle" "moodle через прокси" "нет команды curl"
        run_skip_check "t10_wiki" "wiki через прокси" "нет команды curl"
    fi
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 11 — sudo для группы hq
# ═════════════════════════════════════════════════════════════════════════
check_ticket11() {
    info "Билет №11 — sudo для группы hq (cat, grep, id)"
    run_ok_fail_check "t11_file" "Файл /etc/sudoers.d/hq существует" "test -f /etc/sudoers.d/hq"
    if check_cmd visudo; then
        run_ok_fail_check "t11_syntax" "Синтаксис sudoers корректен (visudo -c)" "visudo -c"
    else
        run_skip_check "t11_syntax" "visudo -c" "нет команды visudo"
    fi
    run_ok_fail_check "t11_cmds" "Разрешены cat, grep, id" \
        "for c in cat grep id; do grep -qi \"\$c\" /etc/sudoers.d/hq || exit 1; done"
    run_ok_fail_check "t11_no_all" "Нет полного ALL для группы hq" "! grep -E '%.*hq[[:space:]].*=\\(ALL\\)[[:space:]]+ALL[[:space:]]*\$' /etc/sudoers.d/hq"
}

# ═════════════════════════════════════════════════════════════════════════
#  БИЛЕТ 12 — Яндекс Браузер + проверка веб-сервисов
# ═════════════════════════════════════════════════════════════════════════
check_ticket12() {
    info "Билет №12 — Яндекс Браузер + веб-сервисы (HQ-CLI)"
    run_ok_fail_check "t12_browser" "Яндекс Браузер установлен" "command -v yandex-browser yandex_browser yandex-browser-corporate 2>/dev/null | head -n1 | grep -q ."
    if check_cmd getent; then
        run_ok_fail_check "t12_dns_moodle" "DNS: moodle.au-team.irpo резолвится" "getent hosts moodle.au-team.irpo"
        run_ok_fail_check "t12_dns_wiki" "DNS: wiki.au-team.irpo резолвится" "getent hosts wiki.au-team.irpo"
    else
        run_skip_check "t12_dns_moodle" "DNS moodle" "нет команды getent"
        run_skip_check "t12_dns_wiki" "DNS wiki" "нет команды getent"
    fi
    if check_cmd curl; then
        run_ok_fail_check "t12_http_moodle" "HTTP moodle.au-team.irpo" "curl -s -o /dev/null -w '%{http_code}' -L http://moodle.au-team.irpo | grep -Eq '200|301|302|303'"
        run_ok_fail_check "t12_http_wiki" "HTTP wiki.au-team.irpo" "curl -s -o /dev/null -w '%{http_code}' -L http://wiki.au-team.irpo | grep -Eq '200|301|302|303'"
    else
        run_skip_check "t12_http_moodle" "HTTP moodle" "нет команды curl"
        run_skip_check "t12_http_wiki" "HTTP wiki" "нет команды curl"
    fi
}

# ─── Карта: какая машина — какие билеты ─────────────────────────────────
tickets_for_machine() {
    case "$1" in
        br-srv) echo "1 5 6" ;;
        hq-srv) echo "2 3 8 9" ;;
        hq-rtr) echo "4 7 10" ;;
        br-rtr) echo "7" ;;
        hq-cli) echo "1 3 4 11 12" ;;
        *) echo "1 2 3 4 5 6 7 8 9 10 11 12" ;;
    esac
}

run_ticket() {
    case "$1" in
        1) check_ticket01 ;; 2) check_ticket02 ;; 3) check_ticket03 ;;
        4) check_ticket04 ;; 5) check_ticket05 ;; 6) check_ticket06 ;;
        7) check_ticket07 ;; 8) check_ticket08 ;; 9) check_ticket09 ;;
        10) check_ticket10 ;; 11) check_ticket11 ;; 12) check_ticket12 ;;
        *) warn "Неизвестный билет: $1" ;;
    esac
}

# ─── Меню выбора машины ─────────────────────────────────────────────────
detect_role() {
    local h; h="$(hostnamectl --static 2>/dev/null || hostname 2>/dev/null || echo unknown)"
    case "$h" in
        *br-srv*) echo "br-srv" ;; *hq-srv*) echo "hq-srv" ;;
        *hq-rtr*) echo "hq-rtr" ;; *br-rtr*) echo "br-rtr" ;;
        *hq-cli*) echo "hq-cli" ;; *) echo "unknown" ;;
    esac
}

select_machine_menu() {
    local pick
    while true; do
        echo
        echo "Выберите машину, на которой выполняется проверка:"
        echo "  1) BR-SRV   (билеты 1, 5, 6)"
        echo "  2) HQ-SRV   (билеты 2, 3, 8, 9)"
        echo "  3) HQ-RTR   (билеты 4, 7, 10)"
        echo "  4) BR-RTR   (билет 7)"
        echo "  5) HQ-CLI   (билеты 1, 3, 4, 11, 12)"
        echo "  0) выход"
        read -rp "Пункт [0-5]: " pick
        case "$pick" in
            0) info "Отменено."; exit 0 ;;
            1) MACHINE="br-srv"; return ;;
            2) MACHINE="hq-srv"; return ;;
            3) MACHINE="hq-rtr"; return ;;
            4) MACHINE="br-rtr"; return ;;
            5) MACHINE="hq-cli"; return ;;
            *) warn "Некорректный выбор." ;;
        esac
    done
}

# ─── Меню выбора билета ─────────────────────────────────────────────────
select_ticket_menu() {
    local rel pick
    rel="$(tickets_for_machine "$MACHINE")"
    while true; do
        echo
        echo "Машина: ${MACHINE}.  Доступные билеты: ${rel}"
        echo "Что проверить?"
        echo "  a) Все билеты этой машины (${rel})"
        echo "  1) Samba AD DC        7) Проброс портов"
        echo "  2) RAID 5             8) Moodle"
        echo "  3) NFS                9) MariaDB для Moodle"
        echo "  4) NTP (chrony)      10) nginx reverse proxy"
        echo "  5) Ansible           11) sudo для группы hq"
        echo "  6) Docker MediaWiki  12) Яндекс Браузер"
        echo "  0) выход"
        read -rp "Пункт [a / 0-12]: " pick
        case "$pick" in
            0) info "Отменено."; exit 0 ;;
            a|A) CHOSEN="$rel"; return ;;
            [1-9]|10|11|12) CHOSEN="$pick"; return ;;
            *) warn "Некорректный выбор." ;;
        esac
    done
}

print_summary() {
    local ok_count=0 fail_count=0 skip_count=0 key status title
    echo
    echo "================================================================================"
    echo "  ИТОГОВАЯ ТАБЛИЦА ПРОВЕРОК — машина: ${MACHINE}"
    echo "================================================================================"
    printf "%-8s | %s\n" "СТАТУС" "ПРОВЕРКА"
    echo "--------------------------------------------------------------------------------"
    for key in "${RESULT_KEYS[@]}"; do
        status="${RESULT_STATUS[$key]}"; title="${RESULT_TITLE[$key]}"
        case "$status" in
            OK)   printf "${GREEN}%-8s${NC} | %s\n" "[OK]"   "$title"; ok_count=$((ok_count+1)) ;;
            FAIL) printf "${RED}%-8s${NC} | %s\n"   "[FAIL]" "$title"; fail_count=$((fail_count+1)) ;;
            *)    printf "${YELLOW}%-8s${NC} | %s\n" "[SKIP]" "$title"; skip_count=$((skip_count+1)) ;;
        esac
    done
    echo "--------------------------------------------------------------------------------"
    echo "OK: $ok_count | FAIL: $fail_count | SKIP: $skip_count"
    echo "================================================================================"
}

main() {
    echo
    echo "============================================================"
    echo "  check_all.sh — проверка билетов Модуля 2 (au-team.irpo)"
    echo "============================================================"

    local detected use
    detected="$(detect_role)"
    if [[ "$detected" != "unknown" ]]; then
        info "Автоопределена машина: $detected"
        read -rp "Использовать её? [Y/n]: " use
        if [[ "${use,,}" =~ ^n ]]; then select_machine_menu; else MACHINE="$detected"; fi
    else
        warn "Не удалось определить машину по hostname."
        select_machine_menu
    fi

    select_ticket_menu

    echo
    info "Запускаю проверки билетов: ${CHOSEN}"
    local t
    for t in $CHOSEN; do
        echo
        echo "──────────────────────────────────────────────"
        run_ticket "$t"
    done

    print_summary
}

main "$@"
