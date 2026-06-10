#!/bin/bash
# =============================================================================
# Билет №6 — Docker Compose: MediaWiki + MariaDB на BR-SRV
# wiki.yml в домашнем каталоге, сервис wiki (порт 8080) + mariadb.
# БД mediawiki, пользователь wiki, пароль WikiP@ssw0rd.
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
echo "  Билет №6 — Docker Compose (MediaWiki + MariaDB)"
echo "============================================================"
echo
read -rp "Пользователь, в чьём ~ создать wiki.yml [root]: " OWNER; OWNER="${OWNER:-root}"
HOME_DIR="$(getent passwd "$OWNER" | cut -d: -f6)"; HOME_DIR="${HOME_DIR:-/root}"
read -rp "Внешний порт MediaWiki [8080]: " PORT; PORT="${PORT:-8080}"
read -rp "Имя БД [mediawiki]: " DB; DB="${DB:-mediawiki}"
read -rp "Пользователь БД [wiki]: " DBUSER; DBUSER="${DBUSER:-wiki}"
read -rp "Пароль БД [WikiP@ssw0rd]: " DBPASS; DBPASS="${DBPASS:-WikiP@ssw0rd}"
read -rp "Пароль root БД [WikiR00t]: " DBROOT; DBROOT="${DBROOT:-WikiR00t}"

echo
info "wiki.yml → ${HOME_DIR}/wiki.yml, порт $PORT, БД $DB/$DBUSER"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

# -----------------------------------------------------------------------------
# 0. (Опционально) Настройка sshd на BR-SRV для приёма LocalSettings.php по scp
#    На Альт Линукс конфиг OpenSSH — /etc/openssh/sshd_config (не /etc/ssh/).
# -----------------------------------------------------------------------------
read -rp "Настроить sshd для входа root по паролю (для scp с HQ-CLI)? [y/N]: " SSHC
if [[ "${SSHC,,}" =~ ^y ]]; then
    SSHD_CONF=""
    for c in /etc/openssh/sshd_config /etc/ssh/sshd_config; do
        [[ -f "$c" ]] && { SSHD_CONF="$c"; break; }
    done
    if [[ -z "$SSHD_CONF" ]] && command -v rpm >/dev/null 2>&1; then
        SSHD_CONF="$(rpm -ql openssh-server 2>/dev/null | grep -m1 '/sshd_config$' || true)"
    fi
    SSHD_CONF="${SSHD_CONF:-/etc/openssh/sshd_config}"

    if [[ -f "$SSHD_CONF" ]]; then
        if cp -a "$SSHD_CONF" "${SSHD_CONF}.bak.$(date +%s)"; then
            ok "Бэкап sshd_config создан"
        else
            error "Не удалось создать бэкап $SSHD_CONF"
            STATUS[sshd]=ERROR
        fi

        if [[ "${STATUS[sshd]:-}" != "ERROR" ]]; then
            set_sshd() {
                local key="$1" val="$2"
                if grep -qiE "^[#[:space:]]*${key}[[:space:]]" "$SSHD_CONF"; then
                    sed -i -E "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$SSHD_CONF"
                else
                    echo "${key} ${val}" >> "$SSHD_CONF"
                fi
            }

            set_sshd PermitRootLogin yes
            set_sshd PasswordAuthentication yes
            ok "В $SSHD_CONF: PermitRootLogin yes, PasswordAuthentication yes"

            if sshd -t -f "$SSHD_CONF" 2>/dev/null; then
                systemctl enable --now sshd 2>/dev/null || true
                systemctl restart sshd 2>/dev/null || true
                ok "sshd перезапущен"
                STATUS[sshd]=OK
            else
                error "sshd -t выдал ошибку — откатите из ${SSHD_CONF}.bak.*"
                STATUS[sshd]=ERROR
            fi
        fi

        if command -v iptables >/dev/null 2>&1; then
            iptables -C INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true
        fi
    else
        warn "Файл конфигурации sshd не найден ($SSHD_CONF) — пропускаю"
        STATUS[sshd]=SKIP
    fi
