#!/usr/bin/env python3
"""
server/app.py — Flask-приложение для лицензионного сервера bilety.

Единственный публичный эндпоинт для покупателей: POST /get
Принимает login, password, ticket; проверяет базу данных и возвращает
тело скрипта только при успешной оплате и наличии оставшихся запусков.

GET /health — используется для мониторинга (uptime-чеки).
"""

import os
import sqlite3
import contextlib

from flask import Flask, request, jsonify, make_response
from werkzeug.security import check_password_hash

# ---------------------------------------------------------------------------
# Конфигурация через переменные окружения
# ---------------------------------------------------------------------------
# Путь к SQLite-базе лицензий. При деплое на PythonAnywhere укажите
# что-то вроде /home/<username>/bilety/licenses.db
BILETY_DB = os.environ.get("BILETY_DB", os.path.join(os.path.dirname(__file__), "licenses.db"))

# Папка с приватными скриптами (НЕ публикуется, НЕ git-tracked).
# При деплое скопируйте настоящие scripts/*.sh сюда и установите chmod 700.
BILETY_SCRIPTS_DIR = os.environ.get(
    "BILETY_SCRIPTS_DIR",
    os.path.join(os.path.dirname(__file__), "private_scripts"),
)

# ---------------------------------------------------------------------------
# Белый список допустимых имён скриптов (защита от path traversal).
# Ключ: ticket-id, который передаёт клиент → значение: имя файла в private_scripts/.
# Расширяйте список при добавлении новых билетов.
# ---------------------------------------------------------------------------
TICKET_ALLOWLIST: dict[str, str] = {
    "1":                          "ticket01_samba_dc.sh",
    "ticket01":                   "ticket01_samba_dc.sh",
    "ticket01_samba_dc":          "ticket01_samba_dc.sh",
    "2":                          "ticket02_raid5.sh",
    "ticket02":                   "ticket02_raid5.sh",
    "ticket02_raid5":             "ticket02_raid5.sh",
    "3":                          "ticket03_nfs.sh",
    "ticket03":                   "ticket03_nfs.sh",
    "ticket03_nfs":               "ticket03_nfs.sh",
    "4":                          "ticket04_chrony_ntp.sh",
    "ticket04":                   "ticket04_chrony_ntp.sh",
    "ticket04_chrony_ntp":        "ticket04_chrony_ntp.sh",
    "5":                          "ticket05_ansible.sh",
    "ticket05":                   "ticket05_ansible.sh",
    "ticket05_ansible":           "ticket05_ansible.sh",
    "6":                          "ticket06_docker_wiki.sh",
    "ticket06":                   "ticket06_docker_wiki.sh",
    "ticket06_docker_wiki":       "ticket06_docker_wiki.sh",
    "7":                          "ticket07_port_forward.sh",
    "ticket07":                   "ticket07_port_forward.sh",
    "ticket07_port_forward":      "ticket07_port_forward.sh",
    "8":                          "ticket08_moodle.sh",
    "ticket08":                   "ticket08_moodle.sh",
    "ticket08_moodle":            "ticket08_moodle.sh",
    "9":                          "ticket09_mariadb_moodle.sh",
    "ticket09":                   "ticket09_mariadb_moodle.sh",
    "ticket09_mariadb_moodle":    "ticket09_mariadb_moodle.sh",
    "10":                         "ticket10_nginx_proxy.sh",
    "ticket10":                   "ticket10_nginx_proxy.sh",
    "ticket10_nginx_proxy":       "ticket10_nginx_proxy.sh",
    "11":                         "ticket11_sudo_hq.sh",
    "ticket11":                   "ticket11_sudo_hq.sh",
    "ticket11_sudo_hq":           "ticket11_sudo_hq.sh",
    "12":                         "ticket12_dns_add_records.sh",
    "ticket12":                   "ticket12_dns_add_records.sh",
    "ticket12_dns_add_records":   "ticket12_dns_add_records.sh",
    "12b":                        "ticket12_hqcli_browser.sh",
    "ticket12b":                  "ticket12_hqcli_browser.sh",
    "ticket12_hqcli_browser":     "ticket12_hqcli_browser.sh",
    # Вспомогательные скрипты для минимальной настройки
    "min_setup_br-srv_t12":       "min_setup_br-srv_t12.sh",
    "min_setup_hq-rtr_t12":       "min_setup_hq-rtr_t12.sh",
    "min_setup_hq-srv_t12":       "min_setup_hq-srv_t12.sh",
    "min_setup_br-srv_t10":       "min_setup_br-srv_t10.sh",
    "min_setup_hq-srv_t10":       "min_setup_hq-srv_t10.sh",
}

