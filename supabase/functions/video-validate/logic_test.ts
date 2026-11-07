// Запуск: node --test functions/video-validate/logic_test.ts
// Фикстуры — fixtures/*.mp4 (генератор make_fixtures.mjs): структурно
// настоящие MP4, кадры — заполнитель.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  checkProfile,
  MAX_MOOV_BYTES,
  parseMp4,
  PROFILES,
  rangeHeader,
  rejectReason,
  safeFourcc,
  totalFromContentRange,
} from "./logic.ts";
import type { RangeReader } from "./logic.ts";

const dir = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const load = (n: string) => new Uint8Array(readFileSync(join(dir, n)));

/** Читатель по буферу + счётчик прочитанных байт (проверка «не качаем всё»). */
function reader(buf: Uint8Array) {
  const stat = { bytes: 0, calls: 0 };
  const read: RangeReader = (s, e) => {
    stat.calls++;
    const part = buf.subarray(s, Math.min(e, buf.length));
    stat.bytes += part.length;
    return Promise.resolve(part);
  };
  return { read, stat };
}
const parse = (buf: Uint8Array) => {
  const r = reader(buf);
  return parseMp4(buf.length, r.read).then((res) => ({ res, stat: r.stat }));
};

test("верный H.264 1280x800: разбирается, звука нет", async () => {
  const { res } = await parse(load("valid_1280x800.mp4"));
  assert.equal(res.ok, true);
  if (res.ok) {
    assert.equal(res.info.width, 1280);
    assert.equal(res.info.height, 800);
    assert.equal(res.info.videoCodec, "avc1");
    assert.equal(res.info.hasAudio, false);
    assert.equal(res.info.durationMs, 5000);
    assert.equal(res.info.majorBrand, "isom");
  }
});

test("верный H.264 1080x1920: разбирается", async () => {
  const { res } = await parse(load("valid_1080x1920.mp4"));
  assert.ok(res.ok);
  if (res.ok) assert.deepEqual([res.info.width, res.info.height], [1080, 1920]);
});

test("moov в конце файла находится", async () => {
  const { res } = await parse(load("moov_at_end_1280x800.mp4"));
  assert.ok(res.ok);
  if (res.ok) assert.deepEqual([res.info.width, res.info.height], [1280, 800]);
});

test("со звуком: файл принимается, hasAudio = true", async () => {
  const { res } = await parse(load("audio_1280x800.mp4"));
  assert.ok(res.ok);
  if (res.ok) {
    assert.equal(res.info.hasAudio, true);
    assert.equal(res.info.videoCodec, "avc1");
  }
});

test("HEVC отклоняется как not_h264 с кодеком в подробностях", async () => {
  const { res } = await parse(load("hevc_1280x800.mp4"));
  assert.deepEqual(res, { ok: false, code: "not_h264", detail: "hvc1", });
});

test("не MP4: not_mp4", async () => {
  const { res } = await parse(load("not_mp4.bin"));
  assert.deepEqual(res, { ok: false, code: "not_mp4" });
});

test("нет moov: no_moov", async () => {
  const { res } = await parse(load("no_moov.mp4"));
  assert.equal(res.ok, false);
  if (!res.ok) assert.equal(res.code, "no_moov");
});

test("обрезанный файл (moov в конце потерян): truncated", async () => {
  const { res } = await parse(load("truncated_1280x800.mp4"));
  assert.equal(res.ok, false);
  if (!res.ok) assert.equal(res.code, "truncated");
});

test("обрезанный mdat при moov в начале: truncated", async () => {
  const { res } = await parse(load("truncated_mdat_1280x800.mp4"));
  assert.equal(res.ok, false);
  if (!res.ok) assert.equal(res.code, "truncated");
});

test("поворот матрицей на 90°: размер считается как на экране", async () => {
  const { res } = await parse(load("rotated_1080x1920.mp4"));
  assert.ok(res.ok);
  if (res.ok) assert.deepEqual([res.info.width, res.info.height], [1080, 1920]);
});