fi

# -----------------------------------------------------------------------------
# 1. Настройка зеркала Docker Hub (решает TLS handshake timeout)
# -----------------------------------------------------------------------------
info "Настройка зеркала Docker Hub (на случай недоступности registry-1.docker.io)..."
DAEMON_JSON="/etc/docker/daemon.json"
# Создаём директорию заранее — она может не существовать до установки docker
mkdir -p "$(dirname "$DAEMON_JSON")"
if [[ ! -f "$DAEMON_JSON" ]] || ! grep -q "registry-mirrors" "$DAEMON_JSON" 2>/dev/null; then
    cat > "$DAEMON_JSON" <<'EOF'
{
  "registry-mirrors": [
    "https://dockerhub.timeweb.cloud",
    "https://mirror.gcr.io"
  ]
}
EOF
    ok "Зеркало Docker Hub настроено → $DAEMON_JSON"
    STATUS[mirror]=OK
else
    warn "$DAEMON_JSON уже содержит registry-mirrors — оставляю как есть"
    STATUS[mirror]=OK
fi

# -----------------------------------------------------------------------------
# 2. Установка Docker и Docker Compose
# -----------------------------------------------------------------------------
info "Установка Docker и Docker Compose..."
apt-get update -y || true

# Порядок попыток:
#   1) docker-engine + docker-compose  — ALT Linux (основная ОС конкурса)
#   2) docker.io + docker-compose-v2   — Debian/Ubuntu новые
#   3) docker.io + docker-compose      — Debian/Ubuntu старые
#   4) docker + docker-compose         — generic fallback
if apt-get install -y docker-engine docker-compose; then
    ok "Установлено: docker-engine + docker-compose (ALT Linux)"
elif apt-get install -y docker.io docker-compose-v2; then
    ok "Установлено: docker.io + docker-compose-v2"
elif apt-get install -y docker.io docker-compose; then
    ok "Установлено: docker.io + docker-compose"
elif apt-get install -y docker docker-compose; then
    ok "Установлено: docker + docker-compose"
else
    warn "Не удалось установить пакеты docker автоматически — проверьте вручную"
fi

if systemctl enable --now docker 2>/dev/null; then
    # Перезапуск нужен, чтобы применить daemon.json с зеркалом
    systemctl restart docker
    ok "docker запущен и перезагружен (применено зеркало)"; STATUS[docker]=OK
else
    error "docker не запущен"; STATUS[docker]=ERROR
    error "Установите вручную: apt-get install docker-engine docker-compose"
fi

# Прерываем дальнейшее выполнение если docker недоступен
if ! command -v docker &>/dev/null; then
    error "Команда docker не найдена — невозможно продолжить"
    error "Установите Docker вручную и перезапустите скрипт"
    exit 1
fi

# -----------------------------------------------------------------------------
# 3. Скачивание образов
# -----------------------------------------------------------------------------
info "Скачивание образа mariadb..."
if docker pull mariadb 2>&1; then
    ok "mariadb успешно скачан"; STATUS[pull_mariadb]=OK
else
    error "Не удалось скачать mariadb — проверьте сеть"; STATUS[pull_mariadb]=ERROR
fi

info "Скачивание образа mediawiki..."
PULL_OK=false
for attempt in 1 2 3; do
    if docker pull mediawiki 2>&1; then
        ok "mediawiki успешно скачан (попытка $attempt)"; STATUS[pull_mediawiki]=OK
        PULL_OK=true
        break
    else
        warn "Попытка $attempt/3 не удалась, жду 5 сек..."
        sleep 5
    fi
done
if ! $PULL_OK; then
    error "Не удалось скачать mediawiki после 3 попыток"
    error "Попробуйте вручную: docker pull mediawiki"
    error "Или перенесите образ: docker save mediawiki | gzip > mediawiki.tar.gz"
    STATUS[pull_mediawiki]=ERROR
