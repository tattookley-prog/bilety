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

apt-get install -y php8.3-fpm 2>/dev/null || apt-get install -y php-fpm 2>/dev/null || true

# ──────────────────────────────────────────────────────────────
# ШАГ 3: PHP-расширения + включение mysqli в CLI
# ──────────────────────────────────────────────────────────────
step 3 "Установка PHP-расширений и включение mysqli в CLI"

# Определить php.ini и conf.d для CLI
PHP_CLI_INI=$(php --ini 2>/dev/null | grep "Loaded Configuration" | awk '{print $NF}' || true)
PHP_CLI_CONFDIR=$(php --ini 2>/dev/null | grep "Scan for additional" | awk -F': ' '{print $2}' | tr -d ' ' || true)

# ─── ОЧИСТКА: убрать все mysqli-директивы от прошлых запусков ───
# Используем простой sed без pipeline чтобы не упасть на pipefail
info "Очистка ранее добавленных директив mysqli..."
[[ -n "$PHP_CLI_CONFDIR" ]] && [[ -d "$PHP_CLI_CONFDIR" ]] && \
    rm -f "${PHP_CLI_CONFDIR}/20-mysqli.ini" 2>/dev/null || true
[[ -n "$PHP_CLI_INI" ]] && [[ -f "$PHP_CLI_INI" ]] && \
    sed -i '/extension=.*mysqli/d' "$PHP_CLI_INI" 2>/dev/null || true
ok "Очистка выполнена"

# Найти реальный каталог расширений PHP
EXT_DIR=$(php -r "echo ini_get('extension_dir');" 2>/dev/null || true)
info "Каталог расширений PHP: ${EXT_DIR:-не определён}"

# Показать что реально есть для MySQL
if [[ -n "$EXT_DIR" ]] && [[ -d "$EXT_DIR" ]]; then
    MYSQL_EXTS=$(ls "$EXT_DIR/" 2>/dev/null | grep -iE "mysql|pdo" || true)
    info "MySQL-файлы в $EXT_DIR: ${MYSQL_EXTS:-не найдены}"
fi

# Установить PHP-пакеты для MySQL
MYSQLI_PKG_INSTALLED=false
for pkg in php8.3-mysqli php8.3-mysqlnd php-mysqli php-mysqlnd; do
    if apt-cache show "$pkg" &>/dev/null 2>&1; then
        if apt-get install -y "$pkg" 2>/dev/null; then
            ok "Установлен: $pkg"
            MYSQLI_PKG_INSTALLED=true
            break
        fi
    fi
done

# Попытка установить все php8.3 mysql-пакеты из репозитория
MYSQL_PKGS=$(apt-cache search "^php8.3" 2>/dev/null | grep -iE "mysql" | awk '{print $1}' | tr '\n' ' ' || true)
[[ -n "$MYSQL_PKGS" ]] && apt-get install -y $MYSQL_PKGS 2>/dev/null || true

# Остальные модули
apt-get install -y \
    php8.3-xml php8.3-gd php8.3-intl php8.3-mbstring \
    php8.3-curl php8.3-zip php8.3-soap php8.3-opcache 2>/dev/null || \
apt-get install -y \
    php-xml php-gd php-intl php-mbstring \
    php-curl php-zip php-soap 2>/dev/null || true

# Обновить EXT_DIR после установки пакетов
EXT_DIR=$(php -r "echo ini_get('extension_dir');" 2>/dev/null || true)

# Найти mysqli.so который реально существует
MYSQLI_SO=""
if [[ -n "$EXT_DIR" ]] && [[ -d "$EXT_DIR" ]]; then
    MYSQLI_SO=$(find "$EXT_DIR" -name "mysqli.so" 2>/dev/null | head -1 || true)
fi
# Попробовать поискать шире если в EXT_DIR нет
[[ -z "$MYSQLI_SO" ]] && \
    MYSQLI_SO=$(find /usr/lib64/php /usr/lib/php -name "mysqli.so" 2>/dev/null | head -1 || true)

info "mysqli.so: ${MYSQLI_SO:-НЕ НАЙДЕН}"

