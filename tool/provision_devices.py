#!/usr/bin/env python3
"""Заводской генератор партии аппаратов (R4).

Работает ПОЛНОСТЬЮ ЛОКАЛЬНО: без обращения к облаку и без ключей Supabase.
Для каждого аппарата создаёт:
  * токен устройства (криптостойкий, 32 байта, base64url);
  * код привязки XXXX-XXXX-XXXX (12 знаков алфавита без 0/O/1/I/L);
  * соль и хэш кода (sha256(соль + КОД_ЗАГЛАВНЫМИ_БЕЗ_ДЕФИСОВ), hex) — так же,
    как проверяет БД (supabase/migrations/20261007000000_r4_tenancy.sql).

Выход (каталог provisioning_out/<партия>/, он в .gitignore, в git не попадает;
по умолчанию партия называется batch_<дата>):
  batch.sql           вставки в devices (с явным кольцом --ring, по умолчанию
                      test) и device_claims (токены и ХЭШИ кодов; открытых кодов
                      нет);
  labels.csv          device_id и ОТКРЫТЫЙ код — для наклеек;
  configs/<ID>.json   по ОДНОМУ файлу на аппарат (формат 1: config_id, device_id,
                      cloud_url, anon_key, token) — для заводской записи
                      (tool/provision_push.sh); config_id у каждого свой
                      (<дата>-<8 hex>), при смене токена выдаётся новый;
  devices.txt         список номеров партии (без секретов).
Файлы с кодами и токенами — ЧУВСТВИТЕЛЬНЫЕ: права 600 (каталоги 700), хранить
оффлайн.

Повторный запуск с теми же номерами отказывает: выданные id записываются в
provisioning_out/issued_ids.txt (только id, без секретов).

Примеры:
  tool/provision_devices.py --org-id <uuid> --prefix CARFOG- --start 100 --count 20 \\
      --cloud-url https://xxxx.supabase.co            # ключ — из PROVISION_ANON_KEY
  tool/provision_devices.py --org-id <uuid> --list ids.txt --cloud-url ...
"""
import argparse
import base64
import csv
import datetime
import hashlib
import json
import os
import re
import secrets
import sys
import uuid

# 31 знак: A-Z без I, L, O и цифры 2-9 (без 0 и 1). Тот же алфавит в БД.
ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
CODE_LEN = 12
TOKEN_BYTES = 32
# Допустимые кольца раскатки — те же, что в check devices.ring (миграция R3).
RINGS = ("test", "early", "all")
DEFAULT_RING = "test"
ID_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
OUT_DIR = "provisioning_out"
REGISTRY = "issued_ids.txt"


class ProvisionError(Exception):
    pass


def new_code() -> str:
    """12 знаков из ALPHABET (secrets.choice — без смещения по модулю)."""
    return "".join(secrets.choice(ALPHABET) for _ in range(CODE_LEN))


def format_code(code: str) -> str:
    return f"{code[0:4]}-{code[4:8]}-{code[8:12]}"


def normalize_code(text: str) -> str:
    """Как в БД: заглавные, только буквы и цифры (дефисы и пробелы убираются)."""
    return re.sub(r"[^A-Za-z0-9]", "", text).upper()


def new_salt() -> str:
    return uuid.uuid4().hex  # 32 hex-символа, как replace(gen_random_uuid()::text,'-','')


def code_hash(salt: str, code: str) -> str:
    """sha256(utf8(соль + нормализованный код)), hex — совпадает с БД."""
    return hashlib.sha256((salt + normalize_code(code)).encode("utf-8")).hexdigest()


def new_token() -> str:
    return base64.urlsafe_b64encode(secrets.token_bytes(TOKEN_BYTES)).decode("ascii").rstrip("=")


def new_config_id(today=None) -> str:
    """Идентификатор файла конфигурации: <дата>-<8 hex>. Новый при каждой смене токена."""
    d = (today or datetime.date.today()).isoformat()
    return f"{d}-{secrets.token_hex(4)}"


def render_config(item, cloud_url: str, anon_key: str) -> str:
    """JSON одного аппарата (формат 1) для приложения."""
    return json.dumps({
        "format": 1,
        "config_id": item["config_id"],
        "device_id": item["id"],
        "cloud_url": cloud_url,
        "anon_key": anon_key,
        "token": item["token"],
    }, ensure_ascii=False, indent=2) + "\n"


def sql_str(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def device_ids(args) -> list:
    if args.list:
        with open(args.list, encoding="utf-8") as f:
            ids = [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]
    else:
        if args.prefix is None or args.start is None or args.count is None:
            raise ProvisionError("нужны --prefix, --start и --count (или --list)")
        if args.count < 1 or args.count > 10000 or args.start < 0:
            raise ProvisionError("--count 1…10000, --start не меньше 0")
        ids = [f"{args.prefix}{n}" for n in range(args.start, args.start + args.count)]
    if not ids:
        raise ProvisionError("список аппаратов пуст")
    bad = [i for i in ids if not ID_RE.match(i)]
    if bad:
        raise ProvisionError(f"недопустимый номер аппарата: {bad[0]!r} (буквы, цифры, . _ -, до 64)")
    if len(set(ids)) != len(ids):
        raise ProvisionError("номера в списке повторяются")
    return ids


def read_registry(out_dir: str) -> set:
    path = os.path.join(out_dir, REGISTRY)
    if not os.path.exists(path):
        return set()
    with open(path, encoding="utf-8") as f:
        return {ln.strip() for ln in f if ln.strip()}


def write_private(path: str, text: str, newline=None) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline=newline) as f:
        f.write(text)
    os.chmod(path, 0o600)


