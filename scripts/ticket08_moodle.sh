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
# ШАГ 3: установка PHP-расширений + принудительное включение mysqli в CLI
# ──────────────────────────────────────────────────────────────
step 3 "Установка PHP-расширений и включение mysqli в CLI"

# Установить пакет mysqli
MYSQLI_PKG=""
for pkg in php8.3-mysqli php8.3-mysqlnd php8.3-pdo_mysql php-mysqli php-mysqlnd; do
    if apt-cache show "$pkg" &>/dev/null; then
        MYSQLI_PKG="$pkg"; break
    fi
done

if [[ -n "$MYSQLI_PKG" ]]; then
    apt-get install -y "$MYSQLI_PKG"
    ok "Установлен: $MYSQLI_PKG"
else
    MYSQL_PKGS=$(apt-cache search php8.3 2>/dev/null | grep -i mysql | awk '{print $1}' | tr '\n' ' ')
    [[ -n "$MYSQL_PKGS" ]] && apt-get install -y $MYSQL_PKGS || \
        warn "MySQL-расширение для PHP не найдено в репозитории"
fi

# Остальные модули
apt-get install -y \
    php8.3-xml php8.3-gd php8.3-intl php8.3-mbstring \
    php8.3-curl php8.3-zip php8.3-soap php8.3-opcache 2>/dev/null || \
apt-get install -y \
    php-xml php-gd php-intl php-mbstring \
    php-curl php-zip php-soap 2>/dev/null || true

# ─── КЛЮЧЕВОЕ ИСПРАВЛЕНИЕ: принудительно включить mysqli в CLI php.ini ───
# mysqlnd != mysqli. CLI php.ini на Альт Линукс может не загружать mysqli
# автоматически даже после установки пакета.
info "Проверяем и включаем mysqli в PHP CLI..."

PHP_CLI_INI=$(php --ini 2>/dev/null | grep "Loaded Configuration" | awk '{print $NF}' || echo "")
PHP_CLI_CONFDIR=$(php --ini 2>/dev/null | grep "Scan for additional" | awk -F': ' '{print $2}' | tr -d ' ' || echo "")

if ! php -m 2>/dev/null | grep -qi "^mysqli$"; then
    info "mysqli не загружен в CLI, включаем..."

    # Найти mysqli.so
    MYSQLI_SO=$(find /usr/lib /usr/lib64 /usr/local/lib -name "mysqli.so" 2>/dev/null | head -1 || true)

    if [[ -n "$PHP_CLI_CONFDIR" ]] && [[ -d "$PHP_CLI_CONFDIR" ]]; then
        # Добавить через conf.d (предпочтительно)
        if [[ -n "$MYSQLI_SO" ]]; then
            echo "extension=${MYSQLI_SO}" > "${PHP_CLI_CONFDIR}/20-mysqli.ini"
        else
            echo "extension=mysqli" > "${PHP_CLI_CONFDIR}/20-mysqli.ini"
        fi
        ok "Добавлен ${PHP_CLI_CONFDIR}/20-mysqli.ini"
    elif [[ -n "$PHP_CLI_INI" ]] && [[ -f "$PHP_CLI_INI" ]]; then
        # Добавить прямо в php.ini
        if ! grep -q "extension=mysqli" "$PHP_CLI_INI"; then
            if [[ -n "$MYSQLI_SO" ]]; then
                echo "extension=${MYSQLI_SO}" >> "$PHP_CLI_INI"
            else
                echo "extension=mysqli" >> "$PHP_CLI_INI"
            fi
            ok "mysqli добавлен в $PHP_CLI_INI"
        fi
    fi
fi

# Итоговая проверка
if php -m 2>/dev/null | grep -qi "^mysqli$"; then
    ok "PHP CLI видит mysqli ✓"; STATUS[php_mysql]=OK
else
    warn "mysqli всё ещё не загружен. CLI php.ini: ${PHP_CLI_INI:-неизвестен}"
    warn "Попробуйте вручную: echo 'extension=mysqli' >> ${PHP_CLI_INI:-/etc/php/8.3/cli/php.ini}"
    STATUS[php_mysql]=ERROR
fi

# ──────────────────────────────────────────────────────────────
# ШАГ 4: MariaDB + создание БД
# ──────────────────────────────────────────────────────────────
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
PHP_FPM_USER=$(grep -rE "^user\s*=" \
    /etc/php8.3/fpm.d/www.conf \
    /etc/php/8.3/fpm/pool.d/www.conf \
    /etc/fpm8.3/php-fpm.d/www.conf 2>/dev/null \
    | head -1 | awk -F'=' '{print $2}' | tr -d ' ' || true)
