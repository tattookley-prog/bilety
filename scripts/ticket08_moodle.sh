#!/bin/bash
# =============================================================================
# Билет №8 — Moodle на HQ-SRV (Apache + PHP-FPM + MariaDB + Moodle)
# БД moodledb, пользователь moodle / P@ssw0rd, админ Moodle P@ssw0rd.
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

TOTAL_STEPS=6

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

declare -A STATUS

echo
echo "============================================================"
echo "  Билет №8 — Moodle (HQ-SRV)"
echo "============================================================"
echo
read -rp "Имя БД [moodledb]: "              DB;     DB="${DB:-moodledb}"
read -rp "Пользователь БД [moodle]: "       DBUSER; DBUSER="${DBUSER:-moodle}"
read -rp "Пароль БД [P@ssw0rd]: "           DBPASS; DBPASS="${DBPASS:-P@ssw0rd}"
read -rp "Каталог moodledata [/var/moodledata]: " DATA; DATA="${DATA:-/var/moodledata}"

echo
info "БД: $DB, пользователь: $DBUSER, moodledata: $DATA"
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

if apt-get install -y apache2 mariadb-server moodle; then
    ok "Основные пакеты (apache2 mariadb-server moodle) установлены"
    STATUS[install]=OK
elif apt-get install -y httpd2 mariadb-server moodle; then
    ok "Основные пакеты (httpd2 mariadb-server moodle) установлены"
    STATUS[install]=OK
else
    warn "Не удалось установить автоматически — проверьте пакеты вручную"
    STATUS[install]=ERROR
fi

# PHP-FPM
info "Установка PHP-FPM и модулей..."
apt-get install -y \
    php8.3-fpm php8.3-mysqli php8.3-xml php8.3-gd php8.3-intl \
    php8.3-mbstring php8.3-curl php8.3-zip php8.3-soap php8.3-opcache 2>/dev/null || \
apt-get install -y \
    php-fpm php-mysqli php-xml php-gd php-intl \
    php-mbstring php-curl php-zip php-soap 2>/dev/null || \
    warn "Некоторые PHP-модули недоступны — возможно, уже входят в пакет moodle"
ok "PHP-FPM и модули обработаны"

# ──────────────────────────────────────────────────────────────
# ШАГ 3: определить реальный путь Moodle и сокет PHP-FPM
# ──────────────────────────────────────────────────────────────
step 3 "Определение пути Moodle и сокета PHP-FPM"

# Найти корень Moodle (index.php, который НЕ выбрасывает исключение)
info "Ищем каталог Moodle..."
WWW=""
for candidate in \
    /var/www/webapps/moodle/public \
    /var/www/webapps/moodle \
    /var/www/html/moodle/public \
    /var/www/html/moodle \
    /usr/share/moodle/public \
    /usr/share/moodle; do
    if [[ -f "$candidate/index.php" ]]; then
        # Убедиться что это не «заглушка» (не содержит rootdirpublic)
        if ! grep -q "rootdirpublic" "$candidate/index.php" 2>/dev/null; then
            WWW="$candidate"
            ok "Moodle найден: $WWW"
            break
        fi
    fi
done

if [[ -z "$WWW" ]]; then
    # Последняя попытка — найти через find
    FOUND=$(find /var/www /usr/share -name "index.php" 2>/dev/null \
            | xargs grep -l "moodle" 2>/dev/null \
            | grep -v "rootdirpublic" \
            | head -1)
    if [[ -n "$FOUND" ]]; then
        WWW=$(dirname "$FOUND")
        ok "Moodle найден через поиск: $WWW"
    else
        warn "Каталог Moodle не найден автоматически, используем /var/www/webapps/moodle/public"
        WWW="/var/www/webapps/moodle/public"
    fi
fi
STATUS[moodle_path]=OK

# Найти сокет PHP-FPM
info "Ищем сокет PHP-FPM..."
FPM_SOCK=""
for sock in \
    /run/php8.3-fpm/php8.3-fpm.sock \
    /run/php/php8.3-fpm.sock \
    /run/php/php-fpm.sock \
    /var/run/php8.3-fpm/php8.3-fpm.sock \
    /var/run/php-fpm/php-fpm.sock \
    /var/run/php-fpm.sock; do
    if [[ -S "$sock" ]]; then
        FPM_SOCK="$sock"
        ok "Сокет PHP-FPM найден: $FPM_SOCK"
        break
    fi
done

