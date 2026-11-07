// Генератор фикстур MP4 для logic_test.ts. Запуск: node make_fixtures.mjs
// Результат лежит в fixtures/ и закоммичен; генератор нужен, чтобы
// пересоздать файлы или добавить новые.
//
// Что это за файлы: структурно настоящие MP4 (ftyp, moov с mvhd/trak/tkhd/
// mdia/hdlr/minf/stbl/stsd, mdat, таблицы выборок), собранные побайтно по
// ISO 14496-12. Кадры в mdat — заполнитель (4 КБ), поэтому файлы НЕ
// декодируются плеером: тесты проверяют разбор структуры, а не воспроизведение.
// Настоящий кодек на этой машине собрать нечем (нет ffmpeg).
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, "fixtures");
mkdirSync(out, { recursive: true });

const be32 = (n) => Buffer.from([(n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255]);
const be16 = (n) => Buffer.from([(n >>> 8) & 255, n & 255]);
const z = (n) => Buffer.alloc(n);
const box = (type, ...parts) => {
  const body = Buffer.concat(parts);
  return Buffer.concat([be32(8 + body.length), Buffer.from(type, "latin1"), body]);
};
const full = (type, ver, flags, ...parts) =>
  box(type, Buffer.from([ver, (flags >> 16) & 255, (flags >> 8) & 255, flags & 255]), ...parts);

const MATRIX_ID = Buffer.concat([be32(0x10000), z(4), z(4), z(4), be32(0x10000), z(4), z(4), z(4), be32(0x40000000)]);
// Поворот на 90°: a=0 b=1 c=-1 d=0.
const MATRIX_ROT90 = Buffer.concat([z(4), be32(0x10000), z(4), be32(0xffff0000), z(4), z(4), z(4), z(4), be32(0x40000000)]);

const mvhd = (durMs) => full("mvhd", 0, 0, be32(0), be32(0), be32(1000), be32(durMs),
  be32(0x10000), be16(0x100), z(10), MATRIX_ID, z(24), be32(3));
const tkhd = (id, w, h, durMs, matrix = MATRIX_ID, audio = false) => full("tkhd", 0, 3,
  be32(0), be32(0), be32(id), z(4), be32(durMs), z(8), be16(0), be16(0),
  be16(audio ? 0x100 : 0), z(2), matrix, be32(w << 16), be32(h << 16));
const mdhd = (durMs) => full("mdhd", 0, 0, be32(0), be32(0), be32(1000), be32(durMs), be16(0x55c4), be16(0));
const hdlr = (type, name) => full("hdlr", 0, 0, z(4), Buffer.from(type, "latin1"), z(12),
  Buffer.from(name + "\0", "latin1"));

const sps = Buffer.from("6742c01fd9005005ba1000000300100000030300f18319600", "hex");
const pps = Buffer.from("68cb8cb2", "hex");
const avcC = box("avcC", Buffer.from([1, 0x42, 0xc0, 0x1f, 0xff, 0xe1]), be16(sps.length), sps,
  Buffer.from([1]), be16(pps.length), pps);
const hvcC = box("hvcC", Buffer.from([1, 1, 0x60, 0, 0, 0, 0x90, 0, 0, 0, 0, 0, 0x78, 0xf0, 0, 0xfc, 0xfd, 0xf8, 0xf8, 0, 0, 3, 0]));

const visualEntry = (fmt, w, h, cfg) => box(fmt, z(6), be16(1), be16(0), be16(0), z(12),
  be16(w), be16(h), be32(0x480000), be32(0x480000), z(4), be16(1), z(32), be16(0x18), be16(0xffff), cfg);
const audioEntry = () => box("mp4a", z(6), be16(1), z(8), be16(2), be16(16), be16(0), be16(0), be32(48000 << 16));

const stsd = (entry) => full("stsd", 0, 0, be32(1), entry);
const tables = (mdatOffset, sampleSize) => Buffer.concat([
  full("stts", 0, 0, be32(1), be32(1), be32(1000)),
  full("stsc", 0, 0, be32(1), be32(1), be32(1), be32(1)),
  full("stsz", 0, 0, be32(0), be32(1), be32(sampleSize)),
  full("stco", 0, 0, be32(1), be32(mdatOffset)),
]);
const trak = (id, w, h, durMs, handler, entry, mdatOffset, sampleSize, matrix) => box("trak",
  tkhd(id, handler === "soun" ? 0 : w, handler === "soun" ? 0 : h, durMs, matrix, handler === "soun"),
  box("mdia", mdhd(durMs), hdlr(handler, handler === "vide" ? "VideoHandler" : "SoundHandler"),
    box("minf",
      handler === "vide" ? full("vmhd", 0, 1, z(8)) : full("smhd", 0, 0, z(4)),
      box("dinf", full("dref", 0, 0, be32(1), full("url ", 0, 1))),
      box("stbl", stsd(entry), tables(mdatOffset, sampleSize)))));

const ftyp = box("ftyp", Buffer.from("isom", "latin1"), be32(512),
  Buffer.from("isomiso2avc1mp41", "latin1"));
const payload = (n) => Buffer.from(Array.from({ length: n }, (_, i) => (i * 31 + 7) & 255));

/**
 * opts: w, h (размер кадра), codec 'avc1'|'hvc1', audio, moovAtEnd, durMs,
 * matrix, mdatBytes.
 */
function build(opts) {
  const o = { codec: "avc1", audio: false, moovAtEnd: false, durMs: 5000, mdatBytes: 4096, ...opts };
  const mdat = box("mdat", payload(o.mdatBytes));
  const entry = o.codec === "avc1" ? visualEntry("avc1", o.w, o.h, avcC) : visualEntry("hvc1", o.w, o.h, hvcC);
  const mkMoov = (mdatPayloadOffset) => box("moov", mvhd(o.durMs),
    trak(1, o.w, o.h, o.durMs, "vide", entry, mdatPayloadOffset, o.mdatBytes, o.matrix),
    ...(o.audio ? [trak(2, 0, 0, o.durMs, "soun", audioEntry(), mdatPayloadOffset, 16)] : []));
  if (o.moovAtEnd) {
    const mdatPayloadOffset = ftyp.length + 8;
    return Buffer.concat([ftyp, mdat, mkMoov(mdatPayloadOffset)]);
  }
  const moovSize = mkMoov(0).length;
  return Buffer.concat([ftyp, mkMoov(ftyp.length + moovSize + 8), mdat]);
}

const files = {
  "valid_1280x800.mp4": build({ w: 1280, h: 800 }),
  "valid_1080x1920.mp4": build({ w: 1080, h: 1920 }),
  "wrong_1920x1080.mp4": build({ w: 1920, h: 1080 }),
  "hevc_1280x800.mp4": build({ w: 1280, h: 800, codec: "hvc1" }),
  "moov_at_end_1280x800.mp4": build({ w: 1280, h: 800, moovAtEnd: true }),
  "audio_1280x800.mp4": build({ w: 1280, h: 800, audio: true }),
  // Кадр 1920x1080, но матрица поворачивает на 90° → на экране 1080x1920.
  "rotated_1080x1920.mp4": build({ w: 1920, h: 1080, matrix: MATRIX_ROT90 }),
  "no_moov.mp4": Buffer.concat([ftyp, box("mdat", payload(4096))]),
  "not_mp4.bin": Buffer.from("Это просто текст, а не видео.\n".repeat(40), "utf8"),
};
// Обрезанные: moov в конце потерян (mdat объявлен длиннее файла) и обрезка
// файла с moov в начале.
const atEnd = files["moov_at_end_1280x800.mp4"];
files["truncated_1280x800.mp4"] = atEnd.subarray(0, Math.floor(atEnd.length * 0.4));
const atStart = files["valid_1280x800.mp4"];
files["truncated_mdat_1280x800.mp4"] = atStart.subarray(0, atStart.length - 1000);

for (const [name, buf] of Object.entries(files)) {
  writeFileSync(join(out, name), buf);
  console.log(name, buf.length);
}