test("не читаем файл целиком: читается малая доля", async () => {
  // Большой mdat: заполняем «видео» 20 МБ, moov в конце.
  const small = load("moov_at_end_1280x800.mp4");
  // ftyp (28) + заголовок mdat (8) + полезная нагрузка; пересоберём с большим mdat.
  const ftypLen = new DataView(small.buffer, small.byteOffset).getUint32(0);
  const moovStart = ftypLen + 8 + 4096;
  const moov = small.subarray(moovStart);
  const big = new Uint8Array(ftypLen + 8 + 20_000_000 + moov.length);
  big.set(small.subarray(0, ftypLen), 0);
  const mdatSize = 8 + 20_000_000;
  big.set([(mdatSize >>> 24) & 255, (mdatSize >>> 16) & 255, (mdatSize >>> 8) & 255, mdatSize & 255,
    0x6d, 0x64, 0x61, 0x74], ftypLen);
  big.set(moov, ftypLen + mdatSize);
  assert.ok(moovStart > 0);
  const { res, stat } = await parse(big);
  assert.ok(res.ok, JSON.stringify(res));
  assert.ok(stat.bytes < 4096, `прочитано ${stat.bytes} байт`);
  assert.ok(stat.calls <= 6, `запросов ${stat.calls}`);
});

test("пустой файл и мусорный размер", async () => {
  assert.deepEqual(await parseMp4(0, () => Promise.resolve(new Uint8Array())), { ok: false, code: "empty" });
  assert.deepEqual(await parseMp4(-5, () => Promise.resolve(new Uint8Array())), { ok: false, code: "empty" });
  const tiny = new Uint8Array([0, 0, 0]);
  const r = await parseMp4(3, () => Promise.resolve(tiny));
  assert.equal(r.ok === false && r.code, "not_mp4");
});

test("ftyp не первый — not_mp4", async () => {
  const f = load("valid_1280x800.mp4");
  const bad = f.slice();
  bad.set([0x66, 0x72, 0x65, 0x65], 4); // 'free' вместо 'ftyp'
  const { res } = await parse(bad);
  assert.equal(res.ok === false && res.code, "not_mp4");
});

test("повреждённый moov: bad_structure, а не падение", async () => {
  const f = load("valid_1280x800.mp4").slice();
  // Портим размер вложенного бокса mvhd внутри moov.
  const moovAt = new DataView(f.buffer, f.byteOffset).getUint32(0);
  f.set([0xff, 0xff, 0xff, 0x00], moovAt + 8);
  const { res } = await parse(f);
  assert.equal(res.ok === false && res.code, "bad_structure");
});

test("огромный объявленный moov: moov_too_large (без чтения)", async () => {
  const f = new Uint8Array(40);
  // ftyp 16 байт
  f.set([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0], 0);
  // moov с 64-битным размером больше предела, но влезающий в «файл» размера size
  const declared = MAX_MOOV_BYTES + 1000;
  f.set([0, 0, 0, 1, 0x6d, 0x6f, 0x6f, 0x76, 0, 0, 0, 0,
    (declared >>> 24) & 255, (declared >>> 16) & 255, (declared >>> 8) & 255, declared & 255], 16);
  const r = await parseMp4(16 + declared, (s, e) => Promise.resolve(f.subarray(s, Math.min(e, f.length))));
  assert.equal(r.ok === false && r.code, "moov_too_large");
});

test("ограничение числа боксов: бесконечная цепочка не вешает разбор", async () => {
  const n = 300;
  const f = new Uint8Array(16 + n * 8);
  f.set([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0], 0);
  for (let i = 0; i < n; i++) f.set([0, 0, 0, 8, 0x66, 0x72, 0x65, 0x65], 16 + i * 8);
  const r = reader(f);
  const res = await parseMp4(f.length, r.read);
  assert.equal(res.ok === false && res.code, "no_moov");
  assert.ok(r.stat.calls <= 70);
});