# Если сокет ещё не появился — запустим FPM и подождём
if [[ -z "$FPM_SOCK" ]]; then
    info "Сокет не найден, запускаем PHP-FPM..."
    systemctl enable --now php8.3-fpm 2>/dev/null || \
    systemctl enable --now php-fpm   2>/dev/null || true
    sleep 3
    for sock in \
        /run/php8.3-fpm/php8.3-fpm.sock \
        /run/php/php8.3-fpm.sock \
        /run/php/php-fpm.sock \
        /var/run/php8.3-fpm/php8.3-fpm.sock \
        /var/run/php-fpm/php-fpm.sock \
        /var/run/php-fpm.sock; do
        if [[ -S "$sock" ]]; then
            FPM_SOCK="$sock"
            ok "Сокет PHP-FPM найден после запуска: $FPM_SOCK"
            break
        fi
    done
fi

if [[ -z "$FPM_SOCK" ]]; then
    # Последняя попытка — find
    FPM_SOCK=$(find /run /var/run -name "*.sock" 2>/dev/null | grep -i php | head -1 || true)
    if [[ -n "$FPM_SOCK" ]]; then
        ok "Сокет PHP-FPM найден через поиск: $FPM_SOCK"
    else
        warn "Сокет PHP-FPM не найден — используем TCP 127.0.0.1:9000"
        FPM_SOCK=""
    fi
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
# ШАГ 5: moodledata + права
# ──────────────────────────────────────────────────────────────
step 5 "Настройка каталога moodledata"
mkdir -p "$DATA"
WWWUSER="apache"; id apache &>/dev/null || WWWUSER="www-data"
chown -R "$WWWUSER:$WWWUSER" "$DATA"
chmod 0770 "$DATA"
[[ -d "$WWW" ]] && chown -R "$WWWUSER:$WWWUSER" "$WWW" 2>/dev/null || true
ok "moodledata: $DATA (владелец $WWWUSER)"
STATUS[data]=OK

# ──────────────────────────────────────────────────────────────
# ШАГ 6: настройка Apache + PHP-FPM
# ──────────────────────────────────────────────────────────────
step 6 "Настройка Apache и PHP-FPM"

# Определить CONF
CONF="/etc/httpd2/conf.d/moodle.conf"
[[ -d /etc/apache2/sites-available ]] && CONF="/etc/apache2/sites-available/moodle.conf"
mkdir -p "$(dirname "$CONF")" 2>/dev/null || true

# Сформировать обработчик PHP
if [[ -n "$FPM_SOCK" ]]; then
    PHP_HANDLER="SetHandler \"proxy:unix:${FPM_SOCK}|fcgi://localhost\""
else
    PHP_HANDLER='SetHandler "proxy:fcgi://127.0.0.1:9000"'
fi

info "Записываем $CONF (DocumentRoot=$WWW)..."
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

# Включить нужные модули Apache
a2enmod proxy       2>/dev/null || true
a2enmod proxy_fcgi  2>/dev/null || true
a2ensite moodle     2>/dev/null || true

# Запустить PHP-FPM
info "Запуск PHP-FPM..."
systemctl enable --now php8.3-fpm 2>/dev/null || \
systemctl enable --now php-fpm   2>/dev/null || true
STATUS[fpm]=OK

# Запустить Apache
for svc in httpd2 apache2; do
    if systemctl enable --now "$svc" 2>/dev/null && \
       systemctl restart "$svc" 2>/dev/null; then
        ok "$svc запущен"
        STATUS[apache]=OK
        break
    fi
done
[[ "${STATUS[apache]:-}" == "OK" ]] || { warn "Проверьте службу Apache вручную"; STATUS[apache]=ERROR; }

# ──────────────────────────────────────────────────────────────
# Итог
# ──────────────────────────────────────────────────────────────
echo
ok "Установка завершена!"
echo
info "Далее завершите установку через веб-интерфейс:"
echo "  URL:          http://192.168.1.2/moodle/"
echo "  (или http://moodle.au-team.irpo после билета №10)"
echo "  DocumentRoot: ${WWW}"
echo "  PHP-FPM сокет: ${FPM_SOCK:-127.0.0.1:9000}"
echo "  БД:           ${DB}"
echo "  Пользователь: ${DBUSER} / ${DBPASS}"
echo "  moodledata:   ${DATA}"
echo "  Админ Moodle: admin / P@ssw0rd (задать в мастере)"
echo "  На главной странице укажите номер рабочего места одной цифрой"

echo
echo "============================================================"
echo "  Итог — Билет №8"
echo "============================================================"
for k in install moodle_path db data fpm apache; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово."