# ─── Включить mysqli (нужен и для драйвера mariadb!) ───
# Если mysqli уже загружен (пакетом/штатным конфигом) — повторно НЕ добавляем,
# иначе PHP пишет Warning: Module "mysqli" is already loaded.
if php -m 2>/dev/null | grep -qi "^mysqli$"; then
    ok "mysqli уже загружен — повторно не добавляем (убираем Warning 'already loaded')"
elif [[ -n "$MYSQLI_SO" ]] && [[ -f "$MYSQLI_SO" ]]; then
    if [[ -n "$PHP_CLI_CONFDIR" ]] && [[ -d "$PHP_CLI_CONFDIR" ]]; then
        echo "extension=${MYSQLI_SO}" > "${PHP_CLI_CONFDIR}/20-mysqli.ini"
        ok "Включён: ${PHP_CLI_CONFDIR}/20-mysqli.ini → ${MYSQLI_SO}"
    elif [[ -n "$PHP_CLI_INI" ]] && [[ -f "$PHP_CLI_INI" ]]; then
        echo "extension=${MYSQLI_SO}" >> "$PHP_CLI_INI"
        ok "Включён в $PHP_CLI_INI"
    fi
else
    warn "mysqli.so не найден — содержимое каталога расширений:"
    ls "${EXT_DIR:-/nonexistent}" 2>/dev/null | head -20 || true
fi

# ─── max_input_vars >= 5000 (обязательное требование Moodle) ───
if [[ -n "$PHP_CLI_CONFDIR" ]] && [[ -d "$PHP_CLI_CONFDIR" ]]; then
    echo "max_input_vars = 5000" > "${PHP_CLI_CONFDIR}/30-moodle.ini"
    ok "max_input_vars=5000 → ${PHP_CLI_CONFDIR}/30-moodle.ini"
elif [[ -n "$PHP_CLI_INI" ]] && [[ -f "$PHP_CLI_INI" ]]; then
    sed -i '/^[[:space:]]*max_input_vars/d' "$PHP_CLI_INI" 2>/dev/null || true
    echo "max_input_vars = 5000" >> "$PHP_CLI_INI"
    ok "max_input_vars=5000 → $PHP_CLI_INI"
fi
# Для веб-фолбэка продублируем в FPM/общий conf.d, если найдём
for d in /etc/php8.3/conf.d /etc/php/8.3/fpm/conf.d /etc/php/8.3/cli/conf.d /etc/fpm8.3/php-fpm.d; do
    [[ -d "$d" ]] && echo "max_input_vars = 5000" > "$d/30-moodle.ini" 2>/dev/null || true
done

# Итоговая проверка
PHP_MYSQL_MOD=$(php -m 2>/dev/null | grep -iE "^mysqli$" || true)
if [[ -n "$PHP_MYSQL_MOD" ]]; then
    ok "PHP CLI видит mysqli ✓"; STATUS[php_mysql]=OK
else
    warn "mysqli не загружен. Доступные модули: $(php -m 2>/dev/null | grep -iE "mysql|pdo" || echo 'нет')"
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

PHP_FPM_USER=$(grep -rE "^user\s*=" \
    /etc/php8.3/fpm.d/www.conf \
    /etc/php/8.3/fpm/pool.d/www.conf \
    /etc/fpm8.3/php-fpm.d/www.conf 2>/dev/null \
    | head -1 | awk -F'=' '{print $2}' | tr -d ' ' || true)
[[ -z "$PHP_FPM_USER" ]] && \
    PHP_FPM_USER=$(ps aux 2>/dev/null | grep "php-fpm: pool" | grep -v grep | awk '{print $1}' | head -1 || true)
[[ -z "$PHP_FPM_USER" ]] && PHP_FPM_USER="_php_fpm"
info "Пользователь PHP-FPM: $PHP_FPM_USER"

mkdir -p "$DATA"
chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$DATA" 2>/dev/null || \
chown -R "_php_fpm:_webserver" "$DATA" 2>/dev/null || true
chmod 0770 "$DATA"
ok "moodledata: $DATA"
STATUS[data]=OK

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

if [[ -f "$MOODLE_DIR/public/index.php" ]] && \
   ! grep -q "rootdirpublic" "$MOODLE_DIR/public/index.php" 2>/dev/null; then
    WWW="$MOODLE_DIR/public"
