-- Применено в боевой базе 2026-10-18 через MCP; файл фиксирует схему в репозитории.
-- ============================================================
-- Хеширование токенов аппаратов, фаза B: открытый токен больше не хранится.
-- Применять ПОСЛЕ 20261018000000_token_hash_phase_a.sql.
-- С этого момента новые аппараты заводятся только с token_hash
-- (tool/provision_devices.py, docs/provisioning.md); вставка без token_hash
-- падает на NOT NULL.
-- ============================================================

alter table public.devices alter column token_hash set not null;
alter table public.devices alter column token drop not null;
update public.devices set token = null where token is not null;
comment on column public.devices.token is 'Не используется: открытый токен не хранится. Проверка по token_hash (sha256 hex от токена).';
comment on column public.devices.token_hash is 'sha256(token) в hex. Новый аппарат: encode(sha256(convert_to(<токен>, ''UTF8'')), ''hex'').';
