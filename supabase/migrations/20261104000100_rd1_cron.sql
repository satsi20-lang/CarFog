-- ============================================================
-- RD1: расписание очистки диагностики. НЕ ПРИМЕНЕНО.
-- Применять ПОСЛЕ 20261104000000_rd1_remote_diag.sql и развёртывания Edge
-- Function diag-shot-purge. pg_cron и pg_net в проекте включены (там уже
-- есть 2 задания: Telegram каждые 5 минут и напоминания в 07:00).
--
-- Перед применением (делает владелец, значения в репозиторий НЕ класть):
--  1. Придумать длинный случайный секрет очистки (40+ символов).
--  2. Положить его в Vault под именем diag_purge_secret:
--       select vault.create_secret('<СЕКРЕТ>', 'diag_purge_secret');
--  3. Тот же секрет — переменной DIAG_PURGE_SECRET функции diag-shot-purge:
--       supabase secrets set DIAG_PURGE_SECRET=<СЕКРЕТ>
--  4. В строке ниже заменить <PROJECT_REF> на код проекта Supabase.
-- ============================================================

-- Пакеты диагностики старше 14 дней — ежедневно в 03:17 UTC.
select cron.schedule(
  'device-diag-purge',
  '17 3 * * *',
  $$select public.device_diag_purge()$$
);

-- Снимки экрана старше 24 часов — ежедневно в 03:27 UTC. Файлы в бакете
-- удаляет Edge Function (Storage API); секрет из Vault уходит заголовком.
select cron.schedule(
  'device-shot-purge',
  '27 3 * * *',
  $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/diag-shot-purge',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-purge-secret', (select decrypted_secret from vault.decrypted_secrets
                          where name = 'diag_purge_secret' limit 1)
    ),
    body := '{}'::jsonb
  );
  $$
);

-- Проверка: select jobname, schedule, active from cron.job;
-- Отключить: select cron.unschedule('device-shot-purge');
