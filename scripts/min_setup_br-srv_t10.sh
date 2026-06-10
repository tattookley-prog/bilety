#!/bin/bash
# =============================================================================
# Минимальная настройка BR-SRV — Билет №10
# Запускает контейнер MediaWiki на порту 8080, чтобы nginx на HQ-RTR мог
# проксировать запросы wiki.au-team.irpo → BR-SRV:8080
#
# Поддерживает: ALT Linux (docker-engine) и Debian/Ubuntu (docker.io)
# Запуск: sudo bash scripts/min_setup_br-srv_t10.sh
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

[[ $EUID -ne 0 ]] && { echo "Запуск только от root (sudo)"; exit 1; }

echo
echo "============================================================"
echo "  Минимальная настройка BR-SRV для Билета №10"
echo "============================================================"
echo

# ── Настройка зеркала Docker Hub (как в ticket06) ────────────────
info "Настройка зеркала Docker Hub..."
DAEMON_JSON="/etc/docker/daemon.json"
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
else
    warn "$DAEMON_JSON уже содержит registry-mirrors — оставляю как есть"
fi

# ── Установка Docker ──────────────────────────────────────────────
info "Проверяю Docker..."
if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден, устанавливаю..."
    info "Обновляю список пакетов..."
    apt-get update -y

    # Порядок как в ticket06:
    # 1) docker-engine  — ALT Linux
    # 2) docker.io      — Debian/Ubuntu новые
    # 3) docker         — generic fallback
    if apt-get install -y docker-engine 2>/dev/null; then
        ok "Установлено: docker-engine (ALT Linux)"
    elif apt-get install -y docker.io 2>/dev/null; then
        ok "Установлено: docker.io"
    elif apt-get install -y docker 2>/dev/null; then
        ok "Установлено: docker"
    else
        fail "Не удалось установить Docker — проверьте репозитории"
        exit 1
    fi
fi

systemctl enable docker
systemctl restart docker
ok "Docker запущен (зеркало применено)"

if ! command -v docker >/dev/null 2>&1; then
    fail "Команда docker не найдена — невозможно продолжить"
    exit 1
fi

# ── Запуск MediaWiki ──────────────────────────────────────────────
info "Удаляю старый контейнер если есть..."
docker rm -f mediawiki_min 2>/dev/null || true

info "Скачиваю образ mediawiki:latest (может занять время)..."
# 3 попытки как в ticket06
PULL_OK=false
for attempt in 1 2 3; do
    if docker pull mediawiki:latest; then
        ok "mediawiki:latest скачан (попытка $attempt)"
        PULL_OK=true
        break
    else
        warn "Попытка $attempt/3 не удалась, жду 5 сек..."
        sleep 5
    fi
done
if ! $PULL_OK; then
    fail "Не удалось скачать mediawiki после 3 попыток"
    fail "Попробуйте вручную: docker pull mediawiki:latest"
    exit 1
fi

info "Запускаю контейнер MediaWiki на порту 8080..."
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

# ── Итоговая проверка ─────────────────────────────────────────────
CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo "000")
if echo "$CODE" | grep -Eq "^(200|301|302|303)$"; then
    ok "Проверка пройдена — MediaWiki отвечает"
else
    fail "MediaWiki не отвечает (HTTP $CODE)"
    warn "Проверьте: docker logs mediawiki_min"
fi

echo
echo "============================================================"
echo "  Готово. BR-SRV слушает на порту 8080."
echo "  Теперь на HQ-RTR запустите check_all.sh → билет 10."
echo "============================================================"
