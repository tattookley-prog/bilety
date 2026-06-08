# bilety — скрипты под 12 экзаменационных билетов (Модуль 2)

Bash-скрипты автоматизации практических заданий по специальности **09.02.06 «Сетевое и системное администрирование»**, **Модуль 2**.

Все скрипты рассчитаны на **Альт Сервер** (узлы HQ-SRV / BR-SRV) и **Альт Рабочая станция** (HQ-CLI). Маршрутизаторы HQ-RTR / BR-RTR — Альт JeOS / Linux.

> Исходное условие всех билетов: стенд с **уже выполненным Модулем 1** (адресация, маршрутизация, DNS `au-team.irpo`, SSH на порту 2026, пользователи `sshuser`/`net_admin`).

---

## Соответствие билетов и скриптов

| Билет | Скрипт | Где запускать | Тема |
|---|---|---|---|
| 1 | `scripts/ticket01_samba_dc.sh` | BR-SRV + HQ-CLI | Samba AD DC, группа `hq`, пользователи `user1hq…user5hq`, ввод HQ-CLI в домен через `net ads join`, проверка `net ads testjoin`, перезапуск SSSD, короткие имена пользователей |
| 2 | `scripts/ticket02_raid5.sh` | HQ-SRV | RAID 5 `/dev/md0`, ext4, монтирование в `/raid5`, `/etc/mdadm.conf` |
| 3 | `scripts/ticket03_nfs.sh` | HQ-SRV + HQ-CLI | NFS-сервер `/raid5/nfs`, автомонтирование на HQ-CLI в `/mnt/nfs` |
| 4 | `scripts/ticket04_chrony_ntp.sh` | HQ-RTR + клиенты | Сервер времени stratum 5, клиенты HQ-SRV/HQ-CLI/BR-RTR/BR-SRV |
| 5 | `scripts/ticket05_ansible.sh` | BR-SRV | Ansible в `/etc/ansible`, инвентарь, `ansible all -m ping` → pong |
| 6 | `scripts/ticket06_docker_wiki.sh` | BR-SRV | Docker + Compose, стек `wiki` (MediaWiki:8080) + `mariadb` |
| 7 | `scripts/ticket07_port_forward.sh` | HQ-RTR / BR-RTR | Проброс TCP 2024 и внешнего 80 → BR-SRV:8080 |
| 8 | `scripts/ticket08_moodle.sh` | HQ-SRV | Apache + PHP + MariaDB + Moodle, admin `P@ssw0rd` |
| 9 | `scripts/ticket09_mariadb_moodle.sh` | HQ-SRV | MariaDB: база `moodledb`, пользователь `moodle`, права |
| 10 | `scripts/ticket10_nginx_proxy.sh` | HQ-RTR (или указанный узел) | Обратный прокси nginx: `moodle.au-team.irpo`, `wiki.au-team.irpo` |
| 11 | `scripts/ticket11_sudo_hq.sh` | HQ-CLI | sudo для группы `hq` только `cat`, `grep`, `id` |
| 12 | `scripts/ticket12_hqcli_browser.sh` | HQ-CLI | Яндекс Браузер для организаций + проверка веб-сервисов |

---

## Как запускать

Все скрипты:
- запускаются **от root** (`sudo bash <скрипт>` или `su -` → `bash <скрипт>`);
- **интерактивны** — значения по умолчанию указаны в квадратных скобках, для подтверждения нажмите Enter;
- выводят сводку параметров и просят подтверждение перед изменениями;
- в конце печатают итоговую таблицу со статусами **OK / ERROR / SKIP**.

```bash
git clone https://github.com/tattookley-prog/bilety.git
cd bilety/scripts
chmod +x *.sh
sudo bash ticket01_samba_dc.sh
```

Билеты, охватывающие **две машины** (1, 3, 4, 7), при запуске спрашивают режим — серверную или клиентскую/роутерную часть.

---

## Проверка результата — `scripts/check_all.sh`