else
    WWW="$MOODLE_DIR"
fi
ok "Web-root: $WWW"
chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR" 2>/dev/null || true

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
    # Проверить что mysqli реально доступен перед запуском
    PHP_MYSQL_CHECK=$(php -m 2>/dev/null | grep -iE "^mysqli$" || true)
    if [[ -z "$PHP_MYSQL_CHECK" ]]; then
        error "mysqli не загружен в PHP CLI — CLI-установка невозможна"
        error "Выполните вручную:"
        error "  php -r \"echo ini_get('extension_dir');\""
        error "  apt-cache search php8.3 | grep -i mysql"
        STATUS[cli_install]=ERROR
    else
        # Удалить config.php от прошлых попыток (иначе install.php откажется
        # с 'The configuration file config.php already exists')
        if [[ -f "$MOODLE_DIR/config.php" ]]; then
            warn "Найден старый config.php — удаляю для чистой установки"
            rm -f "$MOODLE_DIR/config.php"
        fi

        # Сбросить БД от прошлых попыток (иначе install.php падает с
        # 'Database tables already present; CLI installation cannot continue').
        # CREATE DATABASE IF NOT EXISTS в Шаге 4 НЕ удаляет старые таблицы,
        # поэтому пересоздаём БД заново для чистой установки.
        warn "Пересоздаю БД '$DB' для чистой установки (старые таблицы Moodle удаляются)"
        mysql <<SQL 2>/dev/null && ok "БД $DB пересоздана (чистая)" || warn "Не удалось пересоздать БД — продолжаю"
DROP DATABASE IF EXISTS ${DB};
CREATE DATABASE ${DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON ${DB}.* TO '${DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL

        info "Запуск CLI-установки (dbtype=mariadb)..."
        info "Это займёт 1-3 минуты"
        echo

        # MariaDB 11.x требует драйвер 'mariadb', а не 'mysqli'
        # (само расширение PHP mysqli при этом всё равно используется драйвером).
        CLI_ARGS=(
            "$CLI"
            "--wwwroot=$WWWROOT"
            "--dataroot=$DATA"
            "--dbtype=mariadb"
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

        # Перейти в каталог Moodle — убирает 'chdir(): Permission denied (errno 13)'
        # когда runuser стартует из недоступного _php_fpm каталога (напр. /root).
        cd "$MOODLE_DIR" 2>/dev/null || cd /tmp

        # Попытка 1: runuser (не требует sudoers)
        if runuser -u "$PHP_FPM_USER" -- php "${CLI_ARGS[@]}" 2>&1; then
            ok "Moodle установлен через CLI!"; STATUS[cli_install]=OK
        else
            warn "Попытка от $PHP_FPM_USER не удалась, пробуем от root..."
            # Перед повтором убираем частичный config.php и сбрасываем БД,
            # иначе install.php откажется ('config.php already exists' /
            # 'Database tables already present').
            rm -f "$MOODLE_DIR/config.php" 2>/dev/null || true
            mysql <<SQL 2>/dev/null || true
DROP DATABASE IF EXISTS ${DB};
CREATE DATABASE ${DB} DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
GRANT ALL PRIVILEGES ON ${DB}.* TO '${DBUSER}'@'localhost';
FLUSH PRIVILEGES;
SQL
            if php "${CLI_ARGS[@]}" 2>&1; then
                ok "Moodle установлен через CLI (от root)!"; STATUS[cli_install]=OK
                chown "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR/config.php" 2>/dev/null || true
            else
                error "CLI-установка не удалась"
                STATUS[cli_install]=ERROR
            fi
        fi

        if [[ "${STATUS[cli_install]:-}" == "OK" ]]; then
            chown -R "$PHP_FPM_USER:$PHP_FPM_USER" "$DATA" 2>/dev/null || true
            chown "$PHP_FPM_USER:$PHP_FPM_USER" "$MOODLE_DIR/config.php" 2>/dev/null || true
            chmod 0440 "$MOODLE_DIR/config.php" 2>/dev/null || true
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
    echo "  БД:           $DB / $DBUSER / $DBPASS"
    echo "  moodledata:   $DATA"
fi
ok "Готово."
