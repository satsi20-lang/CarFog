// Чистая логика Edge Function video-purge (VIDEO1).
export { batches, secretMatches } from "../diag-shot-purge/logic.ts";

export interface PurgeItem {
  id: string;
  path: string;
}

/** Элементы на удаление из ответа _video_purge_pick: только пути видео. */
export function pickedItems(raw: unknown): PurgeItem[] {
  if (!Array.isArray(raw)) return [];
  const out: PurgeItem[] = [];
  for (const x of raw) {
    if (typeof x !== "object" || x === null) continue;
    const { id, path } = x as Record<string, unknown>;
    if (typeof id !== "string" || typeof path !== "string") continue;
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id)) continue;
    if (!/^[A-Za-z0-9_-]{1,64}\/[0-9a-f-]{36}\.mp4$/.test(path)) continue;
    out.push({ id, path });
  }
  return out;
}