Универсальный скрипт проверки. **Сам нич��го не настраивает** — только читает состояние системы и выводит таблицу **OK / FAIL / SKIP**.

```bash
cd bilety/scripts
chmod +x check_all.sh
sudo bash check_all.sh
```

Порядок работы — **три уровня выбора**:

1. **Машина.** Скрипт определяет её по hostname и предлагает подтвердить, либо выбрать вручную из меню.
2. **Билет.** Можно проверить **все билеты этой машины** (пункт `a`) или **один конкретный** (1–12).
3. **Сторона** — только для двусторонних билетов (1, 3, 4, 7): сервер / клиент / роутер.

### Какая машина — какие билеты

| Машина | Билеты | Что проверяется |
|---|---|---|
| **BR-SRV** | 1, 5, 6 | служба `samba` + группа `hq`/участники; Ansible + `ping`→pong; контейнеры `wiki`/`mariadb` + :8080 |
| **HQ-SRV** | 2, 3, 8, 9 | RAID5 `/dev/md0` + `/raid5`; экспорт `/raid5/nfs`; Apache/MariaDB + `moodledb`; подключение `moodle` |
| **HQ-RTR** | 4, 7, 10 | chrony stratum 5; DNAT 2024; nginx + proxy_pass + заголовки |
| **BR-RTR** | 7 | DNAT 2024 → BR-SRV, 80 → BR-SRV:8080 |
| **HQ-CLI** | 1, 3, 4, 11, 12 | Kerberos/доменный пользователь; монтирование `/mnt/nfs`; синхронизация времени; sudo для `hq`; браузер + веб-сервисы |

> Меню всё равно позволяет выбрать **любой** билет 1–12 вручную, даже если он «не от этой машины» — на случай нестандартного распределения ролей.

### Статусы

- **OK** — проверка прошла (служба активна, файл/правило/запись на месте);
- **FAIL** — настройка не найдена или не работает;
- **SKIP** — в системе нет нужной утилиты (`mysql`, `curl`, `samba-tool`, `chronyc` …) — проверку выполнить нечем;
- для асинхронных вещей (Samba, синхронизация chrony, подъём MediaWiki) используется **ожидание с повтором** до 15–20 с, чтобы не ловить ложный FAIL.

### Пример вывода

```
============================================================
  check_all.sh — проверка билетов Модуля 2 (au-team.irpo)
============================================================
[INFO]  Автоопределена машина: hq-srv
Использовать её? [Y/n]: y

Машина: hq-srv.  Доступные билеты: 2 3 8 9
Что проверить?
  a) Все билеты этой машины (2 3 8 9)
  ...
Пункт [a / 0-12]: 2

================================================================================
  ИТОГОВАЯ ТАБЛИЦА ПРОВЕРОК — машина: hq-srv
================================================================================
СТАТУС   | ПРОВЕРКА
--------------------------------------------------------------------------------
[OK]     | Массив /dev/md0 активен (/proc/mdstat)
[OK]     | Уровень RAID 5
[OK]     | Файловая система ext4 на /dev/md0
[OK]     | /raid5 смонтирован
[OK]     | /raid5 прописан в /etc/fstab
[OK]     | /etc/mdadm.conf содержит ARRAY
--------------------------------------------------------------------------------
OK: 6 | FAIL: 0 | SKIP: 0
================================================================================
```

> Проверки запускаются **на той же машине**, где выполнялся билет (билет 2 — на HQ-SRV, билет 6 — на BR-SRV и т.д.), так как смотрят на локальные службы, файлы и правила.

---

## Топология и адресация (из Модуля 1)

| Устройство | IP | Примечание |
|---|---|---|
| HQ-RTR | 192.168.1.1 (VLAN100), 192.168.2.1 (VLAN200), 192.168.99.1 (VLAN999) | шлюз/DHCP/NTP |
| HQ-SRV | 192.168.1.2/27 | DNS, Moodle, RAID/NFS |
| HQ-CLI | DHCP 192.168.2.x/27 | Альт Рабочая станция |
| BR-RTR | 192.168.3.1/28 | |
| BR-SRV | 192.168.3.2/28 | Samba AD DC, Docker, Ansible |