# ---------------------------------------------------------------------------
# Инициализация Flask
# ---------------------------------------------------------------------------
app = Flask(__name__)


@contextlib.contextmanager
def get_db():
    """Контекстный менеджер: открывает соединение с БД и закрывает его."""
    conn = sqlite3.connect(BILETY_DB)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Эндпоинты
# ---------------------------------------------------------------------------

@app.route("/health", methods=["GET"])
def health():
    """Простая проверка работоспособности сервера."""
    return "ok", 200


@app.route("/get", methods=["POST"])
def get_script():
    """
    POST /get — выдать тело скрипта авторизованному покупателю.

    Ожидаемые поля (form или JSON):
      login    — строка
      password — строка (открытый текст; сравнивается с хэшем в БД)
      ticket   — строка-идентификатор из TICKET_ALLOWLIST

    Коды ответа:
      200 — скрипт возвращён, заголовок X-Uses-Left содержит остаток запусков.
      400 — отсутствует обязательный параметр.
      401 — неверный логин или пароль.
      402 — аккаунт не оплачен.
      403 — лимит запусков исчерпан.
      404 — скрипт не найден на сервере (нужно скопировать файл в private_scripts/).
    """
    # --- Получаем параметры (form или JSON) ---
    if request.is_json:
        data = request.get_json(force=True) or {}
    else:
        data = request.form

    login    = (data.get("login")  or "").strip()
    # Поле называется "cred" — короткое нейтральное имя для учётных данных.
    # Клиент (client/client.sh) передаёт пароль именно в этом поле.
    password = (data.get("cred")   or "").strip()
    ticket   = (data.get("ticket") or "").strip()

    if not login or not password or not ticket:
        return make_response("Отсутствует один из параметров: login, cred, ticket", 400)

    # --- Проверка ticket по белому списку (защита от path traversal) ---
    filename = TICKET_ALLOWLIST.get(ticket)
    if filename is None:
        return make_response(
            f"Неизвестный ticket '{ticket}'. Допустимые значения: 1–12 (и варианты типа ticket12_dns_add_records).",
            400,
        )

    # --- Работа с БД ---
    with get_db() as conn:
        row = conn.execute(
            "SELECT password_hash, paid, uses_left FROM licenses WHERE login = ?",
            (login,),
        ).fetchone()

    # Логин не найден → возвращаем такой же ответ, как при неверном пароле,
    # чтобы не давать информацию об существующих логинах.
    if row is None or not check_password_hash(row["password_hash"], password):
        return make_response("Неверный логин или пароль.", 401)

    if not row["paid"]:
        return make_response(
            "Аккаунт не оплачен. Пожалуйста, произведите оплату и дождитесь активации.",
            402,
        )

    if row["uses_left"] <= 0:
        return make_response(
            "Лимит запусков исчерпан (0 из 5 осталось). Обратитесь к продавцу.",
            403,
        )

    # --- Атомарный декремент счётчика ---
    # UPDATE ... WHERE uses_left > 0 гарантирует, что при гонке двух запросов
    # счётчик не уйдёт в минус; проверяем кол-во изменённых строк.
    with get_db() as conn:
        cur = conn.execute(
            "UPDATE licenses SET uses_left = uses_left - 1 WHERE login = ? AND uses_left > 0",
            (login,),
        )
        conn.commit()
        if cur.rowcount == 0:
            # Гонка: кто-то другой уже забрал последний запуск
            return make_response("Лимит запусков исчерпан.", 403)

        # Получаем актуальное значение после декремента
        new_uses_left = conn.execute(
            "SELECT uses_left FROM licenses WHERE login = ?", (login,)
        ).fetchone()["uses_left"]

    # --- Читаем тело скрипта с диска ---
    script_path = os.path.join(BILETY_SCRIPTS_DIR, filename)
    # Дополнительная проверка: убедимся, что путь не выходит за пределы папки
    script_path = os.path.realpath(script_path)
    scripts_dir_real = os.path.realpath(BILETY_SCRIPTS_DIR)
    if not script_path.startswith(scripts_dir_real + os.sep):
        return make_response("Недопустимый путь.", 400)

    if not os.path.isfile(script_path):
        return make_response(
            f"Скрипт '{filename}' не найден на сервере. "
            "Пожалуйста, сообщите продавцу (файл не скопирован в private_scripts/).",
            404,
        )

    with open(script_path, "r", encoding="utf-8") as f:
        body = f.read()

    response = make_response(body, 200)
    response.headers["Content-Type"] = "text/plain; charset=utf-8"
    response.headers["X-Uses-Left"] = str(new_uses_left)
    return response


# ---------------------------------------------------------------------------
# Запуск для разработки (на PythonAnywhere используется WSGI)
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(debug=False, host="127.0.0.1", port=5000)