def generate(ids, org_id: str, cloud_url: str, anon_key: str):
    """Возвращает список записей (id, token, code, salt, hash). Чистая функция."""
    items = []
    for i in ids:
        code = new_code()
        salt = new_salt()
        items.append({
            "id": i,
            "config_id": new_config_id(),
            "token": new_token(),
            "code": code,
            "salt": salt,
            "hash": code_hash(salt, code),
        })
    return items


def render_sql(items, org_id: str, stamp: str, ring: str = DEFAULT_RING) -> str:
    if ring not in RINGS:
        raise ProvisionError(f"--ring: допустимо {', '.join(RINGS)}")
    lines = [
        f"-- Партия аппаратов {stamp}. Токены и ХЭШИ кодов; открытых кодов здесь нет.",
        "-- Файл чувствителен (токены): хранить оффлайн, в git не добавлять.",
        "-- Выполняет владелец в Supabase SQL Editor.",
        "begin;",
    ]
    for it in items:
        lines.append(
            "insert into public.devices (id, org_id, token, name, ring) values "
            f"({sql_str(it['id'])}, {sql_str(org_id)}, {sql_str(it['token'])}, "
            f"{sql_str(it['id'])}, {sql_str(ring)});"
        )
    for it in items:
        lines.append(
            "insert into public.device_claims (device_id, code_salt, code_hash) values "
            f"({sql_str(it['id'])}, {sql_str(it['salt'])}, {sql_str(it['hash'])});"
        )
    lines.append("commit;")
    return "\n".join(lines) + "\n"


def run(argv=None, today=None) -> dict:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--org-id", required=True, help="uuid организации-изготовителя")
    p.add_argument("--prefix")
    p.add_argument("--start", type=int)
    p.add_argument("--count", type=int)
    p.add_argument("--list", help="файл со списком номеров (по одному в строке)")
    p.add_argument("--cloud-url", required=True)
    p.add_argument("--anon-key", default=os.environ.get("PROVISION_ANON_KEY", ""),
                   help="публичный ключ (publishable); лучше через PROVISION_ANON_KEY")
    p.add_argument("--ring", default=DEFAULT_RING, choices=RINGS,
                   help="кольцо раскатки, записывается в devices.ring явно "
                        "(по умолчанию test: новые аппараты не попадают под боевую раскатку)")
    p.add_argument("--batch", default=None,
                   help="имя партии (каталог provisioning_out/<партия>/); по умолчанию batch_<дата>")
    p.add_argument("--out", default=OUT_DIR)
    args = p.parse_args(argv)

    if not UUID_RE.match(args.org_id):
        raise ProvisionError("--org-id должен быть uuid")
    if not args.cloud_url.startswith("https://"):
        raise ProvisionError("--cloud-url должен начинаться с https://")
    if not args.anon_key:
        raise ProvisionError("публичный ключ не задан (PROVISION_ANON_KEY или --anon-key)")

    ids = device_ids(args)
    os.makedirs(args.out, exist_ok=True)
    issued = read_registry(args.out)
    dup = [i for i in ids if i in issued]
    if dup:
        raise ProvisionError(
            f"аппарат {dup[0]} уже выдан (есть в {REGISTRY}); токены молча не перегенерируются. "
            "Перевыпуск — по docs/provisioning.md."
        )

    day = today or datetime.date.today()
    stamp = day.isoformat()
    batch = args.batch or f"batch_{stamp}"
    if not ID_RE.match(batch):
        raise ProvisionError("--batch: буквы, цифры, . _ - (до 64)")
    batch_dir = os.path.join(args.out, batch)
    if os.path.exists(batch_dir):
        raise ProvisionError(f"{batch_dir} уже существует; не перезаписываю (выберите другое имя --batch)")
    sql_path = os.path.join(batch_dir, "batch.sql")
    csv_path = os.path.join(batch_dir, "labels.csv")
    list_path = os.path.join(batch_dir, "devices.txt")
    cfg_dir = os.path.join(batch_dir, "configs")

    items = generate(ids, args.org_id, args.cloud_url, args.anon_key)
    for it in items:
        it["config_id"] = new_config_id(day)

    os.makedirs(cfg_dir, mode=0o700)
    os.chmod(batch_dir, 0o700)
    os.chmod(cfg_dir, 0o700)

    write_private(sql_path, render_sql(items, args.org_id, stamp, args.ring))
    import io
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["device_id", "claim_code"])
    for it in items:
        w.writerow([it["id"], format_code(it["code"])])
    write_private(csv_path, buf.getvalue())
    cfg_paths = []
    for it in items:
        cp = os.path.join(cfg_dir, f"{it['id']}.json")
        write_private(cp, render_config(it, args.cloud_url, args.anon_key))
        cfg_paths.append(cp)
    write_private(list_path, "\n".join(ids) + "\n")

    with open(os.path.join(args.out, REGISTRY), "a", encoding="utf-8") as f:
        for i in ids:
            f.write(i + "\n")

    return {"count": len(items), "files": [sql_path, csv_path, list_path],
            "configs": cfg_paths, "batch_dir": batch_dir}


def main(argv=None) -> int:
    try:
        res = run(argv)
    except ProvisionError as e:
        print(f"ОШИБКА: {e}", file=sys.stderr)
        return 2
    print(f"Готово: {res['count']} аппаратов.")
    print(f"  партия: {res['batch_dir']}")
    for f in res["files"]:
        print(f"  {f}")
    print(f"  configs/<ID>.json: {len(res['configs'])} файлов")
    print("ВНИМАНИЕ: batch.sql, labels.csv и configs/*.json содержат коды и токены "
          "(права 600). Храните оффлайн, в git и в чаты не отправляйте.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