Домен: **`au-team.irpo`** · DNS-форвардеры: `77.88.8.7`, `77.88.8.3`

---

## Технические особенности

| Возможность | Реализация |
|---|---|
| `set -euo pipefail` | остановка при любой ошибке |
| Цветной вывод | `[INFO]` / `[OK]` / `[WARN]` / `[ERROR]` |
| Проверка root | в начале каждого скрипта |
| Резервные копии | `.bak` для изменяемых конфигов |
| Значения по умолчанию | в квадратных скобках при вводе |
| Совместимость | `apt-get`, имена пакетов Альт Линукс |

> ⚠️ Скрипты меняют системную конфигурацию (сеть, диски, службы). Перед запуском на оценочном стенде убедитесь, что параметры по умолчанию соответствуют вашей адресации.

---

## Troubleshooting билет №1 (BR-SRV): `samba` падает из-за занятого порта 53

Симптом на BR-SRV:

```text
Failed to bind to 0.0.0.0:53 TCP - NT_STATUS_ADDRESS_ALREADY_ASSOCIATED
task_server_terminate: [dns failed to setup interfaces]
```

Причина: порт 53 уже занят другим DNS-демоном (чаще всего `dnsmasq`), который может возвращаться после перезагрузки, если он только отключён (`disabled`).

Для стабильной работы внутреннего DNS Samba AD DC (`--dns-backend=SAMBA_INTERNAL`) скрипт `ticket01_samba_dc.sh` в режиме BR-SRV:
- останавливает и **маскирует** конфликтующие DNS-службы (`dnsmasq`, `named`/`bind`/`bind9`, `systemd-resolved`);
- оставляет запуск DNS-роли за Samba;
- проверяет, что после запуска `samba` именно Samba слушает порт 53;
- сохраняет обратимость: маскировка снимается командой `systemctl unmask <служба>`.

Проверка после перезагрузки BR-SRV:

```bash
systemctl is-active samba      # active
ss -tulnp | grep ':53'         # слушает samba
systemctl is-enabled samba     # enabled
systemctl is-enabled dnsmasq   # masked
```

Откат (при необходимости вернуть службу):

```bash
systemctl unmask dnsmasq
systemctl enable --now dnsmasq
```

---

## Troubleshooting билет №1 (HQ-CLI): `[ERROR] join` / `id user1hq` не находит пользователя

Если после прогона `ticket01_samba_dc.sh` в режиме HQ-CLI итоговая таблица показывает `[ERROR] join` или доменные пользователи не видны, используйте следующие команды для диагностики.

### Быстрая диагностика

```bash
# 1. Проверить статус членства в домене
net ads testjoin

# 2. Проверить Kerberos-билет
klist

# 3. Проверить состояние SSSD
systemctl status sssd

# 4. Поискать пользователя
getent passwd user1hq
getent passwd "user1hq@au-team.irpo"
id user1hq
```

### Возможные причины и решения

| Симптом | Возможная причина | Решение |
|---|---|---|
| `Failed to join domain: Invalid configuration ("workgroup" set to 'HQ-CLI', should be 'AU-TEAM')` | `system-auth write ad` записал в `smb.conf` `workgroup` = имя хоста вместо NetBIOS-домена | Скрипт теперь сам приводит `smb.conf` к корректному виду (`workgroup=AU-TEAM`, `realm=AU-TEAM.IRPO`, `security=ads`) перед `net ads join`. При повторном запуске исправление происходит идемпотентно. |
| `net ads testjoin` → ошибка соединения | DC недоступен с HQ-CLI | Проверить маршрутизацию: `ping 192.168.3.2`, `traceroute 192.168.3.2` |
| `kinit` → «Clock skew» | Время на HQ-CLI и DC расходится > 5 мин | Синхронизировать NTP: `chronyc makestep` или `ntpdate 192.168.3.2` |
| `host au-team.irpo` не резолвится | Неверный DNS или DC не отвечает | Убедиться что `/etc/resolv.conf` содержит `nameserver 192.168.3.2` |
| `id user1hq` → «no such user» | Пользователи не созданы на BR-SRV | Выполнить пункт ниже |
| `id user1hq` → «no such user», но `id user1hq@au-team.irpo` работает | `use_fully_qualified_names = True` в sssd.conf | Скрипт исправляет автоматически; вручную: `sed -i 's/use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf && systemctl restart sssd` |

