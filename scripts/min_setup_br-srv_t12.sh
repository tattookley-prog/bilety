#!/bin/bash
# =============================================================================
# Минимальная настройка BR-SRV — Билет №12
# 1) Поднимает контейнер MediaWiki на порту 8080
# 2) Добавляет DNS A-записи moodle/wiki в зоне au-team.irpo на IP HQ-RTR
# =============================================================================
set -euo pipefail

export PATH="/usr/sbin:/sbin:/usr/local/sbin:$PATH"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Поиск samba-tool по PATH и типичным путям
find_samba_tool() {
    local p
    if p="$(command -v samba-tool 2>/dev/null)"; then
        echo "$p"; return 0
    fi
    for p in /usr/sbin/samba-tool /usr/bin/samba-tool \
              /usr/local/sbin/samba-tool /usr/local/bin/samba-tool; do
        [[ -x "$p" ]] && { echo "$p"; return 0; }
    done
    return 1
}
SAMBA_TOOL="$(find_samba_tool || true)"

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

# Проверка, что служба samba активна
check_samba_service() {
    local svc
    for svc in samba samba-ad-dc; do
        if systemctl is-active -q "$svc" 2>/dev/null; then
            return 0
        fi
    done
    warn "Служба samba не активна — пытаюсь запустить..."
    for svc in samba samba-ad-dc; do
        if systemctl start "$svc" 2>/dev/null; then
            sleep 2
            if systemctl is-active -q "$svc" 2>/dev/null; then
                ok "Служба $svc запущена"
                return 0
            fi
        fi
    done
    warn "Не удалось запустить samba. Проверьте:"
    warn "  systemctl status samba"
    warn "  ss -tulnp | grep ':53'"
    return 1
}

# Запрос текущего IP записи через samba-tool; выводит IP или пустую строку
_dns_query_ip() {
    local rec="$1" out
    out="$("$SAMBA_TOOL" dns query 127.0.0.1 "$ZONE" "$rec" A \
        -U "administrator%${ADMINPASS}" 2>&1)" || true
    echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# Запрос записи с несколькими методами аутентификации; печатает ошибку при сбое
_dns_query_ip_multi() {
    local rec="$1" out ip
    # метод 1: пароль
    out="$("$SAMBA_TOOL" dns query 127.0.0.1 "$ZONE" "$rec" A \
        -U "administrator%${ADMINPASS}" 2>&1)" || true
    ip="$(echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    # метод 2: Kerberos
    if command -v kinit >/dev/null 2>&1; then
        kinit administrator <<< "$ADMINPASS" 2>/dev/null || true
        out="$("$SAMBA_TOOL" dns query 127.0.0.1 "$ZONE" "$rec" A -k yes 2>&1)" || true
        ip="$(echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
        [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    fi
    # метод 3: машинный аккаунт DC (-P)
    out="$("$SAMBA_TOOL" dns query 127.0.0.1 "$ZONE" "$rec" A -P 2>&1)" || true
    ip="$(echo "$out" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    [[ -n "$ip" ]] && { echo "$ip"; return 0; }
    # все методы не дали IP — печатаем последний вывод для диагностики
    warn "samba-tool dns query вернул: $out"
    return 1
}

# Выполнить DNS-команду с fallback по методам аутентификации
# Использование: _samba_dns_run dns add|delete|update ...
_samba_dns_run() {
    local out rc
    # метод 1: пароль
    out="$("$SAMBA_TOOL" "$@" -U "administrator%${ADMINPASS}" 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
    warn "samba-tool $* (пароль): $out"
    # метод 2: Kerberos
    if command -v kinit >/dev/null 2>&1; then
        kinit administrator <<< "$ADMINPASS" 2>/dev/null || true
        out="$("$SAMBA_TOOL" "$@" -k yes 2>&1)"; rc=$?
        [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
        warn "samba-tool $* (kinit): $out"
    fi
    # метод 3: машинный аккаунт DC
    out="$("$SAMBA_TOOL" "$@" -P 2>&1)"; rc=$?
    [[ $rc -eq 0 ]] && { echo "$out"; return 0; }
    warn "samba-tool $* (-P): $out"
    error "Все методы аутентификации samba-tool не сработали."
    error "Проверьте: systemctl is-active samba; ss -tulnp | grep ':53';"
    error "  пароль administrator, синхронизацию времени (±5 мин для Kerberos)."
    return 1
}

# Идемпотентное обеспечение A-записи: add / update / ok-if-same
ensure_dns_a() {
    local rec="$1" target_ip="$2" key="$3" current
    info "Обеспечиваю DNS A: ${rec}.${ZONE} → ${target_ip}"
    current="$(_dns_query_ip_multi "$rec" || true)"
    if [[ -z "$current" ]]; then
        # Запись отсутствует — добавляем
        if _samba_dns_run dns add 127.0.0.1 "$ZONE" "$rec" A "$target_ip" >/dev/null; then
            ok "${rec}.${ZONE} → ${target_ip} добавлена"
        else
            error "Не удалось добавить ${rec}.${ZONE}"
            STATUS["$key"]=ERROR; return 1
        fi
    elif [[ "$current" == "$target_ip" ]]; then
        ok "${rec}.${ZONE} уже указывает на ${current} — ОК"
        STATUS["$key"]=OK; return 0
    else
        warn "${rec}.${ZONE} указывает на ${current}, ожидается ${target_ip} — обновляю"
        if _samba_dns_run dns update 127.0.0.1 "$ZONE" "$rec" A "$current" "$target_ip" >/dev/null; then
            ok "${rec}.${ZONE} обновлена: ${current} → ${target_ip}"
        else
            warn "update не сработал — удаляю и добавляю заново"
            _samba_dns_run dns delete 127.0.0.1 "$ZONE" "$rec" A "$current" >/dev/null || true
            if _samba_dns_run dns add 127.0.0.1 "$ZONE" "$rec" A "$target_ip" >/dev/null; then
                ok "${rec}.${ZONE} пересоздана: → ${target_ip}"
            else
                error "Не удалось пересоздать ${rec}.${ZONE}"
                STATUS["$key"]=ERROR; return 1
            fi
        fi
    fi
    # Финальная проверка
    current="$(_dns_query_ip "$rec" || true)"
    if [[ "$current" == "$target_ip" ]]; then
        ok "${rec}.${ZONE} проверена → ${current}"
        STATUS["$key"]=OK
    else
        error "${rec}.${ZONE} после операции показывает '${current}', ожидалось '${target_ip}'"
        STATUS["$key"]=ERROR
    fi
}

echo
if [[ -n "$SAMBA_TOOL" ]]; then
    info "Найден samba-tool: $SAMBA_TOOL"
    check_samba_service || true
    ensure_dns_a moodle "$PROXY_IP" dns_moodle || true
    ensure_dns_a wiki   "$PROXY_IP" dns_wiki   || true
else
    warn "samba-tool не найден ни по PATH, ни по стандартным путям — DNS шаг пропущен"
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
