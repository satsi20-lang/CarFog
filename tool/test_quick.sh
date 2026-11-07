#!/usr/bin/env bash
# Быстрая проверка во время работы: flutter analyze + только связанные тесты,
# без меток golden и slow (и без layout, если не менялись экраны).
#
#   tool/test_quick.sh                  — файлы из git diff origin/main...HEAD
#                                         плюс незакоммиченные и новые
#   tool/test_quick.sh lib/a.dart ...   — явно переданные файлы
#
# Связь файла с тестом: (1) test/*_test.dart с тем же корнем имени (free_run_service
# → *free_run*_test.dart); (2) тесты, импортирующие этот файл; (3) изменённые
# тесты. Связи нет — все быстрые тесты. Только документы/миграции — анализ и
# сообщение, что тесты приложения не нужны.
# Полный прогон — tool/test_full.sh (контрольные точки, см. CLAUDE.md).
set -uo pipefail
cd "$(dirname "$0")/.."
START=$(date +%s)

if [ "$#" -gt 0 ]; then
  CHANGED=$(printf '%s\n' "$@")
else
  BASE=$(git merge-base origin/main HEAD 2>/dev/null || echo HEAD)
  CHANGED=$( { git diff --name-only "$BASE" HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | sort -u )
fi
CHANGED=$(printf '%s\n' "$CHANGED" | sed '/^$/d')

echo "== Изменённые файлы: $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ')"

# Только документы, миграции и функции Supabase — тесты приложения не нужны.
APP_FILES=$(printf '%s\n' "$CHANGED" | grep -Ev '^(docs/|supabase/|.*\.md$|CLAUDE\.md$)' || true)
if [ -z "$APP_FILES" ] && [ -n "$CHANGED" ]; then
  echo "== Менялись только документы/миграции: тесты приложения не нужны."
  exit 0
fi

# Экраны/виджеты/бренд/ассеты — подключаем golden и layout.
UI=0
if printf '%s\n' "$CHANGED" | grep -Eq '^(lib/(screens|widgets|brand|ui)/|assets/|test/goldens/)'; then UI=1; fi

echo "== flutter analyze"
tool/_analyze.sh || exit 1

# Подбор тестов.
TESTS=""
add() { case " $TESTS " in *" $1 "*) ;; *) TESTS="$TESTS $1";; esac; }
UNMAPPED=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    test/*_test.dart) [ -f "$f" ] && add "$f"; continue ;;
    lib/*.dart) ;;
    *) continue ;;
  esac
  base=$(basename "$f" .dart)
  stem=$(printf '%s' "$base" | sed -E 's/_(service|screen|tab|state|colors|rules|zip)$//')
  rel=${f#lib/}
  found=0
  for t in test/*"$stem"*_test.dart; do [ -f "$t" ] && { add "$t"; found=1; }; done
  for t in $(grep -lE "(package:dry_fog_app/${rel}|/${base}\.dart)'" test/*_test.dart 2>/dev/null); do add "$t"; found=1; done
  [ "$found" = 0 ] && UNMAPPED=1
done <<EOF
$CHANGED
EOF

EXCL="slow"
if [ "$UI" = 0 ]; then EXCL="slow || golden || layout"; fi

if [ -z "$TESTS" ] || [ "$UNMAPPED" = 1 ]; then
  echo "== Связь с тестами найдена не для всех файлов: все быстрые тесты (--exclude-tags \"$EXCL\")"
  flutter test --exclude-tags "$EXCL"
  RC=$?
else
  echo "== Связанные тесты:$TESTS"
  echo "== Исключены метки: $EXCL"
  # shellcheck disable=SC2086
  flutter test $TESTS --exclude-tags "$EXCL"
  RC=$?
  # Предупредить, если связанный тест не запускался из-за метки.
  SKIPPED=""
  for t in $TESTS; do
    if grep -qE "^@Tags\(\['(slow|golden|layout)'\]\)" "$t"; then
      tag=$(sed -nE "1s/^@Tags\(\['([a-z]+)'\]\).*/\1/p" "$t")
      case "$EXCL" in *"$tag"*) SKIPPED="$SKIPPED $t($tag)";; esac
    fi
  done
  [ -n "$SKIPPED" ] && echo "== Не запускались из-за метки (проверит test_full.sh):$SKIPPED"
fi
echo "== Время: $(( $(date +%s) - START )) с"
exit $RC
