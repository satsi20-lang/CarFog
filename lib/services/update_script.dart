// Установочный скрипт и разбор его протокола (R2).
//
// Установка `pm install -r` заменяет само приложение и УБИВАЕТ его процесс,
// поэтому установку и всё, что идёт после неё, делает отдельный корневой
// скрипт (запускается через su в отдельной сессии и переживает смерть
// приложения), а не код приложения. Скрипт пишет протокол в файл; приложение
// читает его при старте и отправляет в журнал и в событие.
//
// Аргументы (позиционные, без подстановки в текст скрипта — так значения не
// могут «выйти» из кавычек):
//   1 MODE        install | rollback
//   2 PKG         имя пакета
//   3 APK         новый APK (для install)
//   4 BACKUP      резервная копия текущего APK
//   5 CODE        versionCode, который ожидается после установки
//   6 HEALTH      файл здоровья (его пишет новая версия)
//   7 LOG         протокол
//   8 ALIAS       полное имя класса алиаса киоска (в namespace, НЕ в пакете) (для возврата роли домашнего экрана)
//   9 ACTIVITY    полное имя класса главной активности (в namespace)
//  10 KIOSK       1 — киоск был включён, вернуть роль после установки
//  11 TIMEOUT_S   сколько ждать сигнала здоровья
const String updateScriptText = r'''#!/system/bin/sh
MODE="$1"; PKG="$2"; APK="$3"; BACKUP="$4"; CODE="$5"; HEALTH="$6"; LOG="$7"
ALIAS="$8"; ACT="$9"; KIOSK="${10}"; TIMEOUT="${11}"

log() { echo "$(date +%s) $*" >> "$LOG"; }
first_line() { echo "$1" | head -n 1; }

# Каталог обновления создан приложением (его uid), а файлы в нём пишет root:
# в конце (любой выход) вернуть владельца и контекст SELinux, иначе приложение
# не прочитает протокол и не удалит резерв.
DIR=$(dirname "$LOG")
OWNER=$(stat -c %u:%g "$DIR" 2> /dev/null)
fix_owner() {
  [ -n "$OWNER" ] && chown -R "$OWNER" "$DIR" 2> /dev/null
  restorecon -R "$DIR" > /dev/null 2>&1
  log "owner_fixed owner=${OWNER:-unknown} $(ls -ldZ "$DIR" 2> /dev/null | tr -s ' ' | head -n 1)"
}
trap fix_owner EXIT

# Диагностика: в каком cgroup и контексте работает скрипт и от кого он
# запущен. pm install убивает процесс приложения вместе с его cgroup; если
# скрипт окажется там же, он умрёт посреди установки (по протоколу видно).
log "diag pid=$$ ppid=$PPID uid=$(id -u) ctx=$(id -Z 2> /dev/null) cgroup=$(tr '\n' ';' < /proc/$$/cgroup 2> /dev/null)"

# ВЫЖИВАНИЕ. Скрипт запускается из процесса приложения и наследует его cgroup
# (uid_<uid>/pid_<pid>). При замене пакета система убивает эту cgroup целиком —
# вместе со скриптом, посреди pm install (проверено на планшете: протокол
# обрывался на backup_ok). Поэтому до установки скрипт переносит себя в корень
# cgroup2 и ПРОВЕРЯЕТ по /proc/self/cgroup, что вышел. Не вышел (нет прав на
# cgroup.procs, нет cgroup2, другое ядро/SELinux) — безопасный отказ no_survive,
# установка не начинается, приложение остаётся прежним.
# CG_SELF/CG_MOUNTS — только для тестов на компьютере.
CGSELF="${CG_SELF:-/proc/self/cgroup}"
CGMOUNTS="${CG_MOUNTS:-/proc/mounts}"
APPUID="${OWNER%%:*}"
in_app_cgroup() { grep -Eq "/uid_${APPUID}(/|\$)" "$CGSELF" 2> /dev/null; }
CGROOT=$(grep ' cgroup2 ' "$CGMOUNTS" 2> /dev/null | head -n 1 | cut -d' ' -f2)
if [ -n "$APPUID" ] && in_app_cgroup && [ -n "$CGROOT" ]; then
  echo $$ > "$CGROOT/cgroup.procs" 2> /dev/null
fi
if [ -z "$APPUID" ] || in_app_cgroup; then
  log "no_survive root=${CGROOT:-none} uid=${APPUID:-unknown} cgroup=$(tr '\n' ';' < "$CGSELF" 2> /dev/null)"
  exit 15
fi
log "survive_ok cgroup=$(tr '\n' ';' < "$CGSELF" 2> /dev/null)"

# Android сбрасывает роль домашнего экрана при замене пакета: вернуть её (если
# киоск был включён) и запустить приложение (root может стартовать активность
# из фона, в отличие от самого приложения).
restore_and_start() {
  if [ "$KIOSK" = "1" ]; then
    pm enable "$PKG/$ALIAS" > /dev/null 2>&1
    log "alias_enabled"
    cmd role add-role-holder --user 0 android.app.role.HOME "$PKG" > /dev/null 2>&1
    log "kiosk_role_restored"
  fi
  am start -n "$PKG/$ACT" > /dev/null 2>&1
  log "started"
}

rollback() {
  log "rollback_start"
  OUT=$(pm install -r -d "$BACKUP" 2>&1)
  case "$OUT" in
    *Success*) log "rollback_ok"; restore_and_start; return 0 ;;
    *) log "rollback_failed $(first_line "$OUT")"; return 1 ;;
  esac
}

log "start mode=$MODE target=$CODE"
rm -f "$HEALTH"

if [ "$MODE" = "install" ]; then
  OLD=$(pm path "$PKG" | head -n 1 | sed 's/^package://')
  if [ -z "$OLD" ] || ! cp "$OLD" "$BACKUP"; then
    log "backup_failed"
    exit 11
  fi
  chmod 644 "$BACKUP" 2> /dev/null
  log "backup_ok"
  OUT=$(pm install -r "$APK" 2>&1)
  case "$OUT" in
    *Success*) log "install_ok"; INSTALLED=1 ;;
    *) log "install_failed $(first_line "$OUT")"; exit 12 ;;
  esac
elif [ "$MODE" = "rollback" ]; then
  OUT=$(pm install -r -d "$BACKUP" 2>&1)
  case "$OUT" in
    *Success*) log "rollback_ok" ;;
    *) log "rollback_failed $(first_line "$OUT")"; exit 13 ;;
  esac
else
  log "bad_mode"
  exit 10
fi

restore_and_start

# Ждём подтверждения здоровья от НОВОЙ версии ("ok <versionCode>").
i=0
while [ "$i" -lt "$TIMEOUT" ]; do
  if [ -f "$HEALTH" ] && grep -q "^ok $CODE\$" "$HEALTH" 2> /dev/null; then
    log "health_ok"
    rm -f "$APK" 2> /dev/null && log "cleanup_ok"
    exit 0
  fi
  sleep 2
  i=$((i + 2))
done

if [ "$MODE" = "install" ]; then
  log "health_timeout"
  rollback && exit 0
  exit 14
fi
log "health_timeout_after_rollback"
exit 0
''';

