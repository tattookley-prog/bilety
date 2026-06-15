#!/usr/bin/env python3
"""
server/admin.py — утилита администратора для управления лицензиями bilety.

Субкоманды:
  init                            — создать схему БД (если не существует)
  generate --count N --uses M     — сгенерировать N логинов с M запусками
  mark-paid   <login>             — пометить логин как оплаченный
  mark-unpaid <login>             — снять отметку оплаты
  set-uses    <login> <n>         — установить количество оставшихся запусков
  list                            — вывести список всех логинов
  revoke      <login>             — отозвать (заблокировать) аккаунт

Примеры:
  python admin.py init
  python admin.py generate --count 20 --uses 5
  python admin.py mark-paid user01
  python admin.py list
  python admin.py set-uses user03 10
  python admin.py revoke user07
"""

import argparse
import os
import secrets
import sqlite3
import string
import sys

from werkzeug.security import generate_password_hash

# ---------------------------------------------------------------------------
# Конфигурация — та же переменная окружения, что и в app.py
# ---------------------------------------------------------------------------
BILETY_DB = os.environ.get(
    "BILETY_DB",
    os.path.join(os.path.dirname(__file__), "licenses.db"),
)

# ---------------------------------------------------------------------------
# Вспомогательные функции
# ---------------------------------------------------------------------------

def get_conn() -> sqlite3.Connection:
    """Открыть соединение с БД. Вернуть sqlite3.Connection."""
    conn = sqlite3.connect(BILETY_DB)
    conn.row_factory = sqlite3.Row
    return conn


def ensure_db_exists():
    """Убедиться, что файл БД существует; выйти с ошибкой, если нет."""
    if not os.path.isfile(BILETY_DB):
        print(
            f"[ERROR] База данных не найдена: {BILETY_DB}\n"
            "Сначала выполните:  python admin.py init",
            file=sys.stderr,
        )
        sys.exit(1)


def generate_password(length: int = 12) -> str:
    """Сгенерировать случайный пароль из букв и цифр."""
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


# ---------------------------------------------------------------------------
# Субкоманды
# ---------------------------------------------------------------------------

