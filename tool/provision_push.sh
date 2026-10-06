#!/usr/bin/env bash
# Заводская запись облачных данных в ОДИН аппарат по adb.
#
#   tool/provision_push.sh <ID> [adb-серийник]
#
# Что делает: находит provisioning_out/*/configs/<ID>.json; кладёт его на
# планшет в общий каталог /sdcard/CarFog/device_config.json (переживает pm clear
# и переустановку); выдаёт приложению доступ ко всем файлам (appops
# MANAGE_EXTERNAL_STORAGE); перезапускает приложение; читает обратно размер и
# sha256 файла и сверяет с локальным. Печатает «ок» или причину. ТОКЕН НЕ
# ПЕЧАТАЕТСЯ. Работает только с одним аппаратом за раз: если подключено больше
# одного, серийник обязателен.
#
# Переменные: PROVISION_DIR (по умолчанию provisioning_out), APP_ID (по
# умолчанию ee.carfog.dryfog).
set -uo pipefail

ID="${1:-}"
SERIAL="${2:-}"
PROVISION_DIR="${PROVISION_DIR:-provisioning_out}"
APP_ID="${APP_ID:-ee.carfog.dryfog}"
REMOTE_DIR="/sdcard/CarFog"
REMOTE="$REMOTE_DIR/device_config.json"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

# нужные утилиты (на части систем shasum нет — есть sha256sum)
for c in adb awk grep tr wc; do
  command -v "$c" >/dev/null 2>&1 || die "не найдена утилита $c"
done
if command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum "$1" | awk '{print $1}'; }
else
  die "нет ни shasum, ни sha256sum: установите одну из них (macOS: shasum; Linux: coreutils)"
fi

[ -n "$ID" ] || die "использование: tool/provision_push.sh <ID> [adb-серийник]"
[[ "$ID" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "недопустимый номер аппарата"

# файл конфигурации: ровно один
shopt -s nullglob
matches=("$PROVISION_DIR"/*/configs/"$ID".json)
shopt -u nullglob
[ "${#matches[@]}" -ge 1 ] || die "нет файла $PROVISION_DIR/*/configs/$ID.json (сначала tool/provision_devices.py)"
[ "${#matches[@]}" -eq 1 ] || die "найдено несколько файлов для $ID: ${matches[*]} — оставьте один"
LOCAL="${matches[0]}"

# ровно один аппарат за раз
devs=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
count=$(printf '%s\n' "$devs" | grep -c . || true)
if [ -z "$SERIAL" ]; then
  [ "$count" -eq 1 ] || die "подключено аппаратов: $count; укажите серийник вторым аргументом (работаем с одним аппаратом за раз)"
  SERIAL="$devs"
else
  printf '%s\n' "$devs" | grep -qx "$SERIAL" || die "аппарат $SERIAL не найден среди подключённых"
fi
A=(adb -s "$SERIAL")

local_size=$(wc -c < "$LOCAL" | tr -d ' ')
local_sha=$(sha256_of "$LOCAL")

"${A[@]}" shell "mkdir -p $REMOTE_DIR" >/dev/null 2>&1 || die "не удалось создать $REMOTE_DIR на аппарате"
"${A[@]}" push "$LOCAL" "$REMOTE" >/dev/null 2>&1 || die "adb push не удался"

# доступ приложения ко всем файлам (иначе при старте файл не прочитать)
if "${A[@]}" shell "pm list packages $APP_ID" 2>/dev/null | grep -q "package:$APP_ID"; then
  "${A[@]}" shell "appops set $APP_ID MANAGE_EXTERNAL_STORAGE allow" >/dev/null 2>&1 \
    || die "appops set не удался (нужен MANAGE_EXTERNAL_STORAGE для $APP_ID)"
  mode=$("${A[@]}" shell "appops get $APP_ID MANAGE_EXTERNAL_STORAGE" 2>/dev/null | tr -d '\r')
  echo "$mode" | grep -qi "allow" || die "разрешение не выдано: $mode"
  "${A[@]}" shell "am force-stop $APP_ID" >/dev/null 2>&1
  "${A[@]}" shell "monkey -p $APP_ID -c android.intent.category.LAUNCHER 1" >/dev/null 2>&1 \
    || echo "ПРЕДУПРЕЖДЕНИЕ: приложение не удалось запустить (файл применится при ближайшем запуске)"
else
  echo "ПРЕДУПРЕЖДЕНИЕ: приложение $APP_ID не установлено — файл записан, разрешение выдайте после установки (appops set $APP_ID MANAGE_EXTERNAL_STORAGE allow)"
fi

# проверка: размер и sha256 на аппарате = локальные
remote_size=$("${A[@]}" shell "stat -c %s $REMOTE" 2>/dev/null | tr -d '\r ')
remote_sha=$("${A[@]}" shell "sha256sum $REMOTE" 2>/dev/null | tr -d '\r' | awk '{print $1}')
[ "$remote_size" = "$local_size" ] || die "размер на аппарате ($remote_size) не равен локальному ($local_size)"
[ "$remote_sha" = "$local_sha" ] || die "sha256 на аппарате не совпал с локальным"

echo "ок: $ID записан в $REMOTE (размер $local_size байт, sha256 совпал)"
