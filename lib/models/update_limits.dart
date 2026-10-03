// Лимиты и параметры удалённого обновления (R2). Все числа — только здесь;
// пометка у каждого: ЗАДАНО (владельцем) или НЕ ИЗМЕРЕНО (оценка, подлежит
// пересмотру по эксплуатации).
class UpdateLimits {
  UpdateLimits._();

  // update_app / rollback_app: не чаще раза в 10 минут и 3 в сутки.
  // ЗАДАНО владельцем (значения «не измерено»).
  static const Duration commandMinInterval = Duration(minutes: 10);
  static const int commandsPerDay = 3;

  // Свободного места нужно не меньше N размеров APK (скачанный файл +
  // резервная копия + запас). ЗАДАНО владельцем: 3.
  static const int diskSpaceFactor = 3;

  // Сколько ждать сигнала здоровья новой версии, после чего откат.
  // ЗАДАНО владельцем: 5 минут (не измерено).
  static const Duration healthTimeout = Duration(minutes: 5);

  // su должен ответить за это время, иначе ack no_root. НЕ ИЗМЕРЕНО.
  static const Duration rootCheckTimeout = Duration(seconds: 5);

  // Запрос подписанной ссылки у Edge Function. НЕ ИЗМЕРЕНО.
  static const Duration urlRequestTimeout = Duration(seconds: 20);

  // Скачивание: общий предел и предел простоя (нет новых байт). НЕ ИЗМЕРЕНО
  // (APK ≈ 54 МБ на мобильной сети — до нескольких минут).
  static const Duration downloadTotalTimeout = Duration(minutes: 15);
  static const Duration downloadIdleTimeout = Duration(seconds: 60);

  // Верхний предел заявленного размера APK, байт: защита от записи сервера
  // с абсурдным размером. НЕ ИЗМЕРЕНО (релиз сейчас ≈ 54 МБ).
  static const int maxApkBytes = 250 * 1024 * 1024;

  // Как часто после запуска установочного скрипта читается его протокол и
  // как долго (если за это время ничего не произошло — скрипт не сработал,
  // блокировка оплаты снимается). НЕ ИЗМЕРЕНО.
  static const Duration protocolPollInterval = Duration(seconds: 5);
  static const Duration protocolWatchMax = Duration(minutes: 9);

  // Каталог внутри filesDir приложения и имена файлов обновления.
  static const String dirName = 'update';
  static const String newApkName = 'new.apk';
  static const String partialApkName = 'new.apk.part';
  static const String backupApkName = 'backup.apk';
  static const String backupInfoName = 'backup.json';
  static const String pendingName = 'pending.json';
  static const String protocolName = 'protocol.log';
  static const String healthName = 'health';
  static const String scriptName = 'update.sh';
}