[[ -z "$PHP_FPM_USER" ]] && \
    PHP_FPM_USER=$(ps aux 2>/dev/null | grep "php-fpm: pool" | grep -v grep | awk '{print $1}' | head -1 || true)
[[ -z "$PHP_FPM_USER" ]] && PHP_FPM_USER="_php_fpm"
info "Пользователь PHP-FPM: $PHP_FPM_USER"

# Создать moodledata
mkdir -p "$DATA"
chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$DATA" 2>/dev/null || \
chown -R "_php_fpm:_webserver" "$DATA" 2>/dev/null || true
chmod 0770 "$DATA"
ok "moodledata: $DATA"
STATUS[data]=OK

# Найти путь к Moodle
info "Ищем каталог Moodle..."
MOODLE_DIR=""
for candidate in /var/www/webapps/moodle /var/www/html/moodle /usr/share/moodle; do
    if [[ -f "$candidate/admin/cli/install.php" ]]; then
        MOODLE_DIR="$candidate"; ok "Moodle найден: $MOODLE_DIR"; break
    fi
done
[[ -z "$MOODLE_DIR" ]] && \
    MOODLE_DIR=$(find /var/www /usr/share -name "install.php" -path "*/admin/cli/*" 2>/dev/null \
                 | head -1 | sed 's|/admin/cli/install.php||' || true)
[[ -z "$MOODLE_DIR" ]] && { warn "Каталог Moodle не найден!"; MOODLE_DIR="/var/www/webapps/moodle"; }

# Web-root (public/ для Moodle 4.5+)
if [[ -f "$MOODLE_DIR/public/index.php" ]] && \
   ! grep -q "rootdirpublic" "$MOODLE_DIR/public/index.php" 2>/dev/null; then
    WWW="$MOODLE_DIR/public"
else
    WWW="$MOODLE_DIR"
fi
ok "Web-root: $WWW"
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
[[ -z "$FPM_SOCK" ]] && \
    FPM_SOCK=$(find /run /var/run -name "*.sock" 2>/dev/null | grep -i php | head -1 || true)
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
# ШАГ 7: CLI-установка Moodle
# ──────────────────────────────────────────────────────────────
step 7 "CLI-установка Moodle (admin/cli/install.php)"

CLI="$MOODLE_DIR/admin/cli/install.php"
if [[ ! -f "$CLI" ]]; then
    error "Файл $CLI не найден — пакет moodle не установлен?"
    STATUS[cli_install]=ERROR
else
    # Определить тип БД: Moodle 5.x принимает только 'mysqli'
    DBTYPE="mysqli"
    info "Используем --dbtype=$DBTYPE"
    info "Это займёт 1-3 минуты — виден прогресс создания таблиц БД"
    echo

    CLI_ARGS=(
        "$CLI"
        "--wwwroot=$WWWROOT"
        "--dataroot=$DATA"
        "--dbtype=$DBTYPE"
        "--dbhost=localhost"
        "--dbname=$DB"
        "--dbuser=$DBUSER"
        "--dbpass=$DBPASS"
        "--fullname=$SITENAME"
        "--shortname=$SITENAME"
        "--adminuser=$ADM_USER"
        "--adminpass=$ADM_PASS"
        "--non-interactive"
        "--agree-license"
    )

    # Попытка 1: от PHP-FPM пользователя через runuser (не требует sudoers)
    if runuser -u "$PHP_FPM_USER" -- php "${CLI_ARGS[@]}" 2>&1; then
        ok "Moodle установлен через CLI!"; STATUS[cli_install]=OK

    else
        warn "Попытка от $PHP_FPM_USER не удалась, пробуем от root..."

        # Попытка 2: от root напрямую
        if php "${CLI_ARGS[@]}" 2>&1; then
            ok "Moodle установлен через CLI (от root)!"; STATUS[cli_install]=OK
            # Исправить владельца config.php
            chown "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR/config.php" 2>/dev/null || true

        else
            error "CLI-установка не удалась"
            error "Диагностика:"
            error "  php -m | grep -i mysqli"
            error "  mysql -u$DBUSER -p$DBPASS $DB"
            STATUS[cli_install]=ERROR
        fi
    fi

    # Исправить права на moodledata и config.php после установки
    if [[ "${STATUS[cli_install]:-}" == "OK" ]]; then
        chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$DATA" 2>/dev/null || true
        chown "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR/config.php" 2>/dev/null || true
        chmod 0440 "$MOODLE_DIR/config.php" 2>/dev/null || true
    fi
fi

# ────────────────────���─────────────────────────────────────────
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
