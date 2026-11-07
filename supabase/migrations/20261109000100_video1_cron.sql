-- ============================================================
-- VIDEO1: ежесуточная уборка файлов видео из бакета. НЕ ПРИМЕНЕНО.
-- Применять ПОСЛЕ 20261109000000_video1_playlist.sql и развёртывания Edge
-- Function video-purge. Расписание — по образцу 20261104000100_rd1_cron.sql.
--
-- Секрет НЕ новый: используется тот же, что у diag-shot-purge — запись
-- diag_purge_secret в Vault и переменная DIAG_PURGE_SECRET функций (секреты
-- Edge Functions общие на проект). Если очистка диагностики уже настроена,
-- от владельца ничего не требуется.
-- Перед применением заменить <PROJECT_REF> на код проекта Supabase.
-- ============================================================

-- Удалённые, отклонённые и брошенные видео — ежедневно в 03:37 UTC.
select cron.schedule(
  'device-video-purge',
  '37 3 * * *',
  $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/video-purge',
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
-- Отключить: select cron.unschedule('device-video-purge');
