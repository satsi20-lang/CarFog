// Лимиты удалённой диагностики (этап R1). Все числа этого блока — только
// здесь; пометка у каждого: ПОДТВЕРЖДЕНО (измерено/задано владельцем) или
// НЕ ИЗМЕРЕНО (разумная оценка, подлежит пересмотру по эксплуатации).

// ------------------------------------------------------------
// ПОСТОЯННЫЙ ЖУРНАЛ ПРИЛОЖЕНИЯ
// ------------------------------------------------------------
class AppLogLimits {
  AppLogLimits._();

  // Размер одного файла и число файлов (текущий + один предыдущий).
  // ЗАДАНО в задании (2 файла по 1 МБ).
  static const int maxFileBytes = 1024 * 1024;
  static const int fileCount = 2;

  // Как часто накопленные строки сбрасываются на диск. Запись идёт
  // асинхронно и пачкой, вне потока шины и UI. НЕ ИЗМЕРЕНО.
  static const Duration flushInterval = Duration(seconds: 1);

  // Предохранитель памяти: сколько строк ждёт записи максимум (при сбое
  // диска старые отбрасываются). НЕ ИЗМЕРЕНО.
  static const int maxPendingLines = 2000;

  // Максимальная длина одной строки журнала (длинные дампы режутся).
  // НЕ ИЗМЕРЕНО.
  static const int maxLineChars = 2000;
}

// ------------------------------------------------------------
// ПАКЕТ ДИАГНОСТИКИ
// ------------------------------------------------------------
class DiagnosticsLimits {
  DiagnosticsLimits._();

  // Хвосты, включаемые в пакет. ЗАДАНО в задании.
  static const int eventsTail = 100;
  static const int logTailLines = 300;

  // Размер одной части при отправке (символов JSON). Предел тела RPC
  // Supabase/PostgREST зависит от настроек проекта и не проверялся —
  // 128 КБ заведомо ниже типичных ограничений. НЕ ИЗМЕРЕНО.
  static const int chunkChars = 128 * 1024;

  // Пауза перед повторной отправкой отложенного пакета после отказа
  // сервера по квоте или токену (ответы 'quota' / 'auth'): это не сбой
  // связи, повтор раз в 30 с только долбил бы сервер. НЕ ИЗМЕРЕНО.
  static const Duration serverRefusalRetryPause = Duration(hours: 1);

  // Срок хранения пакетов на сервере (в миграции supabase/migrations).
  // НЕ ИЗМЕРЕНО, решает владелец.
  static const Duration serverRetention = Duration(days: 14);
}

// ------------------------------------------------------------
// УДАЛЁННЫЕ КОМАНДЫ
// ------------------------------------------------------------
class RemoteCommandLimits {
  RemoteCommandLimits._();

  // Срок действия команды с момента создания на сервере: старше —
  // не выполняется, ack 'expired'. Опрос идёт раз в 30 с, поэтому в норме
  // команда живёт секунды; запас на кратковременный обрыв связи.
  // НЕ ИЗМЕРЕНО, подлежит пересмотру.
  static const Duration maxAge = Duration(minutes: 10);

  // Лимит частоты для collect_diagnostics и restart_app (каждый свой):
  // не чаще раза в минуту и не более 3 в час. ЗАДАНО в задании.
  static const Duration minInterval = Duration(minutes: 1);
  static const int maxPerHour = 3;

  // Действия, которые БЕЗ created_at не выполняются вообще (ack
  // 'no_created_at'): без времени создания срок проверить нечем, а ошибка
  // или старый ответ сервера не должны превращаться в исполнение устаревшей
  // разрушительной команды. ЗАДАНО проверяющим (set_pin, update_config,
  // restart_app); factory_reset добавлен как самое разрушительное действие.
  // Безобидные (ping, collect_diagnostics, unlock, reset_session) без
  // created_at выполняются, с пометкой в журнале.
  static const Set<String> requireCreatedAt = {
    'set_pin',
    'update_config',
    'restart_app',
    'factory_reset',
    'update_app',
    'rollback_app',
  };

  // Сколько идентификаторов выполненных команд помнить (идемпотентность
  // по command_id, переживает перезапуск). НЕ ИЗМЕРЕНО.
  static const int seenIdsCapacity = 200;

  // Сколько последних команд показывать в сервисном меню. ЗАДАНО.
  static const int historyShown = 10;
}

// ------------------------------------------------------------
// ПРЕДЕЛЫ НАСТРОЕК (update_config из облака И локальный ввод в сервисном
// меню — один источник). Значение вне предела отклоняется ЦЕЛИКОМ.
// ------------------------------------------------------------
class ConfigLimits {
  ConfigLimits._();

  // Длительность обработки, с. ЗАДАНО владельцем, подлежит подтверждению.
  static const int treatmentDurationMinS = 10;
  static const int treatmentDurationMaxS = 120;

  // Цена, центов: от 50 центов до 20 €. ЗАДАНО владельцем, подлежит
  // подтверждению.
  static const int priceMinCents = 50;
  static const int priceMaxCents = 2000;

  // Продувка компрессора перед включением насосов/ТЭНа, с. Умолчание 10 с.
  // Верхний предел 60 с — ЗАДАНО владельцем 03.10.2026 (было 30 с по
  // оценке); нижний 1 с — как стоял в локальном вводе, подлежит
  // подтверждению.
  static const int compressorPurgeMinS = 1;
  static const int compressorPurgeMaxS = 60;

  // Работа насоса после ТЭНа (продувка в конце), с. Умолчание 5 с. Верхний
  // предел 60 с — ЗАДАНО владельцем 03.10.2026 (было 30 с по оценке);
  // нижний 1 с — как стоял в локальном вводе, подлежит подтверждению.
  static const int pumpAfterHeaterMinS = 1;
  static const int pumpAfterHeaterMaxS = 60;

  // Диапазон поля или null, если для поля пределов нет.
  static ({int min, int max})? range(String field) {
    switch (field) {
      case 'treatmentDurationS':
        return (min: treatmentDurationMinS, max: treatmentDurationMaxS);
      case 'treatmentPriceCents':
        return (min: priceMinCents, max: priceMaxCents);
      case 'compressorPurgeS':
        return (min: compressorPurgeMinS, max: compressorPurgeMaxS);
      case 'pumpAfterHeaterS':
        return (min: pumpAfterHeaterMinS, max: pumpAfterHeaterMaxS);
    }
    return null;
  }

  static const List<String> numericFields = [
    'treatmentDurationS',
    'treatmentPriceCents',
    'compressorPurgeS',
    'pumpAfterHeaterS',
  ];
}
