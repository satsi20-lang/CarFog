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
            sql_path, csv_path, list_path = res["files"]
            self.assertEqual(len(res["configs"]), 20)
            for p in res["files"] + res["configs"]:
                self.assertEqual(stat.S_IMODE(os.stat(p).st_mode), 0o600, p)
            self.assertEqual(stat.S_IMODE(os.stat(res["batch_dir"]).st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(res["configs"][0])).st_mode), 0o700)
            self.assertEqual(os.path.basename(res["batch_dir"]), "batch_2026-10-07")
            with open(sql_path, encoding="utf-8") as f1:
                sql = f1.read()
            with open(csv_path, encoding="utf-8") as f2:
                rows = list(csv.DictReader(f2))
            cfg = {}
            for cp in res["configs"]:
                with open(cp, encoding="utf-8") as f3:
                    j = json.load(f3)
                self.assertEqual(os.path.basename(cp), j["device_id"] + ".json")
                cfg[j["device_id"]] = j
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
            # формат 1: поля, config_id, уникальность токенов и config_id
            self.assertEqual(len({c["token"] for c in cfg.values()}), 20)
            self.assertEqual(len({c["config_id"] for c in cfg.values()}), 20)
            for c in cfg.values():
                self.assertEqual(set(c), {"format", "config_id", "device_id", "cloud_url", "anon_key", "token", "spec"})
                self.assertEqual(c["format"], 1)
                self.assertRegex(c["config_id"], r"^\d{4}-\d{2}-\d{2}-[0-9a-f]{8}$")
                self.assertTrue(c["config_id"].startswith("2026-10-07-"))
                self.assertEqual(c["cloud_url"], URL)
                self.assertEqual(c["anon_key"], KEY)
                self.assertIn(c["token"], sql)             # токен в SQL = токен в файле
            by_id = {r["device_id"]: r["claim_code"] for r in rows}
            for m in re.finditer(r"insert into public\.device_claims .* values \('([^']+)', '([0-9a-f]{32})', '([0-9a-f]{64})'\);", sql):
                dev, salt, h = m.groups()
                self.assertEqual(h, pd.code_hash(salt, by_id[dev]))
            # общего файла с токенами больше нет; список номеров без секретов
            self.assertFalse([f for f in os.listdir(res["batch_dir"]) if "device_config" in f])
            with open(list_path, encoding="utf-8") as f4:
                listing = f4.read()
            self.assertEqual(listing.split(), [f"CARFOG-{n}" for n in range(100, 120)])
            for c in cfg.values():
                self.assertNotIn(c["token"], listing)
                self.assertNotIn(KEY, listing)

    def test_second_batch_same_day_needs_own_name(self):
        with tempfile.TemporaryDirectory() as tmp:
            run(tmp, "--prefix", "A-", "--start", "1", "--count", "1")
            with self.assertRaises(pd.ProvisionError):
                run(tmp, "--prefix", "B-", "--start", "1", "--count", "1")
            res = run(tmp, "--prefix", "B-", "--start", "1", "--count", "1", "--batch", "second")
            self.assertEqual(os.path.basename(res["batch_dir"]), "second")

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
                self.assertIn("(id, org_id, token, name, ring, spec_pumps, spec_langs, "
                              "spec_default_lang, hardware_profile)", ln)
                self.assertIn(", 'test', ", ln)  # кольцо по умолчанию test
        with tempfile.TemporaryDirectory() as tmp:
            res = run(tmp, "--prefix", "B-", "--start", "1", "--count", "2", "--ring", "early")
            with open(res["files"][0], encoding="utf-8") as f:
                sql = f.read()
            self.assertEqual(sql.count(", 'early', "), 2)
            self.assertNotIn(", 'all', ", sql)

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


