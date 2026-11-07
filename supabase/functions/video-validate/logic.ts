// Чистая логика Edge Function video-validate (VIDEO1): разбор MP4 по
// содержимому БЕЗ скачивания всего файла. Читаются только заголовки боксов
// верхнего уровня (по 16 байт) и целиком — бокс moov. Тело mdat (почти весь
// файл) не читается никогда. Без сети и Deno API: чтение диапазонов
// передаётся функцией, поэтому всё проверяется обычными тестами
// (logic_test.ts: node --test).
//
// Что проверяется (ТЗ 3.4): ftyp; moov (в начале или в конце файла) →
// mvhd (длительность), trak/tkhd (ширина и высота), mdia/hdlr ('vide' /
// 'soun'), stsd (avc1/avc3 = H.264). Затем размер и разрешение под профиль.
//
// Чего НЕ проверяется: что кадры действительно декодируются. Это делает
// приложение на планшете (читает кадр плеером) перед тем, как принять файл.

/** Читает байты [start, end) файла. */
export type RangeReader = (start: number, end: number) => Promise<Uint8Array>;

export type RejectCode =
  | "size_mismatch"   // размер в хранилище не равен объявленному
  | "empty"           // файл пустой
  | "not_mp4"         // нет ftyp в начале
  | "truncated"       // бокс объявлен длиннее файла
  | "no_moov"         // нет moov: нечего воспроизводить
  | "moov_too_large"  // moov больше предела разбора
  | "bad_structure"   // вложенные боксы повреждены
  | "no_video"        // нет видеодорожки
  | "not_h264"        // видео не H.264 (в detail — кодек)
  | "wrong_resolution"
  | "unknown_profile";

export interface Mp4Info {
  majorBrand: string;
  durationMs: number | null;
  /** Размер как его покажет плеер: с учётом поворота на 90/270°. */
  width: number;
  height: number;
  hasAudio: boolean;
  videoCodec: string;
}

export type ParseResult =
  | { ok: true; info: Mp4Info }
  | { ok: false; code: RejectCode; detail?: string };

/** Предел разбора moov, байт. Обычный moov — десятки КБ; 32 МБ с запасом. */
export const MAX_MOOV_BYTES = 32 * 1024 * 1024;
/** Сколько боксов верхнего уровня просматриваем (у фрагментированного MP4 их тысячи). */
export const MAX_TOP_BOXES = 64;
/** Предел размера ftyp. */
const MAX_FTYP_BYTES = 4096;

/** Размер экрана по профилю аппарата (ТЗ 2.2). */
export const PROFILES: Readonly<Record<string, { width: number; height: number }>> = {
  "ixp101m1": { width: 1280, height: 800 },   // альбом
  "sy156-a510": { width: 1080, height: 1920 }, // портрет
};

class Mp4Error extends Error {
  code: RejectCode;
  detail?: string;
  constructor(code: RejectCode, detail?: string) {
    super(code);
    this.code = code;
    this.detail = detail;
  }
}

function u32(b: Uint8Array, o: number): number {
  if (o < 0 || o + 4 > b.length) throw new Mp4Error("bad_structure");
  return ((b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]) >>> 0;
}
function i32(b: Uint8Array, o: number): number {
  return u32(b, o) | 0;
}
function u16(b: Uint8Array, o: number): number {
  if (o < 0 || o + 2 > b.length) throw new Mp4Error("bad_structure");
  return (b[o] << 8) | b[o + 1];
}
function u64(b: Uint8Array, o: number): number {
  const hi = u32(b, o);
  const lo = u32(b, o + 4);
  const v = hi * 4294967296 + lo;
  if (!Number.isSafeInteger(v)) throw new Mp4Error("bad_structure");
  return v;
}
function fourcc(b: Uint8Array, o: number): string {
  if (o < 0 || o + 4 > b.length) throw new Mp4Error("bad_structure");
  return String.fromCharCode(b[o], b[o + 1], b[o + 2], b[o + 3]);
}

/** Безопасная для сообщений запись четырёх знаков кодека. */
export function safeFourcc(s: string): string {
  return s.replace(/[^A-Za-z0-9]/g, "_").slice(0, 4);
}

interface Box {
  type: string;
  /** Начало тела (после заголовка). */
  body: number;
  /** Конец бокса (не включительно). */
  end: number;
}

