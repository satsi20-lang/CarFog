import csv
import datetime
import json
import os
import re
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import provision_devices as pd  # noqa: E402

ORG = "123e4567-e89b-12d3-a456-426614174000"
URL = "https://example.supabase.co"
KEY = "sb_publishable_TESTKEY"
DAY = datetime.date(2026, 10, 7)


def run(tmp, *extra, today=DAY):
    return pd.run(
        ["--org-id", ORG, "--cloud-url", URL, "--anon-key", KEY, "--out", tmp, *extra],
        today=today,
    )


class ProvisionTest(unittest.TestCase):
    def test_code_format_and_alphabet(self):
        forbidden = set("0O1IL")
        for _ in range(500):
            c = pd.new_code()
            self.assertEqual(len(c), 12)
            self.assertTrue(set(c) <= set(pd.ALPHABET))
            self.assertFalse(set(c) & forbidden)
        self.assertEqual(len(pd.ALPHABET), 31)
        self.assertRegex(pd.format_code(pd.new_code()), r"^[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}-[A-HJ-KM-NP-Z2-9]{4}$")

    def test_normalize_and_hash_vector(self):
        # Тот же вектор проверяется в supabase/tests/rls_tenancy.sql
        # (public._claim_hash): хэш считается ОДИНАКОВО в генераторе и в БД.
        salt = "00112233445566778899aabbccddeeff"
        self.assertEqual(pd.normalize_code("abcd-efgh-jkmn"), "ABCDEFGHJKMN")
        h = pd.code_hash(salt, "abcd-efgh-jkmn")
        self.assertEqual(h, pd.code_hash(salt, "ABCDEFGHJKMN"))
        self.assertEqual(h, "ccbfe6423b28c20b5c9adb7c81ca0b9eef6e6c54a84a085f36cfce6dcf45efda")
        self.assertEqual(len(h), 64)
        self.assertNotEqual(h, pd.code_hash("ffeeddccbbaa99887766554433221100", "ABCDEFGHJKMN"))
        # независимый расчёт
        import hashlib
        self.assertEqual(h, hashlib.sha256((salt + "ABCDEFGHJKMN").encode()).hexdigest())

    def test_tokens_unique_and_long(self):
        toks = {pd.new_token() for _ in range(2000)}
        self.assertEqual(len(toks), 2000)
        for t in list(toks)[:50]:
            self.assertGreaterEqual(len(t), 43)  # 32 байта в base64url
            self.assertRegex(t, r"^[A-Za-z0-9_-]+$")

    def test_batch_files_and_no_plaintext_codes_in_sql(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = run(tmp, "--prefix", "CARFOG-", "--start", "100", "--count", "20")
            self.assertEqual(res["count"], 20)
            sql_path, csv_path, cfg_path = res["files"]
            for p in res["files"]:
                self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600, p)
            with open(sql_path, encoding="utf-8") as f1:
                sql = f1.read()
            with open(csv_path, encoding="utf-8") as f2:
                rows = list(csv.DictReader(f2))
            with open(cfg_path, encoding="utf-8") as f3:
                cfg = json.load(f3)
            self.assertEqual(len(rows), 20)
            self.assertEqual(len(cfg), 20)
            self.assertEqual(sql.count("insert into public.devices"), 20)
            self.assertEqual(sql.count("insert into public.device_claims"), 20)
            self.assertIn("begin;", sql)
            self.assertIn("commit;", sql)
            codes = set()
            for r in rows:
                self.assertRegex(r["claim_code"], r"^[A-HJ-KM-NP-Z2-9]{4}(-[A-HJ-KM-NP-Z2-9]{4}){2}$")
                codes.add(r["claim_code"])
                plain = pd.normalize_code(r["claim_code"])
                self.assertNotIn(plain, sql)               # открытого кода в SQL нет
                self.assertNotIn(r["claim_code"], sql)
            self.assertEqual(len(codes), 20)               # коды различаются
            # токены в config совпадают с SQL и уникальны; хэши совпадают с csv
            self.assertEqual(len({c["token"] for c in cfg}), 20)
            for c in cfg:
                self.assertIn(c["token"], sql)
                self.assertEqual(c["cloud_url"], URL)
            by_id = {r["device_id"]: r["claim_code"] for r in rows}
            for m in re.finditer(r"insert into public\.device_claims .* values \('([^']+)', '([0-9a-f]{32})', '([0-9a-f]{64})'\);", sql):
                dev, salt, h = m.groups()
                self.assertEqual(h, pd.code_hash(salt, by_id[dev]))

    def test_repeat_refused_and_registry_has_no_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            run(tmp, "--prefix", "CARFOG-", "--start", "100", "--count", "5")
            with self.assertRaises(pd.ProvisionError) as cm:
                run(tmp, "--prefix", "CARFOG-", "--start", "103", "--count", "5",
                    today=DAY + datetime.timedelta(days=1))
            self.assertIn("CARFOG-103", str(cm.exception))
            with open(os.path.join(tmp, pd.REGISTRY), encoding="utf-8") as fr:
                reg = fr.read().split()
            self.assertEqual(reg, [f"CARFOG-{n}" for n in range(100, 105)])
            # непересекающийся диапазон проходит
            run(tmp, "--prefix", "CARFOG-", "--start", "105", "--count", "2",
                today=DAY + datetime.timedelta(days=1))

    def test_same_day_files_not_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            run(tmp, "--prefix", "A-", "--start", "1", "--count", "2")
            with self.assertRaises(pd.ProvisionError):
                run(tmp, "--prefix", "B-", "--start", "1", "--count", "2")

    def test_input_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(pd.ProvisionError):
                pd.run(["--org-id", "not-uuid", "--cloud-url", URL, "--anon-key", KEY, "--out", tmp,
                        "--prefix", "A-", "--start", "1", "--count", "1"])
            with self.assertRaises(pd.ProvisionError):
                pd.run(["--org-id", ORG, "--cloud-url", "http://x", "--anon-key", KEY, "--out", tmp,
                        "--prefix", "A-", "--start", "1", "--count", "1"])
            with self.assertRaises(pd.ProvisionError):
                pd.run(["--org-id", ORG, "--cloud-url", URL, "--anon-key", "", "--out", tmp,
                        "--prefix", "A-", "--start", "1", "--count", "1"])
            with self.assertRaises(pd.ProvisionError):
                run(tmp, "--prefix", "A'; drop table x;--", "--start", "1", "--count", "1")

    def test_ring_default_test_and_explicit(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = run(tmp, "--prefix", "A-", "--start", "1", "--count", "3")
            with open(res["files"][0], encoding="utf-8") as f:
                sql = f.read()
            devs = [ln for ln in sql.splitlines() if ln.startswith("insert into public.devices")]
            self.assertEqual(len(devs), 3)
            for ln in devs:
                self.assertIn("(id, org_id, token, name, ring)", ln)
                self.assertTrue(ln.rstrip().endswith("'test');"), ln)  # по умолчанию test
        with tempfile.TemporaryDirectory() as tmp:
            res = run(tmp, "--prefix", "B-", "--start", "1", "--count", "2", "--ring", "early")
            with open(res["files"][0], encoding="utf-8") as f:
                sql = f.read()
            self.assertEqual(sql.count("'early');"), 2)
            self.assertNotIn("'all');", sql)

    def test_ring_invalid_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            for bad in ("prod", "ALL", "", "test'; drop table x;--"):
                with self.assertRaises(SystemExit):   # argparse: недопустимое значение
                    run(tmp, "--prefix", "A-", "--start", "1", "--count", "1", "--ring", bad)
            self.assertFalse(os.path.exists(os.path.join(tmp, pd.REGISTRY)))  # ничего не выдано
        # и прямой вызов генерации SQL не принимает неверное кольцо
        with self.assertRaises(pd.ProvisionError):
            pd.render_sql([], ORG, "x", "prod")

    def test_list_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            lst = os.path.join(tmp, "ids.txt")
            with open(lst, "w", encoding="utf-8") as fl:
                fl.write("# партия\nCARFOG-901\n\nCARFOG-905\n")
            out = os.path.join(tmp, "out")
            res = run(out, "--list", lst)
            self.assertEqual(res["count"], 2)


if __name__ == "__main__":
    unittest.main()
