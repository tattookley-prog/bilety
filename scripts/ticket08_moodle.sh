#!/bin/bash
# =============================================================================
# Билет №8 — Moodle на HQ-SRV (Apache + PHP + MariaDB + Moodle)
# БД moodledb, пользователь moodle / P@ssw0rd, админ Moodle P@ssw0rd.
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
echo "  Билет №8 — Moodle (HQ-SRV)"
echo "============================================================"
echo
read -rp "Имя БД [moodledb]: " DB; DB="${DB:-moodledb}"
read -rp "Пользователь БД [moodle]: " DBUSER; DBUSER="${DBUSER:-moodle}"
read -rp "Пароль БД [P@ssw0rd]: " DBPASS; DBPASS="${DBPASS:-P@ssw0rd}"
read -rp "Каталог DocumentRoot Moodle [/var/www/html/moodle]: " WWW; WWW="${WWW:-/var/www/html/moodle}"
read -rp "Каталог moodledata [/var/moodledata]: " DATA; DATA="${DATA:-/var/moodledata}"

echo
info "БД $DB, пользователь $DBUSER, DocumentRoot $WWW"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Установка Apache, PHP, MariaDB, Moodle..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y apache2 mariadb-server moodle >/dev/null 2>&1 || \
apt-get install -y httpd2 mariadb-server moodle >/dev/null 2>&1 || warn "Проверьте пакеты вручную (apache2/php*/mariadb-server/moodle)"
# PHP-модули (имена могут отличаться по версии)
apt-get install -y php php-mysqli php-xml php-gd php-intl php-mbstring php-curl php-zip php-soap >/dev/null 2>&1 || true
ok "Пакеты установлены"
STATUS[install]=OK

info "Запуск MariaDB..."
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || true
sleep 2

info "Создание БД и пользователя..."
mysql <<SQL 2>/dev/null && { ok "БД $DB и пользователь $DBUSER готовы"; STATUS[db]=OK; } || { error "Ошибка создания БД"; STATUS[db]=ERROR; }
CREATE DATABASE IF NOT EXISTS ${DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON ${DB}.* TO '${DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL

info "Каталог данных moodledata..."
mkdir -p "$DATA"
WWWUSER="apache"; id apache &>/dev/null || WWWUSER="www-data"
chown -R "$WWWUSER:$WWWUSER" "$DATA"
chmod 0770 "$DATA"
[[ -d "$WWW" ]] && chown -R "$WWWUSER:$WWWUSER" "$WWW" 2>/dev/null || true
ok "moodledata: $DATA (владелец $WWWUSER)"
STATUS[data]=OK

info "Настройка Apache (DocumentRoot $WWW)..."
VHOST="/etc/httpd2/conf/sites-available/moodle.conf"
[[ -d /etc/apache2/sites-available ]] && VHOST="/etc/apache2/sites-available/moodle.conf"
mkdir -p "$(dirname "$VHOST")" 2>/dev/null || true
cat > "$VHOST" <<EOF
<VirtualHost *:80>
    DocumentRoot ${WWW}
    <Directory ${WWW}>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
a2ensite moodle 2>/dev/null || true
a2enmod php 2>/dev/null || true
for svc in httpd2 apache2; do systemctl enable --now "$svc" 2>/dev/null && systemctl restart "$svc" 2>/dev/null && { ok "$svc запущен"; STATUS[apache]=OK; break; }; done
[[ "${STATUS[apache]:-}" == "OK" ]] || { warn "Проверьте службу Apache вручную"; STATUS[apache]=ERROR; }

echo
ok "Базовая установка завершена."
info "Далее завершите установку через веб-интерфейс:"
echo "  http://<HQ-SRV>/moodle  (или http://moodle.au-team.irpo после билета №10)"
echo "  БД:        ${DB}"
echo "  Пользователь: ${DBUSER} / ${DBPASS}"
echo "  moodledata: ${DATA}"
echo "  Админ Moodle: admin / P@ssw0rd (задать в мастере)"
echo "  На главной странице укажите номер рабочего места одной цифрой"

echo
echo "============================================================"
echo "  Итог — Билет №8"
echo "============================================================"
for k in install db data apache; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово."
