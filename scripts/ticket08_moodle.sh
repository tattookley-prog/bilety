#!/bin/bash
# =============================================================================
# Билет №8 — Moodle на HQ-SRV (Apache + PHP-FPM + MariaDB + Moodle)
# Установка БЕЗ веб-мастера — через admin/cli/install.php (как билет №6).
# БД moodledb, пользователь moodle / P@ssw0rd, админ admin / P@ssw0rd.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${BOLD}──────────────────────────────────────────────${NC}"; \
          echo -e "${BOLD}  Шаг $1/$TOTAL_STEPS: $2${NC}"; \
          echo -e "${BOLD}──────────────────────────────────────────────${NC}"; }

TOTAL_STEPS=7

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

declare -A STATUS

echo
echo "============================================================"
echo "  Билет №8 — Moodle (HQ-SRV), CLI-установка"
echo "============================================================"
echo
read -rp "Имя БД [moodledb]: "              DB;         DB="${DB:-moodledb}"
read -rp "Пользователь БД [moodle]: "       DBUSER;     DBUSER="${DBUSER:-moodle}"
read -rp "Пароль БД [P@ssw0rd]: "           DBPASS;     DBPASS="${DBPASS:-P@ssw0rd}"
read -rp "Каталог moodledata [/var/moodledata]: " DATA;  DATA="${DATA:-/var/moodledata}"
read -rp "Имя сайта Moodle [AU-TEAM]: "     SITENAME;   SITENAME="${SITENAME:-AU-TEAM}"
read -rp "Логин администратора [admin]: "   ADM_USER;   ADM_USER="${ADM_USER:-admin}"
read -rp "Пароль администратора [P@ssw0rd]: " ADM_PASS; ADM_PASS="${ADM_PASS:-P@ssw0rd}"

# Определить IP сервера
MY_IP="$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}')"
MY_IP="${MY_IP:-192.168.1.2}"
read -rp "URL Moodle [http://${MY_IP}/moodle]: " WWWROOT
WWWROOT="${WWWROOT:-http://${MY_IP}/moodle}"

echo
info "БД: $DB, пользователь: $DBUSER, URL: $WWWROOT"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

# ──────────────────────────────────────────────────────────────
# ШАГ 1: обновление списка пакетов
# ──────────────────────────────────────────────────────────────
step 1 "Обновление списка пакетов (apt-get update)"
apt-get update
ok "Список пакетов обновлён"

# ──────────────────────────────────────────────────────────────
# ШАГ 2: установка Apache, MariaDB, Moodle, PHP-FPM
# ──────────────────────────────────────────────────────────────
step 2 "Установка Apache, MariaDB, Moodle, PHP-FPM"
info "Это самый долгий шаг — следите за строками «Unpacking / Setting up»"
echo

if apt-get install -y httpd2 mariadb-server moodle; then
    ok "Основные пакеты (httpd2 mariadb-server moodle) установлены"
    STATUS[install]=OK
elif apt-get install -y apache2 mariadb-server moodle; then
    ok "Основные пакеты (apache2 mariadb-server moodle) установлены"
    STATUS[install]=OK
else
    warn "Не удалось установить автоматически — проверьте пакеты вручную"
    STATUS[install]=ERROR
fi

# PHP-FPM
info "Установка PHP-FPM..."
apt-get install -y php8.3-fpm 2>/dev/null || apt-get install -y php-fpm 2>/dev/null || true

# ──────────────────────────────────────────────────────────────
# ШАГ 3: установка PHP-расширений (особенно mysqli/mysqlnd)
# ──────────────────────────────────────────────────────────────
step 3 "Установка PHP-расширений"
info "Ищем пакет mysqli/mysqlnd в репозитории..."

