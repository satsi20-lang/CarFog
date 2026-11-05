// Чистая логика Edge Function diag-shot-upload (без сети и без Deno API),
// чтобы её можно было проверять обычными тестами (logic_test.ts).

// Потолок снимка: 400 КБ (совпадает с file_size_limit бакета diag-shots и
// проверкой в device_shot_register).
export const MAX_BYTES = 409_600;

const SHOT_RE = /^shot-[0-9]{10,16}$/;
const B64_RE = /^[A-Za-z0-9+/]+={0,2}$/;

export interface Input {
  device: string;
  token: string;
  shot: string;
  jpeg: Uint8Array;
}

// Разбор тела {device, token, shot, jpeg_b64}. null — вход неверный
// (подробности наружу не отдаём).
export function parseInput(body: unknown): Input | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  const { device, token, shot, jpeg_b64 } = b;
  if (typeof device !== "string" || device.length < 1 || device.length > 64) {
    return null;
  }
  if (typeof token !== "string" || token.length < 8 || token.length > 256) {
    return null;
  }
  if (typeof shot !== "string" || !SHOT_RE.test(shot)) return null;
  if (typeof jpeg_b64 !== "string" || jpeg_b64.length < 8) return null;
  // base64 длиннее потолка — отказ до декодирования.
  if (jpeg_b64.length > Math.ceil(MAX_BYTES / 3) * 4) return null;
  if (!B64_RE.test(jpeg_b64)) return null;
  const jpeg = decodeBase64(jpeg_b64);
  if (jpeg === null || !isJpeg(jpeg)) return null;
  return { device, token, shot, jpeg };
}

export function decodeBase64(s: string): Uint8Array | null {
  try {
    const bin = atob(s);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

// Только JPEG: начало FF D8 FF, конец FF D9. Всё остальное (HTML, скрипты,
// другие форматы) в бакет не попадает.
export function isJpeg(b: Uint8Array): boolean {
  return b.length >= 4 && b.length <= MAX_BYTES &&
    b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff &&
    b[b.length - 2] === 0xff && b[b.length - 1] === 0xd9;
}

export type ErrorCode =
  | "method"
  | "bad_request"
  | "auth"
  | "rate_limited"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  method: 405,
  bad_request: 400,
  auth: 401,
  rate_limited: 429,
  internal: 500,
};

// Ответ об ошибке: ТОЛЬКО короткий код, без причин, токена и текста
// исключений.
export function errorResponse(code: ErrorCode): {
  status: number;
  body: { ok: false; error: ErrorCode };
} {
  return { status: STATUS[code], body: { ok: false, error: code } };
}

// Ответ device_shot_register → код ошибки (null — можно грузить).
export function registerError(r: unknown): ErrorCode | null {
  if (typeof r !== "object" || r === null) return "internal";
  const x = r as Record<string, unknown>;
  if (x.ok === true && typeof x.path === "string") return null;
  if (x.error === "auth") return "auth";
  if (x.error === "bad_request") return "bad_request";
  if (x.error === "rate_limited") return "rate_limited";
  return "internal";
}

// Пути старых файлов на удаление: только внутри папки ЭТОГО ответа сервера
// (строки вида <device>/shot-<цифры>.jpg), без «..» и абсолютных путей.
export function removablePaths(r: unknown): string[] {
  if (typeof r !== "object" || r === null) return [];
  const list = (r as Record<string, unknown>).remove;
  if (!Array.isArray(list)) return [];
  return list.filter((p): p is string =>
    typeof p === "string" && /^[A-Za-z0-9_-]{1,64}\/shot-[0-9]{10,16}\.jpg$/.test(p)
  );
}