### Проверка пользователей на BR-SRV

Пользователи `user1hq..user5hq` и группа `hq` создаются на **BR-SRV** при запуске скрипта в режиме ROLE=1. Если samba ранее падала (например, из-за занятого порта 53), пользователи могут быть не созданы:

```bash
# На BR-SRV: проверить наличие пользователей
samba-tool user list | grep hq

# Если список пуст — создать пользователей и группу вручную на BR-SRV:
samba-tool group add hq
for i in 1 2 3 4 5; do
    samba-tool user create "user${i}hq" 'P@ssw0rd'
    samba-tool group addmembers hq "user${i}hq"
done
```

### Ручной ввод в домен (если скрипт завершился с ошибкой)

```bash
# На HQ-CLI от root:

# 1. Проверить и при необходимости исправить workgroup/realm/security в smb.conf
grep -iE 'workgroup|realm|security' /etc/samba/smb.conf
# Ожидаемый вывод: workgroup = AU-TEAM, realm = AU-TEAM.IRPO, security = ads
# Если отличается — перезаписать вручную (замените AU-TEAM/AU-TEAM.IRPO на свои значения):
cat > /etc/samba/smb.conf <<'EOF'
[global]
    workgroup = AU-TEAM
    realm = AU-TEAM.IRPO
    security = ads
    kerberos method = secrets and keytab
    dedicated keytab file = /etc/krb5.keytab
    winbind use default domain = yes
    template shell = /bin/bash
    template homedir = /home/%U
EOF

# 2. Проверить синтаксис
testparm -s

# 3. Получить Kerberos-билет и выполнить join
echo 'P@ssw0rd' | kinit administrator
net ads join -U 'administrator%P@ssw0rd'
# или по Kerberos-билету:
# net ads join -k

systemctl restart sssd
systemctl enable --now sssd

net ads testjoin   # должно вывести: Join is OK
id user1hq         # должно вернуть uid/gid
```

---

## Завершение билета №6: установка MediaWiki через мастер (с HQ-CLI)

После того как `ticket06_docker_wiki.sh` поднял стек, страница `http://192.168.3.2:8080` показывает **«LocalSettings.php not found. Please set up the wiki first.»** — это нормальное состояние свежего стека, а не ошибка. Установку завершают через веб-мастер.

### Где открывать ссылку

| Откуда | URL | Примечание |
|---|---|---|
| BR-SRV (локально) | `http://localhost:8080` | всегда работает, минует сеть |
| HQ-CLI (билет 12) | `http://192.168.3.2:8080` | нужна маршрутизация HQ↔BR |
| HQ-CLI (штатно) | `http://wiki.au-team.irpo` | после билетов 10 (nginx) и 12 (DNS) |
| Внешний ПК (сеть Proxmox `10.12.34.x`) | — | **не откроется**, стенд изолирован — открывайте внутри HQ-CLI через консоль Proxmox (noVNC) |

### Шаги мастера

