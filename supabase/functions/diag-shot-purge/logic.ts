// Чистая логика Edge Function diag-shot-purge (без сети и без Deno API).

// Сравнение секрета без утечки по времени. Пустой ожидаемый секрет — отказ
// всегда (функция без настроенного секрета никому не отвечает).
export function secretMatches(given: string | null, expected: string | undefined): boolean {
  if (!expected || expected.length < 32 || given === null) return false;
  const a = new TextEncoder().encode(given);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

// Пути на удаление из ответа device_shot_expired: только снимки бакета.
export function expiredPaths(r: unknown): string[] {
  if (typeof r !== "object" || r === null) return [];
  const list = (r as Record<string, unknown>).paths;
  if (!Array.isArray(list)) return [];
  return list.filter((p): p is string =>
    typeof p === "string" && /^[A-Za-z0-9_-]{1,64}\/shot-[0-9]{10,16}\.jpg$/.test(p)
  );
}

// Storage удаляет пачками; столько путей за один вызов.
export const BATCH = 100;

export function batches<T>(items: T[], size: number = BATCH): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}
