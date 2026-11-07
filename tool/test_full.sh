#!/usr/bin/env bash
# Полная проверка для контрольных точек: flutter analyze + ВЕСЬ flutter test
# одним прогоном + Kotlin-тесты, если в диффе есть android/.
# Не запускать параллельно в нескольких рабочих копиях: тайминговые тесты
# (метка slow) под нагрузкой дают ложные красные.
set -uo pipefail
cd "$(dirname "$0")/.."
START=$(date +%s)

echo "== flutter analyze"
tool/_analyze.sh || exit 1

echo "== flutter test (все тесты, один прогон)"
flutter test || { echo "ОШИБКА: flutter test красный"; exit 1; }

BASE=$(git merge-base origin/main HEAD 2>/dev/null || echo HEAD)
if { git diff --name-only "$BASE" HEAD; git diff --name-only HEAD; git ls-files --others --exclude-standard; } | grep -q '^android/'; then
  echo "== Kotlin-тесты (в диффе есть android/)"
  JH="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  [ -z "${JAVA_HOME:-}" ] && [ -d "$JH" ] && export JAVA_HOME="$JH"
  (cd android && ./gradlew :app:testDebugUnitTest -q) || { echo "ОШИБКА: Kotlin-тесты красные"; exit 1; }
else
  echo "== Kotlin-тесты пропущены: android/ не менялась"
fi
echo "== ВСЁ ЗЕЛЁНОЕ. Время: $(( $(date +%s) - START )) с"