def cmd_init(_args):
    """Создать схему БД (таблица licenses), если ещё не существует."""
    conn = get_conn()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS licenses (
            login         TEXT PRIMARY KEY,
            password_hash TEXT NOT NULL,
            paid          INTEGER NOT NULL DEFAULT 0,
            uses_left     INTEGER NOT NULL DEFAULT 0,
            created_at    TEXT NOT NULL DEFAULT (datetime('now'))
        )
    """)
    conn.commit()
    conn.close()

    # Установить ограничительные права на файл БД
    if os.path.isfile(BILETY_DB):
        os.chmod(BILETY_DB, 0o600)

    print(f"[OK] База данных инициализирована: {BILETY_DB}")


def cmd_generate(args):
    """Сгенерировать N логинов с M допустимыми запусками каждый."""
    ensure_db_exists()
    count: int = args.count
    uses: int  = args.uses

    conn = get_conn()

    print(f"\n{'='*60}")
    print(f"  Сгенерированные учётные записи ({count} шт., по {uses} запусков)")
    print(f"  СОХРАНИТЕ ЭТОТ СПИСОК — пароли больше не будут показаны!")
    print(f"{'='*60}")
    print(f"  {'Логин':<12}  {'Пароль':<16}  {'Оплачен':<8}  {'Запусков'}")
    print(f"  {'-'*12}  {'-'*16}  {'-'*8}  {'-'*8}")

    for i in range(1, count + 1):
        login    = f"user{i:02d}"
        password = generate_password()
        pw_hash  = generate_password_hash(password)

        # INSERT OR REPLACE — перезапишет, если логин уже существует
        conn.execute(
            "INSERT OR REPLACE INTO licenses (login, password_hash, paid, uses_left) "
            "VALUES (?, ?, 0, ?)",
            (login, pw_hash, uses),
        )
        # Намеренно выводим plaintext-пароль один раз — он нигде не сохраняется,
        # только здесь для распределения покупателям. nosec: intentional one-time display.
        print(f"  {login:<12}  {password:<16}  {'нет':<8}  {uses}")  # noqa: S106

    conn.commit()
    conn.close()

    print(f"{'='*60}")
    print(f"[OK] {count} учётных записей сохранено в БД.")
    print(f"     Используйте  python admin.py mark-paid <login>  после оплаты.\n")


def cmd_mark_paid(args):
    """Пометить логин как оплаченный (paid=1)."""
    ensure_db_exists()
    conn = get_conn()
    cur = conn.execute("UPDATE licenses SET paid=1 WHERE login=?", (args.login,))
    conn.commit()
    conn.close()
    if cur.rowcount:
        print(f"[OK] {args.login} — аккаунт активирован (paid=1).")
    else:
        print(f"[WARN] Логин '{args.login}' не найден.", file=sys.stderr)


def cmd_mark_unpaid(args):
    """Снять отметку оплаты (paid=0)."""
    ensure_db_exists()
    conn = get_conn()
    cur = conn.execute("UPDATE licenses SET paid=0 WHERE login=?", (args.login,))
    conn.commit()
    conn.close()
    if cur.rowcount:
        print(f"[OK] {args.login} — аккаунт деактивирован (paid=0).")
    else:
        print(f"[WARN] Логин '{args.login}' не найден.", file=sys.stderr)


def cmd_set_uses(args):
    """Установить количество оставшихся запусков для логина."""
    ensure_db_exists()
    conn = get_conn()
    cur = conn.execute(
        "UPDATE licenses SET uses_left=? WHERE login=?", (args.n, args.login)
    )
    conn.commit()
    conn.close()
    if cur.rowcount:
        print(f"[OK] {args.login} — uses_left установлен в {args.n}.")
    else:
        print(f"[WARN] Логин '{args.login}' не найден.", file=sys.stderr)


def cmd_list(_args):
    """Вывести список всех логинов с их статусом."""
    ensure_db_exists()
    conn = get_conn()
    rows = conn.execute(
        "SELECT login, paid, uses_left, created_at FROM licenses ORDER BY login"
    ).fetchall()
    conn.close()

    if not rows:
        print("[INFO] База данных пуста.")
        return

    print(f"\n{'='*60}")
    print(f"  {'Логин':<12}  {'Оплачен':<10}  {'Запусков':<10}  {'Создан'}")
    print(f"  {'-'*12}  {'-'*10}  {'-'*10}  {'-'*19}")
    for row in rows:
        paid_str = "ДА" if row["paid"] else "нет"
        print(
            f"  {row['login']:<12}  {paid_str:<10}  {row['uses_left']:<10}  {row['created_at']}"
        )
    print(f"{'='*60}\n")


def cmd_revoke(args):
    """Отозвать аккаунт: paid=0, uses_left=0."""
    ensure_db_exists()
    conn = get_conn()
    cur = conn.execute(
        "UPDATE licenses SET paid=0, uses_left=0 WHERE login=?", (args.login,)
    )
    conn.commit()
    conn.close()
    if cur.rowcount:
        print(f"[OK] {args.login} — аккаунт заблокирован (paid=0, uses_left=0).")
    else:
        print(f"[WARN] Логин '{args.login}' не найден.", file=sys.stderr)


# ---------------------------------------------------------------------------
# Парсер аргументов
# ---------------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="admin.py",
        description="Утилита управления лицензиями bilety.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    # init
    sub.add_parser("init", help="Создать схему БД (если не существует).")

    # generate
    p_gen = sub.add_parser("generate", help="Сгенерировать учётные записи.")
    p_gen.add_argument("--count", type=int, default=20, help="Количество логинов (по умолчанию 20).")
    p_gen.add_argument("--uses",  type=int, default=5,  help="Запусков на логин (по умолчанию 5).")

    # mark-paid
    p_mp = sub.add_parser("mark-paid", help="Активировать аккаунт (paid=1).")
    p_mp.add_argument("login", help="Логин пользователя.")

    # mark-unpaid
    p_mu = sub.add_parser("mark-unpaid", help="Деактивировать аккаунт (paid=0).")
    p_mu.add_argument("login", help="Логин пользователя.")

    # set-uses
    p_su = sub.add_parser("set-uses", help="Установить количество оставшихся запусков.")
    p_su.add_argument("login", help="Логин пользователя.")
    p_su.add_argument("n",     type=int, help="Новое значение uses_left.")

    # list
    sub.add_parser("list", help="Показать все аккаунты.")

    # revoke
    p_rev = sub.add_parser("revoke", help="Заблокировать аккаунт (paid=0, uses_left=0).")
    p_rev.add_argument("login", help="Логин пользователя.")

    return parser


# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
COMMANDS = {
    "init":        cmd_init,
    "generate":    cmd_generate,
    "mark-paid":   cmd_mark_paid,
    "mark-unpaid": cmd_mark_unpaid,
    "set-uses":    cmd_set_uses,
    "list":        cmd_list,
    "revoke":      cmd_revoke,
}

if __name__ == "__main__":
    parser = build_parser()
    args = parser.parse_args()
    COMMANDS[args.command](args)