/** Боксы внутри буфера [start, end). */
function* children(buf: Uint8Array, start: number, end: number): Generator<Box> {
  let o = start;
  while (o < end) {
    if (end - o < 8) throw new Mp4Error("bad_structure");
    let size = u32(buf, o);
    const type = fourcc(buf, o + 4);
    let hdr = 8;
    if (size === 1) {
      size = u64(buf, o + 8);
      hdr = 16;
    } else if (size === 0) {
      size = end - o;
    }
    if (size < hdr || o + size > end) throw new Mp4Error("bad_structure");
    yield { type, body: o + hdr, end: o + size };
    o += size;
  }
}

function find(buf: Uint8Array, parent: Box, type: string): Box | null {
  for (const c of children(buf, parent.body, parent.end)) if (c.type === type) return c;
  return null;
}

interface Track {
  handler: string;
  codec: string | null;
  width: number;
  height: number;
}

function parseTrak(buf: Uint8Array, trak: Box): Track {
  let width = 0;
  let height = 0;
  let rotated = false;
  const tkhd = find(buf, trak, "tkhd");
  if (tkhd) {
    const v = buf[tkhd.body];
    const base = tkhd.body + (v === 1 ? 88 : 76); // ширина/высота 16.16 в конце
    if (base + 8 <= tkhd.end) {
      width = u32(buf, base) >>> 16;
      height = u32(buf, base + 4) >>> 16;
    }
    // Матрица (a b u c d v x y w): при повороте на 90/270° a = d = 0.
    const m = tkhd.body + (v === 1 ? 52 : 40);
    if (m + 20 <= tkhd.end) {
      const a = i32(buf, m);
      const b = i32(buf, m + 4);
      const c = i32(buf, m + 12);
      const d = i32(buf, m + 16);
      rotated = a === 0 && d === 0 && b !== 0 && c !== 0;
    }
  }

  let handler = "";
  let codec: string | null = null;
  const mdia = find(buf, trak, "mdia");
  if (mdia) {
    const hdlr = find(buf, mdia, "hdlr");
    if (hdlr && hdlr.body + 12 <= hdlr.end) handler = fourcc(buf, hdlr.body + 8);
    const minf = find(buf, mdia, "minf");
    const stbl = minf && find(buf, minf, "stbl");
    const stsd = stbl && find(buf, stbl, "stsd");
    if (stsd && stsd.body + 16 <= stsd.end && u32(buf, stsd.body + 4) >= 1) {
      codec = fourcc(buf, stsd.body + 12);
      // Если tkhd не дал размера — берём из описания кадра (VisualSampleEntry).
      if ((width === 0 || height === 0) && stsd.body + 44 <= stsd.end) {
        width = u16(buf, stsd.body + 40);
        height = u16(buf, stsd.body + 42);
      }
    }
  }
  if (rotated) [width, height] = [height, width];
  return { handler, codec, width, height };
}

/** Разбор содержимого moov (буфер — только тело moov). */
export function parseMoov(buf: Uint8Array): {
  durationMs: number | null;
  tracks: Track[];
} {
  const root: Box = { type: "moov", body: 0, end: buf.length };
  let durationMs: number | null = null;
  const tracks: Track[] = [];
  for (const c of children(buf, root.body, root.end)) {
    if (c.type === "mvhd") {
      const v = buf[c.body];
      const tsOff = c.body + (v === 1 ? 20 : 12);
      const timescale = u32(buf, tsOff);
      let dur: number;
      let unknown: boolean;
      if (v === 1) {
        dur = u64(buf, tsOff + 4);
        unknown = false;
      } else {
        dur = u32(buf, tsOff + 4);
        unknown = dur === 0xffffffff;
      }
      durationMs = timescale > 0 && !unknown ? Math.round((dur * 1000) / timescale) : null;
    } else if (c.type === "trak") {
      tracks.push(parseTrak(buf, c));
    }
  }
  return { durationMs, tracks };
}

/**
 * Разбор файла. size — полный размер файла. Читает только заголовки боксов
 * и moov.
 */
