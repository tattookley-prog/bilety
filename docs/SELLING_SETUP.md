# Руководство по продаже скриптов bilety

Этот документ описывает, как настроить систему продажи скриптов билетов своей учебной группе: развернуть сервер авторизации на PythonAnywhere, выдать оплаченные логины и объяснить покупателям, как пользоваться клиентом.

---

## Оглавление

1. [Общая архитектура](#1-общая-архитектура)
2. [Что хранится где](#2-что-хранится-где)
3. [Развёртывание на PythonAnywhere](#3-развёртывание-на-pythonanywhere)
4. [Настройка базы данных и создание логинов](#4-настройка-базы-данных-и-создание-логинов)
5. [Как выдать доступ после оплаты](#5-как-выдать-доступ-после-оплаты)
6. [Как покупатели запускают скрипты](#6-как-покупатели-запускают-скрипты)
7. [Управление логинами (шпаргалка)](#7-управление-логинами-шпаргалка)
8. [Перенос на Fly.io или VPS (опционально)](#8-перенос-на-flyio-или-vps-опционально)
9. [Важные оговорки о безопасности](#9-важные-оговорки-о-безопасности)

---

## 1. Общая архитектура

```
Покупатель                    Твой сервер              Приватная папка
(публичный репо)              (PythonAnywhere)          (только на сервере)
                              
client/client.sh   ──HTTPS──►  server/app.py  ──читает──►  private_scripts/
                                   │                        ticket01_samba_dc.sh
                               проверяет:                   ticket02_raid5.sh
                               • логин/пароль               ...
                               • оплачен ли аккаунт         ticket12_dns_add_records.sh
                               • остались ли запуски
                                   │
                               licenses.db (SQLite)
                               20 логинов × 5 запусков
```

**Принцип безопасности:**
- Публичный репозиторий содержит только `client/client.sh` — тонкий загрузчик без логики билетов.
- Сами скрипты билетов (`*.sh`) хранятся только на твоём сервере в папке `private_scripts/`, которая **не коммитится в git**.
- Все проверки (оплата, лимит запусков) и хранение скриптов — на сервере под твоим контролем.

---

## 2. Что хранится где

| Место | Что там | Публично? |
|-------|---------|-----------|
| Публичный git-репо | `client/client.sh`, `server/app.py`, `server/admin.py` | ✅ Да |
| `server/licenses.db` | Логины, хэши паролей, счётчики | ❌ Только на сервере |
| `server/private_scripts/*.sh` | Настоящие скрипты билетов | ❌ Только на сервере |

> `server/.gitignore` гарантирует, что `licenses.db` и `private_scripts/*.sh` **никогда не попадут в git** даже случайно.

---

## 3. Развёртывание на PythonAnywhere

### Шаг 1: Зарегистрируйся на PythonAnywhere

Перейди на [pythonanywhere.com](https://www.pythonanywhere.com) и создай бесплатный аккаунт. Имя аккаунта будет частью URL твоего сервера: `https://<твой_логин>.pythonanywhere.com`.

### Шаг 2: Загрузи файлы сервера

В консоли PythonAnywhere (раздел **Consoles → Bash**):

```bash
# Создай рабочую папку
mkdir -p ~/bilety/server/private_scripts

# Загрузи файлы сервера
# Вариант А — через git (если репо открытый):
cd ~/bilety
git clone https://github.com/tattookley-prog/bilety.git .

# Вариант Б — загрузи вручную через Files → Upload:
# Загрузи: server/app.py, server/admin.py, server/requirements.txt
```

### Шаг 3: Скопируй скрипты билетов в приватную папку

```bash
# Скопируй настоящие скрипты из репо в приватную папку
cp ~/bilety/scripts/*.sh ~/bilety/server/private_scripts/

# Установи ограничительные права доступа
chmod 700 ~/bilety/server/private_scripts/
chmod 600 ~/bilety/server/private_scripts/*.sh
```

> ⚠️ Убедись, что `private_scripts/` недоступна извне как статические файлы. На PythonAnywhere статические файлы обслуживаются только из явно указанных папок — по умолчанию всё безопасно.

### Шаг 4: Создай виртуальное окружение и установи зависимости

```bash
cd ~/bilety
python3 -m venv venv
source venv/bin/activate
pip install -r server/requirements.txt
```

### Шаг 5: Настрой переменные окружения

В консоли Bash добавь в `~/.bashrc` (для ручного использования `admin.py`):

```bash
export BILETY_DB="/home/<твой_логин>/bilety/server/licenses.db"
export BILETY_SCRIPTS_DIR="/home/<твой_логин>/bilety/server/private_scripts"
```

Для Flask-приложения переменные задаются через WSGI-файл (см. ниже).

### Шаг 6: Создай веб-приложение (WSGI)

1. Перейди в раздел **Web** → **Add a new web app**.
2. Выбери **Manual configuration** (не "Flask" — нам нужна ручная настройка).
3. Выбери Python 3.10 (или актуальную версию).
4. Отредактируй файл WSGI (`/var/www/<твой_логин>_pythonanywhere_com_wsgi.py`):

```python
import sys
import os

# Добавляем папку сервера в путь
sys.path.insert(0, '/home/<твой_логин>/bilety/server')

# Переменные окружения
os.environ['BILETY_DB']          = '/home/<твой_логин>/bilety/server/licenses.db'
os.environ['BILETY_SCRIPTS_DIR'] = '/home/<твой_логин>/bilety/server/private_scripts'

from app import app as application
```

5. В разделе **Virtualenv** укажи путь: `/home/<твой_логин>/bilety/venv`.
6. Нажми **Reload** — сервер запущен!

### Шаг 7: Проверь работу сервера

```bash
curl https://<твой_логин>.pythonanywhere.com/health
# Должен ответить: ok
```

---

## 4. Настройка базы данных и создание логинов

В консоли PythonAnywhere (активируй venv):

```bash
cd ~/bilety
source venv/bin/activate
export BILETY_DB="/home/<твой_логин>/bilety/server/licenses.db"

# Создаём схему БД
python server/admin.py init

# Генерируем 20 логинов по 5 запусков каждый
# СОХРАНИ ВЫВОД — пароли показываются только один раз!
python server/admin.py generate --count 20 --uses 5
```

Вывод будет примерно такой:
```
============================================================
  Сгенерированные учётные записи (20 шт., по 5 запусков)
  СОХРАНИТЕ ЭТОТ СПИСОК — пароли больше не будут показаны!
============================================================
  Логин         Пароль            Оплачен   Запусков
  ------------  ----------------  --------  --------
  user01        aB3xK9mP2rQw      нет       5
  user02        Lz7nY4sG8hEj      нет       5
  ...
============================================================
```

> ⚠️ Сохрани этот список! Пароли хранятся в БД только в виде хэша — восстановить их невозможно.

Установи права на файл БД:
```bash
chmod 600 ~/bilety/server/licenses.db
```

---

## 5. Как выдать доступ после оплаты

По умолчанию все логины имеют `paid=0` (не оплачены) и **не смогут получить скрипты**. После того как покупатель оплатил:

```bash
cd ~/bilety
source venv/bin/activate
export BILETY_DB="/home/<твой_логин>/bilety/server/licenses.db"

# Активировать аккаунт (после получения оплаты)
python server/admin.py mark-paid user03

# Проверить текущий статус всех аккаунтов
python server/admin.py list
```

Чтобы **отозвать доступ** (например, если покупатель потребовал возврат):
```bash
python server/admin.py revoke user03
```

---

## 6. Как покупатели запускают скрипты

**Передай покупателю:**
1. Логин и пароль из сгенерированного списка.
2. Файл `client/client.sh` из репозитория (или ссылку на него).
3. URL твоего сервера: `https://<твой_логин>.pythonanywhere.com`

**Покупатель запускает:**

```bash
# Скачать клиент
curl -O https://raw.githubusercontent.com/tattookley-prog/bilety/main/client/client.sh

# Задать URL сервера (один раз)
export BILETY_SERVER_URL="https://<твой_логин>.pythonanywhere.com"

# Запустить (интерактивный режим)
bash client.sh

# Или передать номер билета сразу
bash client.sh 12
```

Клиент спросит логин и пароль, подключится к твоему серверу, и если всё в порядке — выполнит скрипт. После 5 успешных запусков аккаунт блокируется.

---

## 7. Управление логинами (шпаргалка)

```bash
# Просмотр всех аккаунтов
python server/admin.py list

# Активировать после оплаты
python server/admin.py mark-paid user05

# Деактивировать
python server/admin.py mark-unpaid user05

# Добавить запусков (например, продал дополнительные)
python server/admin.py set-uses user05 10

# Заблокировать полностью (paid=0, uses_left=0)
python server/admin.py revoke user05

# Перегенерировать всё заново (перезапишет существующих пользователей!)
python server/admin.py generate --count 20 --uses 5
```

---

## 8. Перенос на Fly.io или VPS (опционально)

Если понадобится перенести на другой хостинг:

### Fly.io

```bash
# Установи flyctl
curl -L https://fly.io/install.sh | sh

# В папке server/ создай Dockerfile:
# FROM python:3.11-slim
# WORKDIR /app
# COPY requirements.txt .
# RUN pip install -r requirements.txt
# COPY app.py .
# CMD ["gunicorn", "-b", "0.0.0.0:8080", "app:app"]

fly launch
fly secrets set BILETY_DB=/data/licenses.db BILETY_SCRIPTS_DIR=/data/private_scripts
fly volumes create bilety_data --size 1
```

### VPS (Ubuntu/Debian)

```bash
# Установи зависимости
pip install -r server/requirements.txt

# Запусти через gunicorn
cd server
BILETY_DB=/opt/bilety/licenses.db \
BILETY_SCRIPTS_DIR=/opt/bilety/private_scripts \
gunicorn -b 127.0.0.1:5000 app:app

# Настрой nginx как обратный прокси и SSL через certbot
```

---

## 9. Важные оговорки о безопасности

**Что эта система защищает:**
- ✅ Тела скриптов никогда не попадают в публичный git-репозиторий.
- ✅ Скрипт выдаётся только после оплаты (`paid=1`) и при наличии запусков (`uses_left > 0`).
- ✅ Счётчик запусков хранится на твоём сервере — покупатель не может его подделать.
- ✅ Пароли хранятся в виде pbkdf2:sha256-хэшей (werkzeug) — даже при утечке БД пароли не восстановить.

**Что эта система НЕ защищает:**
- ❌ Покупатель, получив скрипт, может его сохранить и использовать сколько угодно раз офлайн.
- ❌ Покупатель может поделиться скриптом с другими после получения.
- ❌ Защита работает только пока твой сервер онлайн.

**Как защитить сервер:**
- Никому не передавай файл `licenses.db` — в нём хэши паролей всех покупателей.
- Папку `private_scripts/` держи с правами `chmod 700`.
- Не добавляй `licenses.db` и `private_scripts/` в git (они уже в `.gitignore`).
- Регулярно делай резервную копию БД: `cp licenses.db licenses.db.bak`.
