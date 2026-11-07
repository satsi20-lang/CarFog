#!/usr/bin/env bash
# flutter analyze с допуском двух известных старых замечаний проекта
# (unused_field _currentTemp в treating.dart и const-конструктор в
# fog_background.dart). Любое другое замечание — ошибка.
cd "$(dirname "$0")/.."
OUT=$(flutter analyze 2>&1)
printf '%s\n' "$OUT" | tail -n +2
ISSUES=$(printf '%s\n' "$OUT" | grep -E '^\s*(info|warning|error) •' \
  | grep -v "lib/screens/treating.dart:50:10 • unused_field" \
  | grep -v "lib/widgets/fog_background.dart:37:3 • prefer_const_constructors_in_immutables" || true)
if [ -n "$ISSUES" ]; then
  echo "ОШИБКА: новые замечания analyze:"; printf '%s\n' "$ISSUES"; exit 1
fi
echo "analyze: чисто (кроме двух известных старых замечаний)"