fi

# -----------------------------------------------------------------------------
# 4. Генерация wiki.yml
# БЕЗ монтирования LocalSettings.php — чтобы мастер установки MediaWiki
# запустился корректно. LocalSettings.php подключается ПОСЛЕ мастера.
# -----------------------------------------------------------------------------
info "Генерирую ${HOME_DIR}/wiki.yml..."

# Используем tee чтобы избежать про��лем с отступами и heredoc
tee "${HOME_DIR}/wiki.yml" > /dev/null << YAML
# Docker Compose — Билет №6 (MediaWiki + MariaDB)
# Поле version убрано — оно устарело в Docker Compose v2+

services:
  mariadb:
    image: mariadb
    container_name: mariadb
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DBROOT}
      MYSQL_DATABASE: ${DB}
      MYSQL_USER: ${DBUSER}
      MYSQL_PASSWORD: ${DBPASS}
    volumes:
      - mariadb_data:/var/lib/mysql

  wiki:
    image: mediawiki
    container_name: wiki
    restart: always
    depends_on:
      - mariadb
    ports:
      - "${PORT}:80"

volumes:
  mariadb_data:
YAML

chown "$OWNER:$OWNER" "${HOME_DIR}/wiki.yml" 2>/dev/null || true

# Проверить валидность YAML перед запуском
if docker compose -f "${HOME_DIR}/wiki.yml" config >/dev/null 2>&1; then
    ok "wiki.yml валиден"
    STATUS[compose_file]=OK
else
    error "wiki.yml невалиден — проверьте файл: cat ${HOME_DIR}/wiki.yml"
    STATUS[compose_file]=ERROR
fi

# -----------------------------------------------------------------------------
# 5. Остановить и удалить старые контейнеры если существуют
# (избегаем конфликта имён контейнеров при повторном запуске скрипта)
# -----------------------------------------------------------------------------
info "Проверка существующих контейнеров..."
for cname in wiki mariadb; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${cname}$"; then
        warn "Контейнер '$cname' уже существует — останавливаю и удаляю..."
        docker stop "$cname" 2>/dev/null || true
        docker rm "$cname" 2>/dev/null || true
        ok "Контейнер '$cname' удалён"
    fi
done

# -----------------------------------------------------------------------------
# 6. Запуск стека
# -----------------------------------------------------------------------------
info "Запуск стека..."
if docker compose -f "${HOME_DIR}/wiki.yml" up -d 2>/dev/null || \
   docker-compose -f "${HOME_DIR}/wiki.yml" up -d 2>/dev/null; then
    ok "Стек запущен (wiki + mariadb)"; STATUS[up]=OK
else
    error "Не удалось запустить стек"; STATUS[up]=ERROR
fi

sleep 5
echo; info "Контейнеры:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true

echo; info "Проверка доступности MediaWiki (мастер установки):"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}" 2>/dev/null || echo "000")
if echo "$HTTP_CODE" | grep -qE '^(200|302|301)$'; then
    ok "MediaWiki отвечает на порту ${PORT} (HTTP $HTTP_CODE)"; STATUS[check]=OK
elif [[ "$HTTP_CODE" == "500" ]]; then
    error "MediaWiki вернул 500 — возможно подключён сломанный LocalSettings.php"
    error "Проверьте: docker logs wiki | tail -20"
    STATUS[check]=ERROR
else
    warn "MediaWiki ещё поднимается (HTTP $HTTP_CODE) — проверьте: curl http://localhost:${PORT}"
    STATUS[check]=WARN
fi

