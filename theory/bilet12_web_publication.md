# Билет №12 — публикация веб-сервисов

## Что требуется по заданию
Собрать сквозную публикацию сервисов: Moodle (HQ-SRV:8081) и MediaWiki (BR-SRV:8080) через reverse proxy nginx на HQ-RTR и DNS-записи `moodle/wiki.au-team.irpo`, затем проверить доступ с HQ-CLI (в т.ч. браузер).

## Теория
Это интеграционный билет: объединяет темы DNS, backend-вебов, проксирования и клиентской проверки.
DNS A-записи связывают имена `moodle.au-team.irpo` и `wiki.au-team.irpo` с IP прокси (HQ-RTR).
Клиент обращается по доменному имени к nginx на HQ-RTR, а тот по `proxy_pass` перенаправляет запросы:
- `moodle.au-team.irpo` → HQ-SRV:8081 (`/moodle/`)
- `wiki.au-team.irpo` → BR-SRV:8080
Таким образом внешний доступ унифицируется через один входной узел и порт 80.
На HQ-CLI важно корректное DNS (`/etc/resolv.conf` на BR-SRV DNS), иначе имена не резолвятся.
Проверку выполняют и CLI-командами (`getent`, `curl`), и через графический браузер.
Билет логически связывает результаты билетов 6, 8, 9, 10 и DNS-часть 12.

Для защиты полезно объяснить не только команды, но и логику потока запроса/данных:
что является точкой входа, где хранится состояние, и каким шагом подтверждается корректность.
Хорошая практика ответа: сначала назвать роль сервиса, затем ключевой конфиг, затем проверочную команду.
Так преподавателю видно, что вы понимаете причину настройки, а не только повторяете команды.

## Ключевые файлы и пути конфигурации
- DNS-зона `au-team.irpo` (Samba AD на BR-SRV)
- nginx-конфиг reverse proxy на HQ-RTR
- Apache/Moodle backend на HQ-SRV (`:8081`)
- Docker/MediaWiki backend на BR-SRV (`:8080`)
- `/etc/resolv.conf` на HQ-CLI

## Основные команды
- `samba-tool dns query ... moodle/wiki A` — проверить A-записи.
- `getent hosts moodle.au-team.irpo` / `wiki.au-team.irpo` — клиентский резолв.
- `curl -I http://moodle.au-team.irpo` / `wiki.au-team.irpo` — HTTP-доступ.
- `command -v yandex-browser ...` — наличие браузера на HQ-CLI.

## Как проверить результат
Используйте справочник в конце скриптов: `scripts/ticket12_dns_add_records.sh`, `scripts/ticket12_hqcli_browser.sh`, `scripts/min_setup_hq-srv_t12.sh`, `scripts/min_setup_br-srv_t12.sh`, `scripts/min_setup_hq-rtr_t12.sh`.

## Частые вопросы преподавателя / на что обратить внимание
- Почему DNS-записи должны указывать на прокси, а не сразу на backend.
- Что именно проверяется через `Host`-заголовок в nginx.
- Где искать проблему при отказе: DNS, nginx, backend или маршрутизация.
- Как билет 12 связывает предыдущие билеты в единую схему.

## Соответствующий скрипт
`scripts/ticket12_hqcli_browser.sh` (и вспомогательные `scripts/ticket12_dns_add_records.sh`, `scripts/min_setup_*_t12.sh`)