1. Нажмите ссылку **set up the wiki** (или откройте `http://192.168.3.2:8080/mw-config/index.php`).
2. Язык интерфейса/вики → **Continue**.
3. Проверка окружения («The environment has been checked…») → **Continue**.
4. **Подключение к БД** — параметры строго из `wiki.yml`:

   | Поле | Значение |
   |---|---|
   | Тип БД | MariaDB, MySQL |
   | Хост БД | `mariadb` (имя контейнера, **НЕ** `localhost`) |
   | Имя БД | `mediawiki` |
   | Пользователь БД | `wiki` |
   | Пароль БД | `WikiP@ssw0rd` |

5. Database settings → «Использовать ту же учётную запись, что и для установки» → **Continue**.
6. Имя вики + учётная запись администратора (логин/пароль запишите!). Можно выбрать «I'm bored already, just install the wiki».
7. Установка → браузер скачает **`LocalSettings.php`** (на HQ-CLI это `~/Downloads`).
8. Перенесите файл на BR-SRV и смонтируйте в контейнер:

   ```bash
   # на HQ-CLI
   scp ~/Downloads/LocalSettings.php root@192.168.3.2:/root/LocalSettings.php
   ```

   ```bash
   # на BR-SRV: добавить в ~/wiki.yml у сервиса wiki:
   #   volumes:
   #     - /root/LocalSettings.php:/var/www/html/LocalSettings.php
   docker compose -f ~/wiki.yml up -d --force-recreate wiki
   ```

9. Проверка: `curl -I http://localhost:8080` → теперь `200/302` на саму вики, а не на «set up the wiki».

### Автоматическая установка (без мастера)

`ticket06_docker_wiki.sh` умеет завершить установку **автоматически**, минуя веб-мастер: после запуска стека скрипт спросит:

```
Завершить установку MediaWiki автоматически (минуя веб-мастер)? [y/N]:
```

Ответьте `y` — скрипт запустит `maintenance/install.php` прямо внутри контейнера, вынет `LocalSettings.php` на хост, добавит его в `wiki.yml` как volume и перезапустит контейнер `wiki`. В итоговой таблице появится строка `install: OK`, а веб-мастер и перенос по `scp` **не нужны**.

Эквивалентные команды вручную (на BR-SRV):

```bash
docker exec wiki php /var/www/html/maintenance/install.php \
  --dbtype mysql --dbserver mariadb --dbname mediawiki \
  --dbuser wiki --dbpass 'WikiP@ssw0rd' \
  --installdbuser root --installdbpass 'WikiR00t' \
  --server "http://192.168.3.2:8080" --scriptpath "" --lang ru \
  --pass 'P@ssw0rd' "AU-TEAM Wiki" Admin
docker cp wiki:/var/www/html/LocalSettings.php /root/LocalSettings.php
```

Затем добавить `volume` в `~/wiki.yml` и перезапустить:

```bash
# в ~/wiki.yml, в секцию wiki:
#   volumes:
#     - /root/LocalSettings.php:/var/www/html/LocalSettings.php
docker compose -f ~/wiki.yml up -d --force-recreate wiki
```

### Ошибка в мастере: `1045 Access denied for user 'wiki'`

Контейнер достучался до БД, но пара логин/пароль не подошла. Чаще всего причина — **устаревший том `mariadb_data`**: пользователь и пароль создаются образом MariaDB только при первом старте на пустом томе, а `docker rm` / `docker compose down` том не удаляют. Сброс (вики ещё пустая, терять нечего):

```bash
docker compose -f ~/wiki.yml down -v          # -v удаляет том mariadb_data
docker compose -f ~/wiki.yml up -d
sleep 20
docker exec -it mariadb mariadb -uwiki -pWikiP@ssw0rd -e "SHOW DATABASES;"   # проверка
```

Не удаляя том — поправить пользователя вручную (root-пароль БД `WikiR00t`):

```bash
docker exec -it mariadb mariadb -uroot -pWikiR00t -e "
  ALTER USER 'wiki'@'%' IDENTIFIED BY 'WikiP@ssw0rd';
  GRANT ALL PRIVILEGES ON mediawiki.* TO 'wiki'@'%';
  FLUSH PRIVILEGES;"
```