test("checkProfile: ixp101m1 — 1280x800", () => {
  assert.deepEqual(checkProfile({ width: 1280, height: 800 }, "ixp101m1"), { ok: true });
  const bad = checkProfile({ width: 1920, height: 1080 }, "ixp101m1");
  assert.deepEqual(bad, { ok: false, code: "wrong_resolution", detail: "1920x1080 need 1280x800" });
});

test("checkProfile: sy156-a510 — 1080x1920 (портрет)", () => {
  assert.deepEqual(checkProfile({ width: 1080, height: 1920 }, "sy156-a510"), { ok: true });
  assert.equal(checkProfile({ width: 1280, height: 800 }, "sy156-a510").ok, false);
  // альбомное видео на портретный планшет не годится, и наоборот
  assert.equal(checkProfile({ width: 1920, height: 1080 }, "sy156-a510").ok, false);
  assert.equal(checkProfile({ width: 800, height: 1280 }, "ixp101m1").ok, false);
});

test("checkProfile: неизвестный профиль — unknown_profile, подробности очищены", () => {
  const r = checkProfile({ width: 1, height: 1 }, "new<script>");
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.code, "unknown_profile");
    assert.ok(!/[<>]/.test(r.detail));
  }
  assert.equal(checkProfile({ width: 1, height: 1 }, "__proto__").ok, false);
  assert.equal(checkProfile({ width: 1, height: 1 }, "constructor").ok, false);
  assert.deepEqual(Object.keys(PROFILES).sort(), ["ixp101m1", "sy156-a510"]);
});

test("rejectReason: код и безопасные подробности, ≤ 200 знаков", () => {
  assert.equal(rejectReason("not_mp4"), "not_mp4");
  assert.equal(rejectReason("not_h264", "hvc1"), "not_h264:hvc1");
  assert.equal(rejectReason("wrong_resolution", "1920x1080 need 1280x800"),
    "wrong_resolution:1920x1080 need 1280x800");
  assert.ok(!rejectReason("not_h264", "a'; drop table x;--").includes("'"));
  assert.ok(rejectReason("not_h264", "x".repeat(500)).length <= 80);
});

test("safeFourcc", () => {
  assert.equal(safeFourcc("hvc1"), "hvc1");
  assert.equal(safeFourcc("a/b\u0000c"), "a_b_");
});

test("totalFromContentRange и rangeHeader", () => {
  assert.equal(totalFromContentRange("bytes 0-0/12345"), 12345);
  assert.equal(totalFromContentRange("bytes 0-15/4754"), 4754);
  assert.equal(totalFromContentRange("bytes */100"), null);
  assert.equal(totalFromContentRange("garbage"), null);
  assert.equal(totalFromContentRange(null), null);
  assert.equal(rangeHeader(0, 16), "bytes=0-15");
  assert.equal(rangeHeader(100, 101), "bytes=100-100");
});

import { judge } from "./logic.ts";

test("judge: размер не совпал — size_mismatch раньше всего", async () => {
  const f = load("valid_1280x800.mp4");
  const { res } = await parse(f);
  const v = judge(f.length + 1, f.length, res, "ixp101m1");
  assert.equal(v.kind, "reject");
  if (v.kind === "reject") assert.equal(v.code, "size_mismatch");
});

test("judge: верный файл под свой профиль — ok; под чужой — wrong_resolution", async () => {
  const f = load("valid_1280x800.mp4");
  const { res } = await parse(f);
  assert.equal(judge(f.length, f.length, res, "ixp101m1").kind, "ok");
  const bad = judge(f.length, f.length, res, "sy156-a510");
  assert.equal(bad.kind === "reject" && bad.code, "wrong_resolution");
});

test("judge: ошибка разбора переходит в отказ с тем же кодом", async () => {
  const f = load("hevc_1280x800.mp4");
  const { res } = await parse(f);
  const v = judge(f.length, f.length, res, "ixp101m1");
  assert.deepEqual(v, { kind: "reject", code: "not_h264", detail: "hvc1" });
});