FAKE_ADB = r"""#!__PYTHON__
import hashlib, os, shutil, sys
dev = os.environ["FAKE_DEV"]
log = os.environ["FAKE_LOG"]
args = sys.argv[1:]
with open(log, "a") as f:
    f.write(" ".join(args) + "\n")
if args[:2] == ["-s", os.environ.get("FAKE_SERIAL", "SER1")]:
    args = args[2:]
def real(p):
    return os.path.join(dev, p.lstrip("/"))
cmd = args[0]
if cmd == "devices":
    print("List of devices attached")
    for s in os.environ.get("FAKE_SERIALS", "SER1").split(","):
        if s: print(s + "\tdevice")
    sys.exit(0)
if cmd == "push":
    dst = real(args[2]); os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.environ.get("FAKE_PUSH_FAIL"): sys.exit(1)
    shutil.copy(args[1], dst)
    if os.environ.get("FAKE_CORRUPT"):
        open(dst, "ab").write(b"x")
    print(args[1] + ": 1 file pushed")  # имя файла, не содержимое
    sys.exit(0)
if cmd == "shell":
    c = args[1]
    if c.startswith("mkdir -p "):
        os.makedirs(real(c.split()[-1]), exist_ok=True); sys.exit(0)
    if c.startswith("pm list packages"):
        if os.environ.get("FAKE_NO_APP"): sys.exit(0)
        print("package:ee.carfog.dryfog"); sys.exit(0)
    if c.startswith("appops set"):
        open(os.path.join(dev, "appops"), "w").write("allow"); sys.exit(0)
    if c.startswith("appops get"):
        print("MANAGE_EXTERNAL_STORAGE: allow" if os.path.exists(os.path.join(dev, "appops")) else "MANAGE_EXTERNAL_STORAGE: default"); sys.exit(0)
    if c.startswith("am force-stop") or c.startswith("monkey"):
        sys.exit(0)
    if c.startswith("stat -c %s "):
        p = real(c.split()[-1])
        if os.path.exists(p): print(os.path.getsize(p))
        sys.exit(0)
    if c.startswith("sha256sum "):
        p = real(c.split()[-1])
        if os.path.exists(p): print(hashlib.sha256(open(p, "rb").read()).hexdigest() + "  " + c.split()[-1])
        sys.exit(0)
    if c.startswith("[ -e "):
        p = real(c.split()[2]); print("yes" if os.path.exists(p) else "no"); sys.exit(0)
    if c.startswith("rm -f "):
        if os.environ.get("FAKE_RM_FAIL"): sys.exit(0)
        p = real(c.split()[-1])
        if os.path.exists(p): os.remove(p)
        sys.exit(0)
    if c.startswith("rmdir "):
        try: os.rmdir(real(c.split()[-1]))
        except OSError: pass
        sys.exit(0)
sys.exit(0)
"""