---

## Troubleshooting: `scp` с HQ-CLI на BR-SRV не отправляет `LocalSettings.php`

`LocalSettings.php` скачивается на ту машину, где открыт браузер (HQ-CLI), а контейнер — на BR-SRV, поэтому файл переносят по `scp`. Если перенос не идёт — **да, причина чаще всего на стороне самой BR-SRV**: она выступает принимающим SSH-сервером, и её `sshd`/firewall решают, пустить ли соединение.
`scripts/ticket06_docker_wiki.sh` теперь умеет **опционально** включить вход root по паролю в `sshd` (для этого сценария `scp`) — по отдельному подтверждению в интерактивном диалоге.

### Сначала диагностика (с HQ-CLI)

```bash
ping 192.168.3.2                                  # есть ли маршрут HQ↔BR
ssh -v root@192.168.3.2                           # доходит ли до sshd, какая ошибка авторизации
scp -v LocalSettings.php root@192.168.3.2:/root/  # подробный лог переноса
```

Если не проходит даже `ping` — это **маршрутизация**, а не scp (проверьте билет 7 и шлюзы по умолчанию).

### Возможные ограничения на самой BR-SRV

| Симптом | Причина на BR-SRV | Решение |
|---|---|---|
| `Connection refused` (порт 22) | sshd не запущен | `systemctl enable --now sshd` |
| `Permission denied (publickey)` для root | `PermitRootLogin prohibit-password`/`no` в `/etc/openssh/sshd_config` | поставить `PermitRootLogin yes` → `systemctl restart sshd`, либо копировать под обычным пользователем |
| Пароль не принимается | `PasswordAuthentication no` | включить `PasswordAuthentication yes` → restart sshd, либо настроить ключи |
| Таймаут соединения | firewall (iptables/nftables) на BR-SRV блокирует 22/tcp | `iptables -L INPUT -n`; разрешить 22/tcp |
| `No route to host` | нет маршрута HQ↔BR | билет 7 / шлюзы по умолчанию |

> На Альт Линукс конфиг OpenSSH обычно лежит в `/etc/openssh/`. Точный путь можно проверить командой `rpm -ql openssh-server | grep sshd_config`, а эффективные параметры — `sshd -T | grep -iE 'permitrootlogin|passwordauthentication'`.
> BR-SRV — это Samba AD DC. После ввода в домен меняются PAM/nsswitch, но **root по SSH** обычно работает, если `sshd` запущен и стоит `PermitRootLogin yes`.

### Обходные пути, если scp быстро не починить

1. **Сгенерировать `LocalSettings.php` прямо в контейнере** (перенос не нужен вообще) — на BR-SRV:

   ```bash
   docker exec -it wiki php maintenance/install.php \
     --dbserver mariadb --dbname mediawiki \
     --dbuser wiki --dbpass 'WikiP@ssw0rd' \
     --installdbuser root --installdbpass 'WikiR00t' \
     --server "http://192.168.3.2:8080" --scriptpath "" \
     --pass 'AdminP@ssw0rd' "AU-TEAM Wiki" admin
   # вынуть файл из контейнера и смонтировать постоянно:
   docker cp wiki:/var/www/html/LocalSettings.php /root/LocalSettings.php
   ```

   Затем добавить `volume` в `wiki.yml` и `docker compose -f ~/wiki.yml up -d --force-recreate wiki`.

2. **Обратное направление** (если на HQ-CLI есть sshd) — тянуть файл с BR-SRV:
   `scp root@<IP-HQ-CLI>:~/Downloads/LocalSettings.php /root/`.

3. **Скопировать содержимое вручную**: открыть `LocalSettings.php` в текстовом редакторе на HQ-CLI, скопировать текст и на BR-SRV (консоль Proxmox) вставить в
   `cat > /root/LocalSettings.php <<'EOF' … EOF`.

4. **Через общий ресурс**: NFS (билет 3) или другой общий каталог между машинами.
