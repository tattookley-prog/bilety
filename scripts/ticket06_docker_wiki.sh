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

info "Установка Docker и Docker Compose..."
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y docker-engine docker-compose >/dev/null 2>&1 || \
apt-get install -y docker docker-compose >/dev/null 2>&1 || warn "Проверьте пакеты docker вручную"
if systemctl enable --now docker 2>/dev/null; then
    ok "docker запущен"; STATUS[docker]=OK
else
    error "docker не запущен"; STATUS[docker]=ERROR
fi

# Заготовка LocalSettings.php (монтируется в контейнер)
LS="${HOME_DIR}/LocalSettings.php"
if [[ ! -f "$LS" ]]; then
    cat > "$LS" <<'EOF'
<?php
# Заготовка LocalSettings.php (Билет №6).
# Полный файл генерируется мастером установки MediaWiki по адресу
# http://<BR-SRV>:8080  → "Complete the installation" → скачать LocalSettings.php
# и заменить этот файл, затем перезапустить: docker compose -f wiki.yml restart wiki
EOF
    ok "Создана заготовка $LS"
else
    warn "$LS уже существует — оставляю как есть"
fi
chown "$OWNER:$OWNER" "$LS" 2>/dev/null || true

info "Генерирую ${HOME_DIR}/wiki.yml..."
cat > "${HOME_DIR}/wiki.yml" <<EOF
version: "3"

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
EOF
chown "$OWNER:$OWNER" "${HOME_DIR}/wiki.yml" 2>/dev/null || true
ok "wiki.yml создан"
STATUS[compose_file]=OK

info "Запуск стека..."
if docker compose -f "${HOME_DIR}/wiki.yml" up -d 2>/dev/null || docker-compose -f "${HOME_DIR}/wiki.yml" up -d 2>/dev/null; then
    ok "Стек запущен (wiki + mariadb)"; STATUS[up]=OK
else
    error "Не удалось запустить стек"; STATUS[up]=ERROR
fi

sleep 5
echo; info "Контейнеры:"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
echo; info "Проверка доступности MediaWiki:"
if curl -s -o /dev/null -w '%{http_code}' "http://localhost:${PORT}" 2>/dev/null | grep -qE '200|302|301'; then
    ok "MediaWiki отвечает на порту ${PORT}"; STATUS[check]=OK
else
    warn "MediaWiki ещё поднимается — проверьте: curl http://localhost:${PORT}"; STATUS[check]=ERROR
fi

echo
echo "============================================================"
echo "  Итог — Билет №6"
echo "============================================================"
for k in docker compose_file up check; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Откройте http://<BR-SRV>:${PORT} и завершите установку MediaWiki."
