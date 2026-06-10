#!/bin/bash
# =============================================================================
# Минимальная настройка BR-SRV — Билет №10
# Запускает контейнер MediaWiki на порту 8080, чтобы nginx на HQ-RTR мог
# проксировать запросы wiki.au-team.irpo → BR-SRV:8080
#
# Запуск: sudo bash scripts/min_setup_br-srv_t10.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "Запуск только от root (sudo)"; exit 1; }

echo
echo "============================================================"
echo "  Минимальная настройка BR-SRV для Билета №10"
echo "============================================================"
echo

# ── Установка Docker ─────────────────────────────────────────────
info "Проверяю Docker..."
if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден, устанавливаю..."
    info "Обновляю список пакетов..."
    apt-get update -y
    info "Устанавливаю docker.io..."
    apt-get install -y docker.io || { fail "Не удалось установить docker"; exit 1; }
fi
systemctl enable docker
systemctl start docker
ok "Docker за��ущен"

# ── Запуск MediaWiki ─────────────────────────────────────────────
info "Запускаю контейнер MediaWiki на порту 8080..."

# Удаляем старый контейнер если есть
docker rm -f mediawiki_min 2>/dev/null || true

info "Скачиваю образ mediawiki:latest (может занять время)..."
docker pull mediawiki:latest

docker run -d \
    --name mediawiki_min \
    --restart unless-stopped \
    -p 8080:80 \
    mediawiki:latest

ok "Контейнер mediawiki_min запущен"

# ── Ожидание запуска ─────────────────────────────────────────────
info "Жду запуска MediaWiki (до 60 сек)..."
for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")
    if echo "$CODE" | grep -Eq "^(200|301|302|303)$"; then
        ok "MediaWiki отвечает на порту 8080 (HTTP $CODE, за ~${i}с)"
        break
    fi
    sleep 1
done

# Итоговая проверка
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")
if echo "$CODE" | grep -Eq "^(200|301|302|303)$"; then
    ok "Проверка пройдена"
else
    fail "MediaWiki не отвечает (HTTP $CODE) — проверьте docker logs mediawiki_min"
fi

echo
echo "============================================================"
echo "  Готово. BR-SRV слушает на порту 8080."
echo "  Теперь на HQ-RTR запустите check_all.sh → билет 10."
echo "============================================================"
