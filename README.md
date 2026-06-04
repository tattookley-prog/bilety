# bilety — скрипты под 12 экзаменационных билетов (Модуль 2)

Bash-скрипты автоматизации практических заданий по специальности **09.02.06 «Сетевое и системное администрирование»**, **Модуль 2**.

Все скрипты рассчитаны на **Альт Сервер** (узлы HQ-SRV / BR-SRV) и **Альт Рабочая станция** (HQ-CLI). Маршрутизаторы HQ-RTR / BR-RTR — Альт JeOS / Linux.

> Исходное условие всех билетов: стенд с **уже выполненным Модулем 1** (адресация, маршрутизация, DNS `au-team.irpo`, SSH на порту 2026, пользователи `sshuser`/`net_admin`).

---

## Соответствие билетов и скриптов

| Билет | Скрипт | Где запускать | Тема |
|---|---|---|---|
| 1 | `scripts/ticket01_samba_dc.sh` | BR-SRV + HQ-CLI | Samba AD DC, группа `hq`, пользователи `user1hq…user5hq`, ввод HQ-CLI в домен |
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