# -----------------------------------------------------------------------------
# 6.5 Автоустановка MediaWiki через maintenance/install.php
#     По умолчанию [Y/n] — Enter = да, scp с HQ-CLI не нужен.
#
#     ИСПРАВЛЕНИЕ Error 1133 (MariaDB 10.4+):
#     В новых версиях MariaDB GRANT не создаёт пользователей автоматически.
#     Если install.php запускать с --dbuser wiki, он пытается выполнить
#     GRANT ... TO 'wiki'@'mariadb' и падает с Error 1133, даже если
#     пользователь уже создан заранее.
#     Решение: запускать install.php с --dbuser root (пропускает GRANT),
#     затем патчить LocalSettings.php: заменить root → wiki.
# -----------------------------------------------------------------------------
read -rp "Завершить установку MediaWiki автоматически (минуя веб-мастер)? [Y/n]: " AUTO
AUTO="${AUTO:-y}"
if [[ "${AUTO,,}" =~ ^y ]]; then
    read -rp "Имя вики [AU-TEAM Wiki]: " WIKI_NAME; WIKI_NAME="${WIKI_NAME:-AU-TEAM Wiki}"
    read -rp "Администратор вики [Admin]: " WIKI_ADMIN; WIKI_ADMIN="${WIKI_ADMIN:-Admin}"
    # ВАЖНО: MediaWiki требует пароль администратора (sysop) не короче 10 символов,
    # иначе install.php падает на этапе создания учётной записи администра��ора.
    read -rp "Пароль администратора (>=10 символов) [WikiP@ssw0rd]: " WIKI_PASS; WIKI_PASS="${WIKI_PASS:-WikiP@ssw0rd}"
    while [[ "${#WIKI_PASS}" -lt 10 ]]; do
        warn "Пароль слишком короткий (${#WIKI_PASS} симв.) — MediaWiki требует не менее 10 символов"
        read -rp "Введите пароль администратора (>=10 символов) [WikiP@ssw0rd]: " WIKI_PASS
        WIKI_PASS="${WIKI_PASS:-WikiP@ssw0rd}"
    done
    # ВАЖНО: на Альт Линукс `hostname -I` часто НЕ поддерживается и под
    # `set -euo pipefail` (особенно pipefail) обрывает скрипт прямо здесь.
    # Поэтому определяем IP устойчиво, и все вызовы прикрыты `|| true`.
    DEF_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
    [[ -z "${DEF_IP:-}" ]] && DEF_IP="$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}' || true)"
    [[ -z "${DEF_IP:-}" ]] && DEF_IP="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1 || true)"
    DEF_IP="${DEF_IP:-192.168.3.2}"
    read -rp "URL сервера вики [http://${DEF_IP}:${PORT}]: " WIKI_URL; WIKI_URL="${WIKI_URL:-http://${DEF_IP}:${PORT}}"

    info "Ожидание готовности MariaDB..."
    DB_READY=false
    for i in $(seq 1 30); do
        if docker exec mariadb mariadb -uroot -p"${DBROOT}" -e 'SELECT 1' >/dev/null 2>&1; then
            DB_READY=true; ok "MariaDB готова (за ~${i}с)"; break
        fi
        sleep 1
    done
    $DB_READY || warn "MariaDB не ответила за 30с — установка может не пройти"

    # Если предыдущая попытка установки оборвалась (например, на коротком пароле),
    # в БД могли остаться таблицы MediaWiki — тогда install.php упадёт с
    # "There are already MediaWiki tables in this database". Предлагаем очистить.
    TABLE_COUNT=$(docker exec mariadb mariadb -uroot -p"${DBROOT}" -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB}';" 2>/dev/null || echo 0)
    if [[ "${TABLE_COUNT:-0}" =~ ^[0-9]+$ ]] && [[ "${TABLE_COUNT:-0}" -gt 0 ]]; then
        warn "В БД '${DB}' уже есть таблицы (${TABLE_COUNT} шт.) — вероятно, остаток прошлой установки"
        read -rp "Очистить БД '${DB}' перед установкой (нужно для повторной установки)? [y/N]: " DROPDB
        if [[ "${DROPDB,,}" =~ ^y ]]; then
            if docker exec mariadb mariadb -uroot -p"${DBROOT}" -e \
                "DROP DATABASE IF EXISTS \`${DB}\`; CREATE DATABASE \`${DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci; GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${DBUSER}'@'%'; FLUSH PRIVILEGES;" 2>/dev/null; then
                ok "БД '${DB}' пересоздана — чистый старт"
            else
                warn "Не удалось пересоздать БД '${DB}' — установка может упасть с 'tables already exist'"
            fi
        fi
    fi

    # Создаём wiki-пользователя заранее (нужен для нормальной работы вики после патча)
    info "Подготовка пользователя БД '${DBUSER}' для хостов '%' и 'mariadb'..."
    if docker exec mariadb mariadb -uroot -p"${DBROOT}" -e "
        CREATE USER IF NOT EXISTS '${DBUSER}'@'%'       IDENTIFIED BY '${DBPASS}';
        CREATE USER IF NOT EXISTS '${DBUSER}'@'mariadb' IDENTIFIED BY '${DBPASS}';
        GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${DBUSER}'@'%';
        GRANT ALL PRIVILEGES ON \`${DB}\`.* TO '${DBUSER}'@'mariadb';
        FLUSH PRIVILEGES;" 2>/dev/null; then
        ok "Пользователь '${DBUSER}' готов (хосты '%' и 'mariadb')"
    else
        warn "Не удалось предсоздать пользователя '${DBUSER}' — но установка пройдёт через root"
    fi

    # FIX Error 1133: запускаем install.php с --dbuser root
    # В MariaDB 10.4+ GRANT не создаёт пользователей автоматически, поэтому
    # install.php с --dbuser wiki падает при попытке GRANT ... TO 'wiki'@'mariadb'.
    # Решение: устанавливаем от root (GRANT не выполняется — root уже владелец),
    # затем патчим LocalSettings.php: меняем root → wiki.
    info "Запуск maintenance/install.php внутри контейнера wiki (dbuser=root, обход Error 1133)..."
    if docker exec wiki php /var/www/html/maintenance/install.php \
        --dbtype mysql --dbserver mariadb \
        --dbname "${DB}" --dbuser root --dbpass "${DBROOT}" \
        --server "${WIKI_URL}" --scriptpath "" --lang ru \
        --pass "${WIKI_PASS}" "${WIKI_NAME}" "${WIKI_ADMIN}"; then
        ok "MediaWiki установлена (LocalSettings.php сгенерирован)"; STATUS[install]=OK
    else
        error "install.php завершился с ошибкой — проверьте: docker logs wiki | tail -20"
        error "Частые причины: пароль администратора < 10 символов; остаток таблиц в БД (см. вопрос выше)."
        STATUS[install]=ERROR
    fi

    if [[ "${STATUS[install]:-}" == "OK" ]]; then
        if docker cp wiki:/var/www/html/LocalSettings.php "${HOME_DIR}/LocalSettings.php"; then
            chown "$OWNER:$OWNER" "${HOME_DIR}/LocalSettings.php" 2>/dev/null || true
            ok "LocalSettings.php сохранён → ${HOME_DIR}/LocalSettings.php"

            # Патч LocalSettings.php: заменить root → wiki-пользователя
            # install.php записал root в wgDBuser/wgDBpassword — меняем на wiki
            info "Патч LocalSettings.php: wgDBuser root → ${DBUSER}..."
            sed -i "s/\\\$wgDBuser = \"root\"/\$wgDBuser = \"${DBUSER}\"/" "${HOME_DIR}/LocalSettings.php" 2>/dev/null || true
            sed -i "s/\\\$wgDBuser = 'root'/\$wgDBuser = '${DBUSER}'/" "${HOME_DIR}/LocalSettings.php" 2>/dev/null || true
            sed -i "s/\\\$wgDBpassword = \"${DBROOT}\"/\$wgDBpassword = \"${DBPASS}\"/" "${HOME_DIR}/LocalSettings.php" 2>/dev/null || true
            sed -i "s/\\\$wgDBpassword = '${DBROOT}'/\$wgDBpassword = '${DBPASS}'/" "${HOME_DIR}/LocalSettings.php" 2>/dev/null || true
            if grep -q "\"${DBUSER}\"\|'${DBUSER}'" "${HOME_DIR}/LocalSettings.php" 2>/dev/null; then
                ok "LocalSettings.php пропатчен: wgDBuser = ${DBUSER}"
            else
                warn "Проверьте вручную: grep wgDBuser ${HOME_DIR}/LocalSettings.php"
            fi
        fi

        info "Перегенерация wiki.yml с монтированием LocalSettings.php..."
        tee "${HOME_DIR}/wiki.yml" > /dev/null << YAML
# Docker Compose — Билет №6 (MediaWiki + MariaDB), с LocalSettings.php
services:
  mariadb:
    image: mariadb
    container_name: mariadb
    restart: always
    environment:
      MYSQL_ROOT_PASSWORD: ${DBROOT}
      MYSQL_DATABASE: ${DB}
      MYSQL_USER: ${DBUSER}
      MYSQL_PASSWORD: ${DBPASS}
    volumes:
      - mariadb_data:/var/lib/mysql

  wiki:
    image: mediawiki
    container_name: wiki
    restart: always
    depends_on:
      - mariadb
    ports:
      - "${PORT}:80"
    volumes:
      - ${HOME_DIR}/LocalSettings.php:/var/www/html/LocalSettings.php

volumes:
  mariadb_data:
YAML
        chown "$OWNER:$OWNER" "${HOME_DIR}/wiki.yml" 2>/dev/null || true
        info "Перезапуск контейнера wiki с LocalSettings.php..."
        docker compose -f "${HOME_DIR}/wiki.yml" up -d --force-recreate wiki 2>/dev/null || \
        docker-compose -f "${HOME_DIR}/wiki.yml" up -d --force-recreate wiki 2>/dev/null || true
        sleep 3
        FINAL_CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}" 2>/dev/null || echo "000")
        if echo "$FINAL_CODE" | grep -qE '^(200|301|302)$'; then
            ok "Вики готова и отвечает (HTTP $FINAL_CODE) — мастер не нужен"
        else
            warn "Финальная проверка: HTTP $FINAL_CODE — проверьте docker logs wiki"
        fi
    fi
fi

# -----------------------------------------------------------------------------
# 7. Итог
# -----------------------------------------------------------------------------
echo
echo "============================================================"
echo "  Итог — Билет №6"
echo "============================================================"
for k in mirror docker pull_mariadb pull_mediawiki compose_file up check sshd install; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        WARN)  echo -e "  ${YELLOW}[WARN]${NC}  $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
echo
if [[ "${STATUS[install]:-}" == "OK" ]]; then
    ok "Вики готова! Откройте ${WIKI_URL}"
    echo -e "  Логин администратора: ${WIKI_ADMIN}"
    echo -e "  Пароль администратора: ${WIKI_PASS}"
    echo
    info "Веб-мастер установки и перенос LocalSettings.php по scp не требуются."
else
    ok "Откройте http://<BR-SRV>:${PORT} и завершите установку MediaWiki."
    echo
    warn "После прохождения мастера установки:"
    echo -e "  1) Скачайте LocalSettings.php и скопируйте на сервер:"
    echo -e "     scp LocalSettings.php root@<BR-SRV>:${HOME_DIR}/LocalSettings.php"
    echo -e "  2) Добавьте монтирование в wiki.yml (секция wiki → volumes):"
    echo -e "       volumes:"
    echo -e "         - ${HOME_DIR}/LocalSettings.php:/var/www/html/LocalSettings.php"
    echo -e "  3) Перезапустите контейнер wiki:"
    echo -e "     docker compose -f ${HOME_DIR}/wiki.yml up -d --force-recreate wiki"
fi