class SpecTest(unittest.TestCase):
    """Спецификация аппарата (число насосов, языки): контракт, файл, SQL, подпись."""

    def test_defaults(self):
        sp = pd.parse_spec()
        self.assertEqual(sp, {"pumps": 4, "langs": ["et", "en", "ru"], "default_lang": "et",
                              "hardware_profile": "sy156-a510"})

    def test_parse_valid(self):
        sp = pd.parse_spec(8, "ru,en,de", "en")
        self.assertEqual((sp["pumps"], sp["langs"], sp["default_lang"]), (8, ["ru", "en", "de"], "en"))
        # порядок сохраняется, default по умолчанию — первый
        self.assertEqual(pd.parse_spec(6, "de,fr")["default_lang"], "de")
        self.assertEqual(pd.parse_spec(4, "no")["langs"], ["no"])

    def test_pumps_bounds(self):
        for ok in (4, 8):
            pd.parse_spec(ok)
        for bad in (3, 9, 10, 11, 0, -1, 4.5, "5", True, None):
            with self.assertRaises(pd.ProvisionError, msg=repr(bad)):
                pd.parse_spec(bad)

    def test_langs_invalid(self):
        for bad in ("xx", "et,xx", "ET", "et,ET", "et,et", "et,,en", " ", "et en"):
            with self.assertRaises(pd.ProvisionError, msg=repr(bad)):
                pd.parse_spec(4, bad)
        # >24 кодов
        many = [c for c in pd.LANG_CATALOG][:25]
        with self.assertRaises(pd.ProvisionError):
            pd.parse_spec(4, ",".join(many))
        self.assertEqual(len(pd.parse_spec(4, ",".join(many[:24]))["langs"]), 24)

    def test_default_lang_must_be_in_langs(self):
        with self.assertRaises(pd.ProvisionError):
            pd.parse_spec(4, "et,en", "ru")
        with self.assertRaises(pd.ProvisionError):
            pd.parse_spec(4, "et,en", "EN")

    def test_catalog_has_27_codes(self):
        self.assertEqual(len(pd.LANG_CATALOG), 27)
        self.assertEqual(len(set(pd.LANG_CATALOG)), 27)
        self.assertTrue(all(c == c.lower() and 2 <= len(c) <= 3 for c in pd.LANG_CATALOG))

    def test_label(self):
        self.assertEqual(pd.spec_label(pd.parse_spec()), "4 насоса · ET/EN/RU")
        self.assertEqual(pd.spec_label(pd.parse_spec(8, "ru,de")), "8 насосов · RU/DE")

    def test_run_writes_spec_to_sql_config_and_labels(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = run(tmp, "--prefix", "S-", "--start", "1", "--count", "2",
                      "--pumps", "8", "--langs", "ru,en,de", "--default-lang", "en")
            with open(res["files"][0], encoding="utf-8") as f:
                sql = f.read()
            devs = [ln for ln in sql.splitlines() if ln.startswith("insert into public.devices")]
            self.assertEqual(len(devs), 2)
            for ln in devs:
                self.assertIn(", 8, array['ru', 'en', 'de']::text[], 'en', 'sy156-a510');", ln)
            with open(res["files"][1], encoding="utf-8") as f:
                rows = list(csv.DictReader(f))
            self.assertEqual(list(rows[0].keys()), ["device_id", "claim_code", "подпись"])
            self.assertEqual({r["подпись"] for r in rows}, {"8 насосов · RU/EN/DE"})
            for cp in res["configs"]:
                with open(cp, encoding="utf-8") as f:
                    j = json.load(f)
                self.assertEqual(j["format"], 1)
                self.assertEqual(j["spec"], {"pumps": 8, "langs": ["ru", "en", "de"],
                                             "default_lang": "en", "hardware_profile": "sy156-a510"})

    def test_run_defaults_and_bad_values_refused_without_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            res = run(tmp, "--prefix", "D-", "--start", "1", "--count", "1")
            with open(res["configs"][0], encoding="utf-8") as f:
                j = json.load(f)
            self.assertEqual(j["spec"]["pumps"], 4)
            self.assertEqual(j["spec"]["langs"], ["et", "en", "ru"])
        for extra in (["--pumps", "3"], ["--pumps", "9"], ["--pumps", "11"], ["--langs", "xx"],
                      ["--langs", "et,et"], ["--langs", "et,en", "--default-lang", "ru"]):
            with tempfile.TemporaryDirectory() as tmp:
                with self.assertRaises(pd.ProvisionError, msg=str(extra)):
                    run(tmp, "--prefix", "B-", "--start", "1", "--count", "1", *extra)
                self.assertFalse(os.path.exists(os.path.join(tmp, pd.REGISTRY)))  # номера не «сожжены»
                self.assertFalse(os.path.exists(os.path.join(tmp, "batch_2026-10-07")))

    def test_old_config_without_spec_still_renders(self):
        item = {"config_id": "2026-10-07-aabbccdd", "id": "X-1", "token": "t"}
        j = json.loads(pd.render_config(item, URL, KEY))
        self.assertNotIn("spec", j)
        self.assertEqual(j["format"], 1)

    def test_sql_has_no_secrets_besides_token_and_matches_db_catalog(self):
        # каталог кодов генератора совпадает с каталогом в миграции R5
        here = os.path.dirname(os.path.abspath(__file__))
        with open(os.path.join(here, "..", "supabase", "migrations", "20261008000000_r5_spec.sql"),
                  encoding="utf-8") as f:
            mig = f.read()
        m = re.search(r"array\[((?:'[a-z]+',?\s*)+)\]::text\[\]", mig)
        self.assertIsNotNone(m)
        db_codes = tuple(re.findall(r"'([a-z]+)'", m.group(1)))
        self.assertEqual(db_codes, pd.LANG_CATALOG)


class ScriptsTest(unittest.TestCase):
    """provision_push.sh / provision_finish.sh с поддельным adb (без устройства)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.dev = os.path.join(self.tmp, "dev")
        os.makedirs(self.dev)
        self.log = os.path.join(self.tmp, "adb.log")
        adb = os.path.join(self.bin, "adb")
        with open(adb, "w") as f:
            f.write(FAKE_ADB.replace("__PYTHON__", sys.executable))
        os.chmod(adb, 0o755)
        self.out = os.path.join(self.tmp, "out")
        self.res = pd.run(["--org-id", ORG, "--cloud-url", URL, "--anon-key", KEY, "--out", self.out,
                           "--prefix", "CARFOG-", "--start", "7", "--count", "2"], today=DAY)
        with open(self.res["configs"][0], encoding="utf-8") as f:
            self.token = json.load(f)["token"]
        self.root = os.path.dirname(os.path.abspath(__file__))

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, name, *args, **env):
        import subprocess
        e = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE_DEV=self.dev,
                 FAKE_LOG=self.log, PROVISION_DIR=self.out)
        e.update({k: str(v) for k, v in env.items()})
        return subprocess.run([os.path.join(self.root, name), *args], capture_output=True, text=True, env=e)

    def restricted_path(self, with_sha256sum=False, with_shasum=False):
        """PATH из одних нужных утилит: проверка вариантов хэш-утилиты."""
        import shutil
        d = os.path.join(self.tmp, "rbin")
        os.makedirs(d, exist_ok=True)
        for name in ("awk", "grep", "tr", "wc", "adb"):
            src = os.path.join(self.bin, "adb") if name == "adb" else shutil.which(name)
            dst = os.path.join(d, name)
            if not os.path.exists(dst):
                os.symlink(src, dst)
        if with_sha256sum:
            dst = os.path.join(d, "sha256sum")
            if not os.path.exists(dst):
                with open(dst, "w") as f:
                    f.write("#!" + sys.executable + "\nimport hashlib, sys\n"
                            "print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() + '  ' + sys.argv[1])\n")
                os.chmod(dst, 0o755)
        if with_shasum:
            os.symlink(shutil.which("shasum"), os.path.join(d, "shasum"))
        return d

    def run_with_path(self, name, path, *args):
        import subprocess, shutil
        e = dict(os.environ, PATH=path, FAKE_DEV=self.dev, FAKE_LOG=self.log, PROVISION_DIR=self.out)
        return subprocess.run([shutil.which("bash"), os.path.join(self.root, name), *args],
                              capture_output=True, text=True, env=e)

    def test_push_falls_back_to_sha256sum_when_no_shasum(self):
        r = self.run_with_path("provision_push.sh", self.restricted_path(with_sha256sum=True), "CARFOG-7")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("sha256 совпал", r.stdout)

    def test_push_uses_shasum_when_present(self):
        r = self.run_with_path("provision_push.sh", self.restricted_path(with_shasum=True), "CARFOG-7")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_push_clear_error_when_no_hash_tool(self):
        r = self.run_with_path("provision_push.sh", self.restricted_path(), "CARFOG-7")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("нет ни shasum, ни sha256sum", r.stderr)

    def test_scripts_report_missing_adb(self):
        import subprocess, shutil
        d = os.path.join(self.tmp, "noadb")
        os.makedirs(d)
        for name in ("awk", "grep", "tr", "wc"):
            os.symlink(shutil.which(name), os.path.join(d, name))
        for script in ("provision_push.sh", "provision_finish.sh"):
            r = self.run_with_path(script, d, "CARFOG-7")
            self.assertNotEqual(r.returncode, 0, script)
            self.assertIn("не найдена утилита adb", r.stderr, script)

    def test_push_ok_verifies_size_and_sha_and_never_prints_token(self):
        r = self.run_script("provision_push.sh", "CARFOG-7")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("ок: CARFOG-7", r.stdout)
        self.assertIn("sha256 совпал", r.stdout)
        remote = os.path.join(self.dev, "sdcard/CarFog/device_config.json")
        with open(remote, "rb") as a, open(self.res["configs"][0], "rb") as b:
            self.assertEqual(a.read(), b.read())
        with open(self.log) as f:
            calls = f.read()
        self.assertIn("appops set ee.carfog.dryfog MANAGE_EXTERNAL_STORAGE allow", calls)
        self.assertIn("am force-stop ee.carfog.dryfog", calls)
        self.assertNotIn(self.token, r.stdout + r.stderr + calls)   # токен нигде не печатается

    def test_push_refuses_unknown_id_and_bad_id(self):
        r = self.run_script("provision_push.sh", "CARFOG-999")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("нет файла", r.stderr)
        r = self.run_script("provision_push.sh", "A B; rm")
        self.assertNotEqual(r.returncode, 0)

    def test_push_one_device_at_a_time(self):
        r = self.run_script("provision_push.sh", "CARFOG-7", FAKE_SERIALS="SER1,SER2")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("укажите серийник", r.stderr)
        r = self.run_script("provision_push.sh", "CARFOG-7", "SER2", FAKE_SERIALS="SER1,SER2", FAKE_SERIAL="SER2")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        r = self.run_script("provision_push.sh", "CARFOG-7", "NOPE", FAKE_SERIALS="SER1")
        self.assertNotEqual(r.returncode, 0)

    def test_push_detects_corrupted_copy(self):
        r = self.run_script("provision_push.sh", "CARFOG-7", FAKE_CORRUPT="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("не равен", r.stderr + r.stdout)

    def test_push_without_app_warns_but_writes_file(self):
        r = self.run_script("provision_push.sh", "CARFOG-7", FAKE_NO_APP="1")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("не установлено", r.stdout)

    def test_finish_removes_file_and_reports(self):
        self.run_script("provision_push.sh", "CARFOG-7")
        r = self.run_script("provision_finish.sh", "CARFOG-7")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("файл конфигурации удалён", r.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.dev, "sdcard/CarFog/device_config.json")))
        r = self.run_script("provision_finish.sh", "CARFOG-7")
        self.assertEqual(r.returncode, 0)
        self.assertIn("файла не было", r.stdout)

    def test_finish_fails_loudly_if_not_deleted(self):
        self.run_script("provision_push.sh", "CARFOG-7")
        r = self.run_script("provision_finish.sh", "CARFOG-7", FAKE_RM_FAIL="1")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("не удалён", r.stderr)


if __name__ == "__main__":
    unittest.main()
