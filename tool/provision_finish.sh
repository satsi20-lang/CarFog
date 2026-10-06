#!/usr/bin/env bash
# Завершение пуско-наладки по adb (если кнопка «Завершить пуско-наладку» в
# сервисном меню недоступна): удаляет файл конфигурации с общего каталога.
#
#   tool/provision_finish.sh <ID> [adb-серийник]
#
# <ID> нужен для журнала и защиты от записи не в тот аппарат; токен не печатается.
# Облачные настройки в самом приложении остаются.
set -uo pipefail

ID="${1:-}"
SERIAL="${2:-}"
REMOTE_DIR="/sdcard/CarFog"
REMOTE="$REMOTE_DIR/device_config.json"

die() { echo "ОШИБКА: $*" >&2; exit 1; }

for c in adb awk grep tr; do
  command -v "$c" >/dev/null 2>&1 || die "не найдена утилита $c"
done

[ -n "$ID" ] || die "использование: tool/provision_finish.sh <ID> [adb-серийник]"
[[ "$ID" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "недопустимый номер аппарата"

devs=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')
count=$(printf '%s\n' "$devs" | grep -c . || true)
if [ -z "$SERIAL" ]; then
  [ "$count" -eq 1 ] || die "подключено аппаратов: $count; укажите серийник вторым аргументом (работаем с одним аппаратом за раз)"
  SERIAL="$devs"
else
  printf '%s\n' "$devs" | grep -qx "$SERIAL" || die "аппарат $SERIAL не найден среди подключённых"
fi
A=(adb -s "$SERIAL")

existed=$("${A[@]}" shell "[ -e $REMOTE ] && echo yes || echo no" 2>/dev/null | tr -d '\r ')
"${A[@]}" shell "rm -f $REMOTE" >/dev/null 2>&1
left=$("${A[@]}" shell "[ -e $REMOTE ] && echo yes || echo no" 2>/dev/null | tr -d '\r ')
[ "$left" = "no" ] || die "файл не удалён ($REMOTE остался на аппарате)"
"${A[@]}" shell "rmdir $REMOTE_DIR" >/dev/null 2>&1 || true   # пустой каталог убираем, непустой оставляем

if [ "$existed" = "yes" ]; then
  echo "ок: $ID — файл конфигурации удалён с аппарата"
else
  echo "ок: $ID — файла не было (уже удалён)"
fi
