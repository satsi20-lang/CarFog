#!/usr/bin/env bash
# Сборка релиза для серийных планшетов (arm64) с проверками.
#
#   tool/build_release.sh                 — боевая сборка (СИГНАЛ ЗДОРОВЬЯ ВСЕГДА ПИШЕТСЯ)
#   tool/build_release.sh --test-build    — ТЕСТОВАЯ сборка без сигнала здоровья
#                                           (SKIP_HEALTH_SIGNAL, для проверки отката)
#
# Защита от SKIP_HEALTH_SIGNAL: боевая сборка не принимает ни аргументов, ни
# переменных окружения, через которые флаг мог бы попасть в релиз; тестовая
# собирается ТОЛЬКО с явным --test-build и получает в имени файла метку TEST,
# чтобы её нельзя было спутать с боевой и загрузить в бакет по ошибке.
#
# Переменные (необязательные):
#   OUT_DIR       куда положить APK (по умолчанию ~)
#   CERT_SHA256   ожидаемый отпечаток сертификата подписи (по умолчанию —
#                 отпечаток релизного ключа проекта)
#   AAPT2, APKSIGNER  пути к инструментам (по умолчанию build-tools 36.0.0)
# Файлы ключа и пароли скрипт не читает: подпись делает gradle.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_BUILD=0
for a in "$@"; do
  case "$a" in
    --test-build) TEST_BUILD=1 ;;
    *) echo "ОШИБКА: неизвестный аргумент '$a'. Допустим только --test-build." >&2; exit 2 ;;
  esac
done

# Ни одна внешняя настройка не должна подмешать флаг в боевую сборку.
if [ "$TEST_BUILD" = "0" ]; then
  for v in DART_DEFINES FLUTTER_BUILD_ARGS SKIP_HEALTH_SIGNAL; do
    if [ -n "${!v:-}" ]; then
      echo "ОШИБКА: задана переменная $v — боевая сборка отказана." >&2; exit 3
    fi
  done
  if grep -rq "SKIP_HEALTH_SIGNAL" .dart_tool/package_config.json android/gradle.properties 2>/dev/null; then
    echo "ОШИБКА: SKIP_HEALTH_SIGNAL найден в настройках сборки." >&2; exit 3
  fi
fi

OUT_DIR="${OUT_DIR:-$HOME}"
CERT_SHA256="${CERT_SHA256:-225a34a381e1d6917a836712c2af8a89a51a9c24f622fca0fb768281394a8deb}"
BT="$HOME/Library/Android/sdk/build-tools/36.0.0"
AAPT2="${AAPT2:-$BT/aapt2}"
APKSIGNER="${APKSIGNER:-$BT/apksigner}"
APK=build/app/outputs/flutter-apk/app-release.apk
MAX_BYTES=$((45 * 1024 * 1024))   # выше 45 МБ — остановка (лимит хранилища 50 МБ)

VER_LINE=$(grep '^version:' pubspec.yaml | awk '{print $2}')
VNAME=${VER_LINE%+*}
VCODE=${VER_LINE#*+}

# Аппаратный профиль — единственный источник правды lib/models/hardware_profile.dart
# (свою копию не храним): версии с 1.8.0 собираются только под него.
HW_FILE=lib/models/hardware_profile.dart
HW_ID=$(sed -n "s/.*static const String id = '\([^']*\)';.*/\1/p" "$HW_FILE")
HW_NOTE=$(sed -n "s/.*static const String releaseNote = '\([^']*\)';.*/\1/p" "$HW_FILE")
[ -n "$HW_ID" ] && [ -n "$HW_NOTE" ] \
  || { echo "ОШИБКА: не прочитан профиль из $HW_FILE" >&2; exit 4; }

ARGS=(build apk --release --target-platform android-arm64)   # НЕ --split-per-abi: он меняет versionCode
if [ "$TEST_BUILD" = "1" ]; then
  echo "!!! ТЕСТОВАЯ СБОРКА: без сигнала здоровья, только для проверки отката !!!" >&2
  ARGS+=(--dart-define=SKIP_HEALTH_SIGNAL=true)
fi
flutter "${ARGS[@]}"

BADGING=$("$AAPT2" dump badging "$APK")
echo "$BADGING" | grep -q "^package: name='ee.carfog.dryfog' versionCode='$VCODE' versionName='$VNAME'" \
  || { echo "ОШИБКА: пакет/версия в APK не совпали с pubspec ($VER_LINE)" >&2; exit 4; }
echo "$BADGING" | grep -q "uses-permission: name='android.permission.INTERNET'" \
  || { echo "ОШИБКА: нет разрешения INTERNET" >&2; exit 4; }

# В lib/ только arm64-v8a; допустима единственная мелкая библиотека датастора
# в других ABI (приходит из зависимости, на arm64 не используется).
BAD=$(unzip -l "$APK" | awk '{print $4}' | grep '^lib/' | grep -v '^lib/arm64-v8a/' \
      | grep -v 'libdatastore_shared_counter.so' || true)
[ -z "$BAD" ] || { echo "ОШИБКА: лишние библиотеки в APK: $BAD" >&2; exit 4; }

CERT=$("$APKSIGNER" verify --print-certs "$APK" | grep 'certificate SHA-256 digest' | head -1 | awk '{print $NF}')
[ "$CERT" = "$CERT_SHA256" ] || { echo "ОШИБКА: отпечаток подписи $CERT не равен ожидаемому" >&2; exit 4; }

SIZE=$(stat -f%z "$APK" 2>/dev/null || stat -c%s "$APK")
[ "$SIZE" -lt "$MAX_BYTES" ] || { echo "ОШИБКА: размер $SIZE байт ≥ 45 МБ — остановка" >&2; exit 4; }

SHA=$(shasum -a 256 "$APK" | awk '{print $1}')
if [ "$TEST_BUILD" = "1" ]; then
  NAME="carfog-$VNAME-b$VCODE-TEST-${SHA:0:12}.apk"
else
  NAME="carfog-$VNAME-b$VCODE-${SHA:0:12}.apk"
fi
cp "$APK" "$OUT_DIR/$NAME"
# Примечание релиза рядом с файлом (имя APK не меняется: оно хэш-ориентировано).
{
  echo "$NAME"
  echo "версия $VNAME+$VCODE $HW_NOTE"
  echo "профиль: $HW_ID"
  [ "$TEST_BUILD" = "1" ] && echo "ТЕСТОВАЯ СБОРКА (без сигнала здоровья)"
  echo "sha256=$SHA"
} > "$OUT_DIR/$NAME.note.txt"
echo "ПРИМЕЧАНИЕ: версия $VNAME+$VCODE $HW_NOTE (профиль $HW_ID)"
echo "OK  $NAME  sha256=$SHA  size=$SIZE"
