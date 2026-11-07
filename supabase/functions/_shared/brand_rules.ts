// Общие правила пакета бренда (ТЗ TZ_Brand_WhiteLabel_v1, разделы 4 и 5):
// семь токенов цвета, схема brand.json версии 1, проверки PNG и расчёт
// контраста по WCAG 2.x.
//
// Этот модуль — ЕДИНСТВЕННЫЙ источник правил. Его использует Edge Function
// brand-upload; портал (этап 3) и приложение (этап 2) повторяют ровно эти
// же формулы и пороги. Меняя пороги здесь, нужно менять их и там —
// иначе портал сохранит пакет, который аппарат потом отвергнет.
//
// Сети и Deno API здесь нет: модуль проверяется обычными тестами
// (node --test).

export const BRAND_SCHEMA = 1;

/** id бренда: как в check-ограничении таблицы public.brands. */
export const BRAND_ID_RE = /^[a-z0-9][a-z0-9_-]{1,30}$/;

/** Семь токенов цвета бренда. Порядок важен только для сообщений. */
export const COLOR_TOKENS = [
  "primary",
  "primaryAlt",
  "background",
  "backgroundStandby",
  "surface",
  "textPrimary",
  "textSecondary",
] as const;

export type ColorToken = (typeof COLOR_TOKENS)[number];
export type Colors = Record<ColorToken, string>;

// ---------- Пределы (ТЗ, раздел 5) ----------

/** Архив бренда — до 1 МБ (то же число в бакете и в брендовых таблицах). */
export const MAX_ZIP_BYTES = 1_048_576;
/** Логотип PNG — до 300 КБ. */
export const MAX_LOGO_BYTES = 307_200;
/** Сторона картинки — до 1000 px. */
export const MAX_PNG_SIDE = 1000;
/** Файлов в архиве — не больше 8 (защита от «тысячи пустых файлов»). */
export const MAX_ZIP_ENTRIES = 8;
/** Суммарный РАСПАКОВАННЫЙ размер — до 3 МБ (защита от zip-бомбы). */
export const MAX_UNPACKED_BYTES = 3 * 1_048_576;
/** Белый список имён в архиве. Путей и каталогов нет. */
export const ALLOWED_ZIP_NAMES = ["brand.json", "logo.png", "qr_default.png"] as const;
/** Название бренда и слоган. */
export const MAX_NAME_LEN = 40;
export const MAX_SLOGAN_LEN = 80;

// ---------- Цвет ----------

const HEX_RE = /^#[0-9a-fA-F]{6}$/;

/** '#RRGGBB' → [r,g,b] 0…255. null — не цвет. */
export function parseHexColor(v: unknown): [number, number, number] | null {
  if (typeof v !== "string" || !HEX_RE.test(v)) return null;
  return [
    parseInt(v.slice(1, 3), 16),
    parseInt(v.slice(3, 5), 16),
    parseInt(v.slice(5, 7), 16),
  ];
}