export async function parseMp4(size: number, read: RangeReader): Promise<ParseResult> {
  try {
    if (!Number.isSafeInteger(size) || size <= 0) return { ok: false, code: "empty" };
    let offset = 0;
    let majorBrand = "";
    let moov: Uint8Array | null = null;

    for (let i = 0; i < MAX_TOP_BOXES && offset < size; i++) {
      if (size - offset < 8) {
        return { ok: false, code: i === 0 ? "not_mp4" : "truncated" };
      }
      const head = await read(offset, Math.min(offset + 16, size));
      if (head.length < 8) return { ok: false, code: "truncated" };
      let boxSize = u32(head, 0);
      const type = fourcc(head, 4);
      let hdr = 8;
      if (boxSize === 1) {
        if (head.length < 16) return { ok: false, code: "truncated" };
        boxSize = u64(head, 8);
        hdr = 16;
      } else if (boxSize === 0) {
        boxSize = size - offset; // до конца файла
      }
      if (i === 0 && type !== "ftyp") return { ok: false, code: "not_mp4" };
      if (boxSize < hdr) return { ok: false, code: "bad_structure" };
      if (offset + boxSize > size) return { ok: false, code: "truncated" };

      if (type === "ftyp") {
        if (boxSize - hdr > MAX_FTYP_BYTES) return { ok: false, code: "bad_structure" };
        const body = await read(offset + hdr, offset + boxSize);
        if (body.length >= 4) majorBrand = fourcc(body, 0);
      } else if (type === "moov") {
        if (boxSize - hdr > MAX_MOOV_BYTES) return { ok: false, code: "moov_too_large" };
        const body = await read(offset + hdr, offset + boxSize);
        if (body.length !== boxSize - hdr) return { ok: false, code: "truncated" };
        moov = body;
      }
      offset += boxSize;
    }

    if (moov === null) return { ok: false, code: "no_moov" };

    const { durationMs, tracks } = parseMoov(moov);
    const video = tracks.find((t) => t.handler === "vide");
    if (!video) return { ok: false, code: "no_video" };
    const codec = video.codec ?? "";
    if (codec !== "avc1" && codec !== "avc3") {
      return { ok: false, code: "not_h264", detail: safeFourcc(codec || "none") };
    }
    return {
      ok: true,
      info: {
        majorBrand,
        durationMs,
        width: video.width,
        height: video.height,
        hasAudio: tracks.some((t) => t.handler === "soun"),
        videoCodec: codec,
      },
    };
  } catch (e) {
    if (e instanceof Mp4Error) return { ok: false, code: e.code, detail: e.detail };
    return { ok: false, code: "bad_structure" };
  }
}

/** Подходит ли разрешение профилю аппарата. */
export function checkProfile(
  info: { width: number; height: number },
  profile: string,
): { ok: true } | { ok: false; code: RejectCode; detail: string } {
  const need = Object.prototype.hasOwnProperty.call(PROFILES, profile) ? PROFILES[profile] : null;
  if (!need) return { ok: false, code: "unknown_profile", detail: safeDetail(profile) };
  if (info.width !== need.width || info.height !== need.height) {
    return {
      ok: false,
      code: "wrong_resolution",
      detail: `${info.width}x${info.height} need ${need.width}x${need.height}`,
    };
  }
  return { ok: true };
}

function safeDetail(s: string): string {
  return s.replace(/[^A-Za-z0-9 x._-]/g, "_").slice(0, 60);
}

/**
 * Строка причины отказа для базы и портала: «код» или «код:подробности».
 * Портал переводит по коду (EN/RU/ET); подробности — только латиница,
 * цифры и безопасные знаки.
 */
export function rejectReason(code: RejectCode, detail?: string): string {
  const d = detail ? safeDetail(detail) : "";
  return d ? `${code}:${d}` : code;
}

/** Полный размер из заголовка Content-Range ("bytes 0-0/12345"). null — нет. */
export function totalFromContentRange(h: string | null): number | null {
  if (h === null) return null;
  const m = /^bytes\s+(\d+)-(\d+)\/(\d+)$/i.exec(h.trim());
  if (!m) return null;
  const total = Number(m[3]);
  return Number.isSafeInteger(total) ? total : null;
}

/** Заголовок Range для байтов [start, end) (end не включается). */
export function rangeHeader(start: number, end: number): string {
  return `bytes=${start}-${end - 1}`;
}

/** Итог проверки файла: принять или отклонить с причиной. */
export type Verdict =
  | { kind: "ok"; info: Mp4Info }
  | { kind: "reject"; code: RejectCode; detail?: string };

/**
 * Решение по файлу: объявленный размер → разбор → разрешение под профиль.
 * objectSize — реальный размер объекта в хранилище.
 */
export function judge(
  declaredSize: number,
  objectSize: number,
  parsed: ParseResult,
  profile: string,
): Verdict {
  if (objectSize !== declaredSize) {
    return { kind: "reject", code: "size_mismatch", detail: `${objectSize} of ${declaredSize}` };
  }
  if (!parsed.ok) return { kind: "reject", code: parsed.code, detail: parsed.detail };
  const p = checkProfile(parsed.info, profile);
  if (!p.ok) return { kind: "reject", code: p.code, detail: p.detail };
  return { kind: "ok", info: parsed.info };
}
