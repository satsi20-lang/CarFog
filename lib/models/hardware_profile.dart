// Аппаратный профиль планшета — единственный источник правды (версии с 1.8.0
// собираются только под него; см. docs/hardware.md и docs/releases.md).
class HardwareProfile {
  HardwareProfile._();

  static const String id = 'sy156-a510';
  static const String title = 'Syoung SY156-A510, 15.6", 1080x1920, портрет';

  // Порт шины RS485 по умолчанию: ttyS4 (UART4) совпадает с надписью
  // «ttys4/RS485» у DB9. Какой узел выведен на белый 4-пиновый разъём,
  // ещё НЕ определено (проба на живой шине — отдельная задача), поэтому
  // порт — настройка (AppConfig.busPort), а не константа.
  static const String defaultBusPort = '/dev/ttyS4';

  static const int screenWidthPx = 1080;
  static const int screenHeightPx = 1920;
  static const int densityDpi = 240;
  // Логический размер в dp при density 240 (devicePixelRatio 1.5).
  static const double logicalWidthDp = 720;
  static const double logicalHeightDp = 1280;

  static const String orientation = 'portrait';

  // Метка для релизного примечания (tool/build_release.sh берёт её отсюда же,
  // не хранит свою копию).
  static const String releaseNote = 'для SY156-A510 (портрет)';
}