# Найти доступный пакет mysqli
MYSQLI_PKG=""
for pkg in php8.3-mysqli php8.3-mysqlnd php8.3-pdo_mysql \
           php-mysqli php-mysqlnd; do
    if apt-cache show "$pkg" &>/dev/null; then
        MYSQLI_PKG="$pkg"
        info "Найден пакет: $MYSQLI_PKG"
        break
    fi
done

if [[ -n "$MYSQLI_PKG" ]]; then
    apt-get install -y "$MYSQLI_PKG"
    ok "Установлен: $MYSQLI_PKG"
else
    # Установить всё что содержит mysql в имени для php8.3
    info "Ищем все php8.3-*mysql* пакеты..."
    MYSQL_PKGS=$(apt-cache search php8.3 2>/dev/null | grep -i mysql | awk '{print $1}' | tr '\n' ' ')
    if [[ -n "$MYSQL_PKGS" ]]; then
        apt-get install -y $MYSQL_PKGS
        ok "Установлено: $MYSQL_PKGS"
    else
        warn "MySQL-расширение для PHP не найдено — CLI-установка может не пройти"
    fi
fi

# Остальные модули
apt-get install -y \
    php8.3-xml php8.3-gd php8.3-intl php8.3-mbstring \
    php8.3-curl php8.3-zip php8.3-soap php8.3-opcache 2>/dev/null || \
apt-get install -y \
    php-xml php-gd php-intl php-mbstring \
    php-curl php-zip php-soap 2>/dev/null || true
ok "PHP-расширения обработаны"

# Проверка
PHP_HAS_MYSQL=$(php -m 2>/dev/null | grep -iE "mysqli|mysqlnd|pdo_mysql" | head -1 || true)
if [[ -n "$PHP_HAS_MYSQL" ]]; then
    ok "PHP видит MySQL-расширение: $PHP_HAS_MYSQL"
    STATUS[php_mysql]=OK
else
    warn "PHP не видит MySQL-расширение — CLI-установка может не пройти"
    warn "Попробуйте вручную: apt-cache search php8.3 | grep -i mysql"
    STATUS[php_mysql]=ERROR
fi

# ──────────────────────────────────────────────────────────────
# ШАГ 4: MariaDB + создание БД
# ─────────────────────────────────��────────────────────────────
step 4 "Запуск MariaDB и создание БД / пользователя"
info "Запуск MariaDB..."
systemctl enable --now mariadb 2>/dev/null || systemctl enable --now mysqld 2>/dev/null || true
sleep 2

info "Создание БД '$DB' и пользователя '$DBUSER'..."
mysql <<SQL && { ok "БД $DB и пользователь $DBUSER готовы"; STATUS[db]=OK; } \
           || { error "Ошибка создания БД"; STATUS[db]=ERROR; }