// Команда «починки» для нового приложения, если скрипт не дошёл до конца
// (в протоколе нет owner_fixed): вернуть владельца и контекст каталога update,
// включить алиас и вернуть роль домашнего экрана. Всё идемпотентно.
String shQuote(String s) => "'${s.replaceAll("'", "'\\''")}'";

String buildRepairCommand({
  required String dir,
  required String packageName,
  required String aliasClass,
  required bool kiosk,
}) {
  final d = shQuote(dir);
  final b = StringBuffer()
    ..write('chown -R "\$(stat -c %u:%g $d)" $d; ')
    ..write('restorecon -R $d > /dev/null 2>&1; ');
  if (kiosk) {
    b
      ..write('pm enable ${shQuote('$packageName/$aliasClass')} > /dev/null 2>&1; ')
      ..write('cmd role add-role-holder --user 0 android.app.role.HOME ${shQuote(packageName)} > /dev/null 2>&1; ');
  }
  b.write('echo repaired');
  return b.toString();
}

// ---------------------------------------------------------------------------
// Разбор протокола скрипта
// ---------------------------------------------------------------------------

enum UpdateOutcome {
  // новая версия подтвердила здоровье (health_ok)
  installed,
  // установка не удалась (install_failed / backup_failed), старая версия цела
  failed,
  // здоровья не было, поставлена резервная версия (rollback_ok)
  rolledBack,
  // откат тоже не удался (rollback_failed)
  rollbackFailed,
  // скрипт ещё работает / протокол пуст
  inProgress,
}

class ProtocolSummary {
  final UpdateOutcome outcome;
  final String? detail; // причина (первая строка вывода pm)
  final List<String> events;
  final int? startedAtS;
  final int? finishedAtS;

  const ProtocolSummary(
    this.outcome,
    this.events, {
    this.detail,
    this.startedAtS,
    this.finishedAtS,
  });

  int? get durationS => (startedAtS != null && finishedAtS != null)
      ? finishedAtS! - startedAtS!
      : null;
}

class UpdateProtocol {
  UpdateProtocol._();

  // Строки вида "<unix-время> <событие> [подробности]".
  static ProtocolSummary parse(String text) {
    final events = <String>[];
    int? started;
    int? finished;
    String? detail;
    var outcome = UpdateOutcome.inProgress;
    for (final raw in text.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final sp = line.indexOf(' ');
      if (sp <= 0) continue;
      final ts = int.tryParse(line.substring(0, sp));
      if (ts == null) continue; // строка без метки времени — не наша
      final rest = line.substring(sp + 1).trim();
      final name = rest.split(' ').first;
      final extra = rest.length > name.length ? rest.substring(name.length).trim() : null;
      events.add(name);
      if (name == 'start') started ??= ts;
      switch (name) {
        case 'health_ok':
          outcome = UpdateOutcome.installed;
          finished = ts;
          break;
        case 'install_failed':
        case 'backup_failed':
        case 'no_survive':
        case 'bad_mode':
          outcome = UpdateOutcome.failed;
          detail = extra ?? name;
          finished = ts;
          break;
        case 'rollback_ok':
          // откат после неудачи: итог "откатились" (даже если health_ok был бы
          // для ручного отката — там нет health_timeout)
          if (outcome != UpdateOutcome.installed) outcome = UpdateOutcome.rolledBack;
          finished = ts;
          break;
        case 'rollback_failed':
          outcome = UpdateOutcome.rollbackFailed;
          detail = extra ?? name;
          finished = ts;
          break;
        case 'health_timeout':
          detail ??= 'health_timeout';
          break;
      }
    }
    return ProtocolSummary(
      outcome,
      events,
      detail: detail,
      startedAtS: started,
      finishedAtS: finished,
    );
  }
}
