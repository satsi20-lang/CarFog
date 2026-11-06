// CORS для Edge Functions, которые вызывает БРАУЗЕР (портал).
//
// Зачем: `supabase.functions.invoke` из браузера сначала посылает предзапрос
// OPTIONS. Без ответа на него и без заголовков CORS браузер отменит вызов,
// и загрузка из портала просто не заработает.
//
// Образца в репозитории нет: у развёрнутых функций портала
// (portal-checkout, portal-billing) исходников здесь не лежит, поэтому это
// первый общий модуль CORS. Новым функциям для портала брать его отсюда.
//
// Функции, которые вызывает АППАРАТ (release-url, brand-url,
// diag-shot-upload), в CORS не нуждаются: там не браузер и нет Origin.

/**
 * Разрешённые адреса. Звёздочку (`*`) не ставим НИКОГДА: функция
 * brand-upload работает под JWT супервайзера, и открывать её любому сайту
 * нельзя. Чужой Origin не получает заголовка вовсе — браузер сам отменит
 * запрос.
 */
export const ALLOWED_ORIGINS: readonly string[] = [
  "https://app.carfog.online", // портал
  "http://localhost:5173",     // разработка (vite)
];

/** Заголовки, которые присылает supabase-js. */
export const ALLOW_HEADERS = "authorization, apikey, content-type, x-client-info";
export const ALLOW_METHODS = "POST, OPTIONS";
/** Сколько браузер может помнить ответ на предзапрос, с. */
export const MAX_AGE_S = 86_400;

export function isAllowedOrigin(origin: string | null | undefined): boolean {
  return typeof origin === "string" && ALLOWED_ORIGINS.includes(origin);
}

/**
 * Заголовки CORS. Ставятся на ВСЕ ответы функции — и успешные, и об
 * ошибках (401, 403, 405, 500): иначе браузер не покажет порталу причину
 * отказа, и вместо понятного сообщения получится «ошибка сети».
 *
 * `Vary: Origin` обязателен: ответы для разных адресов различаются, и без
 * него промежуточный кэш мог бы отдать чужой заголовок.
 */
export function corsHeaders(origin: string | null | undefined): Record<string, string> {
  const h: Record<string, string> = {
    "Vary": "Origin",
    "Access-Control-Allow-Methods": ALLOW_METHODS,
    "Access-Control-Allow-Headers": ALLOW_HEADERS,
    "Access-Control-Max-Age": String(MAX_AGE_S),
  };
  if (isAllowedOrigin(origin)) h["Access-Control-Allow-Origin"] = origin as string;
  return h;
}

/** Ответ JSON с заголовками CORS. */
export function jsonResponse(
  status: number,
  body: unknown,
  origin: string | null | undefined,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(origin) },
  });
}

/**
 * Ответ на предзапрос: 204 без тела. Чужому Origin отвечаем так же, но без
 * `Allow-Origin` — ничего не раскрываем и не подтверждаем.
 */
export function preflightResponse(origin: string | null | undefined): Response {
  return new Response(null, { status: 204, headers: corsHeaders(origin) });
}
