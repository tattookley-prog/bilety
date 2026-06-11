#!/bin/bash
# =============================================================================
# Минимальная настройка BR-SRV — Билет №12
# 1) Поднимает контейнер MediaWiki на порту 8080
# 2) Добавляет DNS A-записи moodle/wiki в зоне au-team.irpo на IP HQ-RTR
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

[[ $EUID -ne 0 ]] && { error "Запуск только от root (sudo/su -)"; exit 1; }

declare -A STATUS

echo
echo "============================================================"
echo "  Минимальная настройка BR-SRV для Билета №12"
echo "============================================================"
echo

read -rp "DNS зона [au-team.irpo]: " ZONE; ZONE="${ZONE:-au-team.irpo}"
read -rp "IP обратного прокси HQ-RTR [192.168.2.1]: " PROXY_IP; PROXY_IP="${PROXY_IP:-192.168.2.1}"
read -rp "Пароль administrator домена [P@ssw0rd]: " ADMINPASS; ADMINPASS="${ADMINPASS:-P@ssw0rd}"

echo
info "Будет: MediaWiki :8080, DNS moodle/wiki.${ZONE} → ${PROXY_IP}"
read -rp "Продолжить? [y/N]: " C; [[ "${C,,}" =~ ^y ]] || exit 0

info "Настройка зеркала Docker Hub..."
DAEMON_JSON="/etc/docker/daemon.json"
mkdir -p "$(dirname "$DAEMON_JSON")"
if [[ ! -f "$DAEMON_JSON" ]] || ! grep -q "registry-mirrors" "$DAEMON_JSON" 2>/dev/null; then
    cp -n "$DAEMON_JSON" "${DAEMON_JSON}.bak" 2>/dev/null || true
    cat > "$DAEMON_JSON" <<'JSON'
{
  "registry-mirrors": [
    "https://dockerhub.timeweb.cloud",
    "https://mirror.gcr.io"
  ]
}
JSON
    ok "Зеркало Docker Hub настроено → $DAEMON_JSON"
else
    warn "$DAEMON_JSON уже содержит registry-mirrors — оставляю как есть"
fi

info "Проверяю Docker..."
if ! command -v docker >/dev/null 2>&1; then
    info "Docker не найден, устанавливаю..."
    apt-get update -y
    if apt-get install -y docker-engine; then
        ok "Установлено: docker-engine (ALT Linux)"; STATUS[install]=OK
    elif apt-get install -y docker.io; then
        ok "Установлено: docker.io"; STATUS[install]=OK
    elif apt-get install -y docker; then
        ok "Установлено: docker"; STATUS[install]=OK
    else
        fail "Не удалось установить Docker"; STATUS[install]=ERROR; exit 1
    fi
else
    STATUS[install]=OK
fi

systemctl enable docker 2>/dev/null || true
systemctl restart docker
ok "Docker запущен"
STATUS[docker]=OK

info "Удаляю старый контейнер mediawiki_min если есть..."
docker rm -f mediawiki_min 2>/dev/null || true

info "Скачиваю образ mediawiki:latest..."
PULL_OK=false
for attempt in 1 2 3; do
    if docker pull mediawiki:latest; then
        ok "mediawiki:latest скачан (попытка $attempt)"
        PULL_OK=true
        break
    fi
    warn "Попытка $attempt/3 не удалась, жду 5 сек..."
    sleep 5
done
if ! $PULL_OK; then
    fail "Не удалось скачать mediawiki после 3 попыток"
    STATUS[pull]=ERROR
    exit 1
fi
STATUS[pull]=OK

docker run -d \
    --name mediawiki_min \
    --restart unless-stopped \
    -p 8080:80 \
    mediawiki:latest >/dev/null
ok "Контейнер mediawiki_min запущен"
STATUS[container]=OK

info "Жду ответа MediaWiki на :8080 (до 60 сек)..."
for i in $(seq 1 60); do
    CODE="$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080 2>/dev/null || echo 000)"
    if [[ "$CODE" =~ ^(200|301|302|303)$ ]]; then
        ok "MediaWiki отвечает на порту 8080 (HTTP $CODE, за ~${i}с)"
        STATUS[wiki_http]=OK
        break
    fi
    sleep 1
done
STATUS[wiki_http]="${STATUS[wiki_http]:-ERROR}"

dns_query_ip() {
    local rec="$1"
    samba-tool dns query 127.0.0.1 "$ZONE" "$rec" A -U "administrator%${ADMINPASS}" 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

set_dns_record() {
    local rec="$1" key="$2" current
    info "Добавляю DNS A: ${rec}.${ZONE} → ${PROXY_IP}"
    if samba-tool dns add 127.0.0.1 "$ZONE" "$rec" A "$PROXY_IP" -U "administrator%${ADMINPASS}" 2>/dev/null; then
        ok "${rec}.${ZONE} добавлена"
        STATUS["$key"]=OK
        return 0
    fi

    warn "${rec}.${ZONE} уже существует или add вернул ошибку — показываю текущее значение"
    samba-tool dns query 127.0.0.1 "$ZONE" "$rec" A -U "administrator%${ADMINPASS}" 2>/dev/null || true
    current="$(dns_query_ip "$rec")"
    if [[ -z "$current" ]]; then
        STATUS["$key"]=ERROR
        return 1
    fi
    if [[ "$current" == "$PROXY_IP" ]]; then
        ok "${rec}.${ZONE} уже указывает на ${current}"
        STATUS["$key"]=OK
    else
        warn "${rec}.${ZONE} указывает на ${current}, ожидается ${PROXY_IP}"
        STATUS["$key"]=ERROR
    fi
}

echo
if command -v samba-tool >/dev/null 2>&1; then
    set_dns_record moodle dns_moodle || true
    set_dns_record wiki dns_wiki || true
else
    warn "samba-tool не найден — DNS шаг пропущен"
    STATUS[dns_moodle]=ERROR
    STATUS[dns_wiki]=ERROR
fi

echo
echo "============================================================"
echo "  Итог — Билет №12 (BR-SRV)"
echo "============================================================"
for k in install docker pull container wiki_http dns_moodle dns_wiki; do
    v="${STATUS[$k]:-SKIP}"
    case "$v" in
        OK)    echo -e "  ${GREEN}[OK]${NC}    $k";;
        ERROR) echo -e "  ${RED}[ERROR]${NC} $k";;
        *)     echo -e "  ${YELLOW}[SKIP]${NC}  $k";;
    esac
done
echo "============================================================"
ok "Готово. Проверьте с HQ-CLI: getent hosts moodle.${ZONE} и wiki.${ZONE}"

echo
echo "============================================================"
echo "  СПРАВОЧНИК КОМАНД ДЛЯ ПОКАЗА ПРЕПОДАВАТЕЛЮ"
echo "============================================================"
cat <<'EOF'
docker ps                                                                 # Контейнер mediawiki_min запущен
curl -I http://localhost:8080                                             # MediaWiki отвечает
samba-tool dns query 127.0.0.1 au-team.irpo moodle A -U administrator    # A-запись moodle
samba-tool dns query 127.0.0.1 au-team.irpo wiki A -U administrator      # A-запись wiki
EOF