/** Относительная яркость по WCAG 2.x (sRGB). */
export function relativeLuminance(rgb: [number, number, number]): number {
  const [r, g, b] = rgb.map((c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  }) as [number, number, number];
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/**
 * Контраст двух цветов по WCAG: от 1 (одинаковые) до 21 (чёрный и белый).
 * Порядок цветов не важен.
 */
export function contrastRatio(a: string, b: string): number | null {
  const ra = parseHexColor(a);
  const rb = parseHexColor(b);
  if (ra === null || rb === null) return null;
  const la = relativeLuminance(ra);
  const lb = relativeLuminance(rb);
  const hi = Math.max(la, lb);
  const lo = Math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/**
 * Пары, которые обязаны пройти проверку (ТЗ раздел 4 и задание этапа 1):
 * обычный текст к каждому фону — не меньше 4,5; второстепенный текст и
 * акцент к основному фону — не меньше 3,0.
 */
export const CONTRAST_RULES: { fg: ColorToken; bg: ColorToken; min: number }[] = [
  { fg: "textPrimary", bg: "background", min: 4.5 },
  { fg: "textPrimary", bg: "surface", min: 4.5 },
  { fg: "textPrimary", bg: "backgroundStandby", min: 4.5 },
  { fg: "textSecondary", bg: "background", min: 3.0 },
  { fg: "primary", bg: "background", min: 3.0 },
];

export interface ContrastFailure {
  fg: ColorToken;
  bg: ColorToken;
  min: number;
  /** Посчитанный контраст, округлён до двух знаков. null — цвет не разобран. */
  ratio: number | null;
}

export interface ContrastResult {
  ok: boolean;
  failures: ContrastFailure[];
}

const round2 = (x: number): number => Math.round(x * 100) / 100;

/** Проверка всех пар. ok=false — список непрошедших с числами. */
export function checkContrast(colors: Partial<Colors>): ContrastResult {
  const failures: ContrastFailure[] = [];
  for (const rule of CONTRAST_RULES) {
    const fg = colors[rule.fg];
    const bg = colors[rule.bg];
    const ratio = fg !== undefined && bg !== undefined ? contrastRatio(fg, bg) : null;
    if (ratio === null || ratio < rule.min) {
      failures.push({ fg: rule.fg, bg: rule.bg, min: rule.min, ratio: ratio === null ? null : round2(ratio) });
    }
  }
  return { ok: failures.length === 0, failures };
}

/**
 * Встроенный бренд CaRFog: РОВНО текущие значения приложения (опись
 * docs/inventory/brand_inventory.md). Здесь они только для проверки, что
 * пороги контраста не отвергают наш собственный вид.
 */
export const CARFOG_COLORS: Colors = {
  primary: "#2EC4B6",
  primaryAlt: "#00C6B2",
  background: "#1A1A1A",
  backgroundStandby: "#0B2545",
  surface: "#2E2E2E",
  textPrimary: "#FFFFFF",
  textSecondary: "#8899AA",
};

// ---------- PNG ----------

const PNG_SIG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];

/** Настоящий PNG: подпись и первый блок IHDR на своём месте. */
export function isPng(bytes: Uint8Array): boolean {
  if (bytes.length < 24) return false;
  for (let i = 0; i < PNG_SIG.length; i++) {
    if (bytes[i] !== PNG_SIG[i]) return false;
  }
  // Длина IHDR = 13 и тип 'IHDR'.
  const len = (bytes[8]! << 24) | (bytes[9]! << 16) | (bytes[10]! << 8) | bytes[11]!;
  return len === 13 &&
    bytes[12] === 0x49 && bytes[13] === 0x48 && bytes[14] === 0x44 && bytes[15] === 0x52;
}

/** Размеры PNG из IHDR. null — не PNG. */
export function pngSize(bytes: Uint8Array): { width: number; height: number } | null {
  if (!isPng(bytes)) return null;
  const read = (o: number): number =>
    ((bytes[o]! << 24) | (bytes[o + 1]! << 16) | (bytes[o + 2]! << 8) | bytes[o + 3]!) >>> 0;
  const width = read(16);
  const height = read(20);
  if (width < 1 || height < 1) return null;
  return { width, height };
}

/** Картинка пакета: PNG, в пределах размера файла и стороны. */
export function checkImage(
  bytes: Uint8Array,
  maxBytes: number,
): { ok: true; width: number; height: number } | { ok: false; error: string } {
  if (bytes.length > maxBytes) return { ok: false, error: "too_big" };
  const size = pngSize(bytes);
  if (size === null) return { ok: false, error: "not_png" };
  if (size.width > MAX_PNG_SIDE || size.height > MAX_PNG_SIDE) {
    return { ok: false, error: "side_too_large" };
  }
  return { ok: true, width: size.width, height: size.height };
}

// ---------- brand.json ----------

export interface Manifest {
  schema: number;
  id: string;
  version: number;
  name: string;
  colors: Colors;
  slogan: string;
  logo: string;
  qr_default?: string;
}

export type ManifestCheck =
  | { ok: true; manifest: Manifest }
  | { ok: false; errors: string[] };

// Управляющие символы в названии и слогане недопустимы: они ломают вид и
// бывают признаком подмены.
const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f]/;

/**
 * Проверка brand.json по схеме версии 1. Поля `brand` и `version` — то, что
 * просил загружающий: манифест обязан совпадать с ними, иначе можно было бы
 * подписать чужой бренд.
 */
export function validateManifest(
  raw: unknown,
  want: { brand: string; version: number },
): ManifestCheck {
  const errors: string[] = [];
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return { ok: false, errors: ["manifest_not_object"] };
  }
  const m = raw as Record<string, unknown>;

  if (m.schema !== BRAND_SCHEMA) errors.push("bad_schema");

  const id = m.id;
  if (typeof id !== "string" || !BRAND_ID_RE.test(id)) errors.push("bad_id");
  else if (id !== want.brand) errors.push("id_mismatch");

  const version = m.version;
  if (typeof version !== "number" || !Number.isInteger(version) || version < 1) {
    errors.push("bad_version");
  } else if (version !== want.version) errors.push("version_mismatch");

  const name = m.name;
  if (typeof name !== "string" || name.trim().length < 1 ||
      name.length > MAX_NAME_LEN || CONTROL_RE.test(name)) {
    errors.push("bad_name");
  }

  // Слоган только на английском и один для всех языков (решение владельца
  // 8); пустой допустим — тогда аппарат показывает встроенную подпись.
  const slogan = m.slogan === undefined || m.slogan === null ? "" : m.slogan;
  if (typeof slogan !== "string" || slogan.length > MAX_SLOGAN_LEN ||
      CONTROL_RE.test(slogan)) {
    errors.push("bad_slogan");
  }

  const colorsRaw = m.colors;
  const colors: Partial<Colors> = {};
  if (typeof colorsRaw !== "object" || colorsRaw === null || Array.isArray(colorsRaw)) {
    errors.push("bad_colors");
  } else {
    const c = colorsRaw as Record<string, unknown>;
    for (const token of COLOR_TOKENS) {
      if (parseHexColor(c[token]) === null) errors.push(`bad_color:${token}`);
      else colors[token] = (c[token] as string).toUpperCase();
    }
    for (const key of Object.keys(c)) {
      if (!(COLOR_TOKENS as readonly string[]).includes(key)) {
        errors.push(`unknown_color:${key}`);
      }
    }
  }

  if (m.logo !== "logo.png") errors.push("bad_logo_name");
  if (m.qr_default !== undefined && m.qr_default !== null &&
      m.qr_default !== "qr_default.png") {
    errors.push("bad_qr_name");
  }

  if (errors.length > 0) return { ok: false, errors };

  const out: Manifest = {
    schema: BRAND_SCHEMA,
    id: id as string,
    version: version as number,
    name: (name as string).trim(),
    colors: colors as Colors,
    slogan: slogan as string,
    logo: "logo.png",
  };
  if (m.qr_default === "qr_default.png") out.qr_default = "qr_default.png";
  return { ok: true, manifest: out };
}