CREATE DATABASE IF NOT EXISTS ${DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON ${DB}.* TO '${DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL

# ──────────────────────────────────────────────────────────────
# ШАГ 5: moodledata + определение путей
# ──────────────────────────────────────────────────────────────
step 5 "moodledata, пути Moodle, PHP-FPM"

# Определить пользователя PHP-FPM
PHP_FPM_USER=$(grep -rE "^user\s*=" /etc/php8.3/fpm.d/www.conf \
                         /etc/php/8.3/fpm/pool.d/www.conf \
                         /etc/fpm8.3/php-fpm.d/www.conf 2>/dev/null \
               | head -1 | awk -F'=' '{print $2}' | tr -d ' ' || true)
[[ -z "$PHP_FPM_USER" ]] && PHP_FPM_USER=$(ps aux 2>/dev/null | grep "php-fpm: pool" | grep -v grep | awk '{print $1}' | head -1 || true)
[[ -z "$PHP_FPM_USER" ]] && PHP_FPM_USER="_php_fpm"
info "Пользователь PHP-FPM: $PHP_FPM_USER"

# Создать moodledata
mkdir -p "$DATA"
chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$DATA" 2>/dev/null || \
chown -R "_php_fpm:_webserver" "$DATA" 2>/dev/null || true
chmod 0770 "$DATA"
ok "moodledata: $DATA"
STATUS[data]=OK

# Найти путь к Moodle (public/ или корень)
info "Ищем каталог Moodle..."
MOODLE_DIR=""
for candidate in \
    /var/www/webapps/moodle \
    /var/www/html/moodle \
    /usr/share/moodle; do
    if [[ -f "$candidate/admin/cli/install.php" ]]; then
        MOODLE_DIR="$candidate"
        ok "Moodle найден: $MOODLE_DIR"
        break
    fi
done
[[ -z "$MOODLE_DIR" ]] && MOODLE_DIR=$(find /var/www /usr/share -name "install.php" -path "*/admin/cli/*" 2>/dev/null | head -1 | sed 's|/admin/cli/install.php||' || true)
[[ -z "$MOODLE_DIR" ]] && { warn "Каталог Moodle не найден! Пакет установлен?"; MOODLE_DIR="/var/www/webapps/moodle"; }

# Определить web-root (public/ для Moodle 4.5+, иначе сам каталог)
if [[ -f "$MOODLE_DIR/public/index.php" ]] && ! grep -q "rootdirpublic" "$MOODLE_DIR/public/index.php" 2>/dev/null; then
    WWW="$MOODLE_DIR/public"
else
    WWW="$MOODLE_DIR"
fi
ok "Web-root Moodle: $WWW"

# Права на каталог Moodle
chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR" 2>/dev/null || true

# Найти сокет PHP-FPM
info "Ищем сокет PHP-FPM..."
systemctl enable --now php8.3-fpm 2>/dev/null || systemctl enable --now php-fpm 2>/dev/null || true
sleep 2
FPM_SOCK=""
for sock in \
    /run/php8.3-fpm/php8.3-fpm.sock \
    /run/php/php8.3-fpm.sock \
    /run/php/php-fpm.sock \
    /var/run/php8.3-fpm/php8.3-fpm.sock \
    /var/run/php-fpm/php-fpm.sock; do
    [[ -S "$sock" ]] && { FPM_SOCK="$sock"; ok "Сокет: $FPM_SOCK"; break; }
done
[[ -z "$FPM_SOCK" ]] && FPM_SOCK=$(find /run /var/run -name "*.sock" 2>/dev/null | grep -i php | head -1 || true)
[[ -z "$FPM_SOCK" ]] && warn "Сокет не найден — используем TCP 127.0.0.1:9000"

# ──────────────────────────────────────────────────────────────
# ШАГ 6: Настройка Apache + PHP-FPM
# ──────────────────────────────────────────────────────────────
step 6 "Настройка Apache и PHP-FPM"

CONF="/etc/httpd2/conf.d/moodle.conf"
[[ -d /etc/apache2/sites-available ]] && CONF="/etc/apache2/sites-available/moodle.conf"
mkdir -p "$(dirname "$CONF")" 2>/dev/null || true

if [[ -n "$FPM_SOCK" ]]; then
    PHP_HANDLER="SetHandler \"proxy:unix:${FPM_SOCK}|fcgi://localhost\""
else
    PHP_HANDLER='SetHandler "proxy:fcgi://127.0.0.1:9000"'
fi

cat > "$CONF" <<EOF
Alias /moodle ${WWW}

<Directory ${WWW}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
    <FilesMatch \.php\$>
        ${PHP_HANDLER}
    </FilesMatch>
</Directory>
EOF

a2enmod proxy      2>/dev/null || true
a2enmod proxy_fcgi 2>/dev/null || true
a2ensite moodle    2>/dev/null || true
systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php-fpm 2>/dev/null || true

for svc in httpd2 apache2; do
    if systemctl enable --now "$svc" 2>/dev/null && systemctl restart "$svc" 2>/dev/null; then
        ok "$svc запущен"; STATUS[apache]=OK; break
    fi
done
[[ "${STATUS[apache]:-}" == "OK" ]] || { warn "Проверьте Apache вручную"; STATUS[apache]=ERROR; }

# ──────────────────────────────────────────────────────────────
# ШАГ 7: CLI-установка Moodle (без веб-мастера, как билет №6)
# ──────────────────────────────────────────────────────────────
step 7 "CLI-установка Moodle (admin/cli/install.php)"

CLI="$MOODLE_DIR/admin/cli/install.php"
if [[ ! -f "$CLI" ]]; then
    error "Файл $CLI не найден — пакет moodle не установлен?"
    STATUS[cli_install]=ERROR
else
    # Определить тип БД для install.php
    # Moodle 4.5+ (включая 5.x) не принимает 'mariadb' — только 'mysqli'
    # Попробуем оба варианта
    DBTYPE="mysqli"
    info "Используем --dbtype=$DBTYPE (совместимо с Moodle 4.x и 5.x)"

    info "Запуск $CLI ..."
    info "Это займёт 1-3 минуты — виден прогресс создания таблиц БД"
    echo

    run_cli() {
        local run_as="$1"
        local cmd=(php "$CLI"
            --wwwroot="$WWWROOT"
            --dataroot="$DATA"
            --dbtype="$DBTYPE"
            --dbhost=localhost
            --dbname="$DB"
            --dbuser="$DBUSER"
            --dbpass="$DBPASS"
            --fullname="$SITENAME"
            --shortname="$SITENAME"
            --adminuser="$ADM_USER"
            --adminpass="$ADM_PASS"
            --non-interactive
            --agree-license)

        if [[ "$run_as" == "root" ]]; then
            "${cmd[@]}"
        else
            sudo -u "$run_as" "${cmd[@]}"
        fi
    }

    # Попытка 1: от PHP-FPM пользователя
    if run_cli "$PHP_FPM_USER" 2>&1; then
        ok "Moodle установлен через CLI!"; STATUS[cli_install]=OK
    else
        warn "Попытка от $PHP_FPM_USER не удалась, пробуем от root..."
        # Попытка 2: от root
        if run_cli "root" 2>&1; then
            ok "Moodle установлен через CLI (от root)!"; STATUS[cli_install]=OK
            chown "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR/config.php" 2>/dev/null || true
        else
            # Попытка 3: --dbtype=mariadb (старые версии Moodle)
            warn "Пробуем --dbtype=mariadb (для старых версий Moodle)..."
            DBTYPE="mariadb"
            if run_cli "root" 2>&1; then
                ok "Moodle установлен (dbtype=mariadb)!"; STATUS[cli_install]=OK
                chown "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR/config.php" 2>/dev/null || true
            else
                error "CLI-установка не удалась всеми способами"
                error "Частые причины:"
                error "  - PHP не видит mysqli: php -m | grep -i mysql"
                error "  - БД недоступна: mysql -u$DBUSER -p$DBPASS $DB"
                STATUS[cli_install]=ERROR
            fi
        fi
    fi
fi

# ──────────────────────────────────────────────────────────────
# Итог
# ──────────────────────────────────────────────────────────────
echo
echo "============================================================"
echo "  Итог — Билет №8"
echo "============================================================"
for k in install php_mysql db data apache cli_install; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
echo

if [[ "${STATUS[cli_install]:-}" == "OK" ]]; then
    ok "Moodle готов! Веб-мастер не нужен."
    echo
    echo "  URL:      $WWWROOT"
    echo "  Логин:    $ADM_USER"
    echo "  Пароль:   $ADM_PASS"
    echo "  На главной странице укажи номер рабочего места (одна цифра)"
else
    warn "CLI-установка не удалась. Попробуй веб-мастер: $WWWROOT"
    echo "  БД:           $DB"
    echo "  Пользователь: $DBUSER / $DBPASS"
    echo "  moodledata:   $DATA"
fi
ok "Готово."
