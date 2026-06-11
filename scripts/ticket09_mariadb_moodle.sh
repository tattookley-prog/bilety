#!/bin/bash
# =============================================================================
# Билет №9 — MariaDB для Moodle на HQ-SRV
# БД moodledb, пользователь moodle / P@ssw0rd, права, проверка подключения.
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
echo "  Билет №9 — MariaDB для Moodle (HQ-SRV)"
echo "============================================================"
echo
read -rp "Имя БД [moodledb]: " DB; DB="${DB:-moodledb}"
read -rp "Пользователь БД [moodle]: " DBUSER; DBUSER="${DBUSER:-moodle}"
read -rp "Пароль БД [P@ssw0rd]: " DBPASS; DBPASS="${DBPASS:-P@ssw0rd}"

echo
info "БД $DB, пользователь $DBUSER"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Установка MariaDB..."
if ! command -v mysql >/dev/null 2>&1; then
    apt-get update -y || true
    apt-get install -y mariadb-server || warn "Проверьте пакет mariadb-server"
fi
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || true
sleep 2
command -v mysql >/dev/null 2>&1 && { ok "MariaDB доступна"; STATUS[install]=OK; } || STATUS[install]=ERROR

info "Создание БД, пользователя и выдача прав..."
if mysql <<SQL 2>/dev/null
CREATE DATABASE IF NOT EXISTS ${DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON ${DB}.* TO '${DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL
then
    ok "БД $DB и пользователь $DBUSER созданы, права выданы"; STATUS[create]=OK
else
    error "Ошибка SQL"; STATUS[create]=ERROR
fi

echo; info "Проверка подключения от имени $DBUSER..."
if mysql -u"$DBUSER" -p"$DBPASS" -e "SELECT 'OK';" >/dev/null 2>&1; then
    ok "Подключение пользователя $DBUSER успешно"; STATUS[connect]=OK
else
    error "Не удалось подключиться пользователем $DBUSER"; STATUS[connect]=ERROR
fi

echo; info "Список баз данных (подтверждение наличия $DB):"
mysql -u"$DBUSER" -p"$DBPASS" -e "SHOW DATABASES;" 2>/dev/null || mysql -e "SHOW DATABASES;" 2>/dev/null || true

echo
echo "============================================================"
echo "  Итог — Билет №9"
echo "============================================================"
for k in install create connect; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. SQL для отчёта выведены выше."

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
systemctl is-active mariadb || systemctl is-active mysqld            # Статус MariaDB
mysql -e "SHOW DATABASES;"                                            # Наличие moodledb
mysql -e "SELECT User,Host FROM mysql.user WHERE User='moodle';"      # Пользователь moodle
mysql -e "SHOW GRANTS FOR 'moodle'@'localhost';"                      # Права пользователя moodle
mysql -umoodle -pP@ssw0rd -e "SELECT 'OK';"                           # Вход под moodle-пользователем
EOF
