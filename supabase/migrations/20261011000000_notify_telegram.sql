-- ============================================================
-- Telegram-уведомления о событиях аппаратов (Edge Function notify-telegram).
-- НЕ ПРИМЕНЕНО автоматически; SQL в Supabase выполняет только владелец.
-- Миграция идемпотентна (можно запускать повторно). Инструкция —
-- docs/telegram_alerts.md.
--
-- Все три таблицы читает и пишет только функция под сервисным ключом (он
-- обходит RLS). RLS включена, политик для anon/authenticated нет, права
-- отозваны: из приложения и панели под обычным входом таблиц не видно.
-- ============================================================

-- ---------- Куда слать: один канал Telegram на организацию ----------
-- chat_id — строка: у каналов и групп это отрицательное число вида
-- -100…, у личных чатов — положительное; узнаётся режимом whoami.
create table if not exists public.notify_channels (
  org_id     uuid        primary key,
  chat_id    text        not null,
  enabled    boolean     not null default true,
  created_at timestamptz default now()
);
alter table public.notify_channels enable row level security;
revoke all on table public.notify_channels from public, anon, authenticated;
drop policy if exists notify_channels_anon on public.notify_channels;
drop policy if exists notify_channels_authenticated on public.notify_channels;

-- ---------- Аппараты, о которых уже сообщено «нет связи» ----------
-- Строка появляется вместе с сообщением «нет связи» и удаляется вместе с
-- сообщением «связь восстановлена» (режим offline_check).
create table if not exists public.notify_offline_state (
  device_id   text        primary key,
  notified_at timestamptz not null
);
alter table public.notify_offline_state enable row level security;
revoke all on table public.notify_offline_state from public, anon, authenticated;
drop policy if exists notify_offline_state_anon on public.notify_offline_state;
drop policy if exists notify_offline_state_authenticated on public.notify_offline_state;

-- ---------- Защита от повторов (режим event) ----------
-- Одна строка на вид сообщения: ключ «device_id|type|channel», время
-- последней отправки. Не чаще одного сообщения в 5 минут на ключ (окно —
-- в logic.ts, DEDUP_WINDOW_MS).
create table if not exists public.notify_dedup (
  key     text        primary key,
  sent_at timestamptz not null
);
alter table public.notify_dedup enable row level security;
revoke all on table public.notify_dedup from public, anon, authenticated;
drop policy if exists notify_dedup_anon on public.notify_dedup;
drop policy if exists notify_dedup_authenticated on public.notify_dedup;
