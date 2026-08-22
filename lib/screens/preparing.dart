import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../services/cloud_service.dart';
import '../services/modbus_service.dart';
import '../services/session_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'title': 'Прогрев...',
    'subtitle': 'Идёт нагрев испарителя, пожалуйста подождите',
    'hint1': '1. Вставьте шланг в приоткрытое окно автомобиля',
    'hint2': '2. Включите внутреннюю рециркуляцию воздуха',
    'hint3': '3. Закройте все двери и ожидайте снаружи',
    'hint4':
        '4. После завершения обработки насос ещё {s} сек будет распылять — не трогайте шланг',
    'target': 'Цель',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'Preheating...',
    'subtitle': 'Heating the evaporator, please wait',
    'hint1': '1. Insert the hose through a slightly open window',
    'hint2': '2. Turn on cabin air recirculation',
    'hint3': '3. Close all doors and wait outside',
    'hint4':
        '4. After treatment ends, the pump keeps spraying for {s} more sec — do not touch the hose',
    'target': 'Target',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'Eelsoojendus...',
    'subtitle': 'Aurusti soojenemine käib, palun oota',
    'hint1': '1. Sisesta voolik veidi avatud autoaknasse',
    'hint2': '2. Lülita sisse salongi õhu ringlus',
    'hint3': '3. Sulge kõik uksed ja oota väljas',
    'hint4':
        '4. Pärast töötluse lõppu pihustab pump veel {s} sek — ära puuduta voolikut',
    'target': 'Sihtmärk',
    'cancel': 'Tühista',
  },
};

class PreparingScreen extends StatefulWidget {
  const PreparingScreen({super.key});

  @override
  State<PreparingScreen> createState() => _PreparingScreenState();
}

class _PreparingScreenState extends State<PreparingScreen> {
  static const double _targetTemp = 225.0;
  // Аварийный потолок — сохранён из прежней (симулированной) версии этого
  // экрана. Без него реальный ТЭН, управляемый только по показаниям
  // термопары, не имеет верхнего предела на случай залипшего реле или
  // сбоя чтения.
  static const double _abortTemp = 240.0;
  static const int _maxDurationS = 600; // 10 минут

  // Термопарный модуль HLS-KWL-4TC физически отдаёт ~-500°C как код "нет
  // датчика" (см. комментарий про toShort() в ModbusChannel.kt) — любое
  // показание настолько ниже нуля недостижимо во время реального нагрева,
  // так же как и null (ошибка чтения с шины). Оба случая считаются
  // "плохим" чтением термопары (Шаг 33, задача 5.3).
  static const double _sensorFaultThreshold = -100.0;
  // ~15 секунд подряд плохих чтений (тик каждые 3 сек) — не самый первый
  // сбой (тот может быть помехой на шине), но и не ждём полные 10 минут
  // общего таймаута, откуда клиент раньше не получал никакого объяснения.
  static const int _sensorFailStreak = 5;

  double _currentTemp = 0.0;
  int _elapsedS = 0;
  int _badReadStreak = 0;
  Timer? _timer;

  // Не даёт таймеру среагировать ещё раз после того, как исход уже решён
  // (успех/таймаут/перегрев/отмена) — Timer.periodic может успеть
  // сработать повторно, пока идут await внутри предыдущего тика.
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(ModbusService.setHeater(true));
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    if (_finished) return;
    _elapsedS += 3;

    final temp = await ModbusService.readTemperature();
    if (!mounted || _finished) return;

    final sensorBad = temp == null || temp <= _sensorFaultThreshold;
    if (sensorBad) {
      _badReadStreak++;
      if (_badReadStreak >= _sensorFailStreak) {
        await _sensorFail(temp);
      }
      // Ещё не набрали streak — подождём следующих тиков, может помеха.
      return;
    }
    _badReadStreak = 0;
    setState(() => _currentTemp = temp);

    if (temp >= _abortTemp) {
      await _fail(
        errorCode: 'overheat',
        logCode: 'HEAT_OVERHEAT',
        sessionReason: 'overheat',
        hardwareErrorCode: 'overheat',
        tempC: temp,
      );
      return;
    }

    if (temp >= _targetTemp) {
      _finished = true;
      _timer?.cancel();
      if (!mounted) return;
      context.read<AppNotifier>().transition(AppState.compressorStartup);
      return;
    }

    if (_elapsedS >= _maxDurationS) {
      await _fail(
        errorCode: 'timeout',
        logCode: 'HEAT_TIMEOUT',
        sessionReason: 'timeout',
      );
    }
  }

  // errorCode — что показать клиенту на error.dart. sessionReason —
  // значение поля reason в session_complete (Шаг 33, задача 2.3).
  // hardwareErrorCode — если задан, дополнительно шлётся hardware_error
  // (Шаг 33, задача 5.2) с фактической температурой.
  Future<void> _fail({
    required String errorCode,
    required String logCode,
    required String sessionReason,
    String? hardwareErrorCode,
    double? tempC,
  }) async {
    _finished = true;
    _timer?.cancel();
    await ModbusService.setHeater(false);
    await _logError(logCode, 'temp=${_currentTemp.toStringAsFixed(1)}');
    if (hardwareErrorCode != null) {
      await CloudService.report(
        CloudEventType.hardwareError,
        data: {'code': hardwareErrorCode, 'temp_c': ?tempC},
      );
    }
    await SessionService.interrupt(sessionReason);
    if (!mounted) return;
    context.read<AppNotifier>().goToError(errorCode);
  }

  // Термопара молчит или устойчиво отдаёт код "нет датчика" — раньше это
  // приводило к обычному 'timeout' через все 10 минут без объяснения
  // причины (Шаг 33, задача 5.3). Теперь отдельная, более быстрая ветка:
  // сразу и hardware_error с кодом, и session_complete с reason 'sensor'.
  Future<void> _sensorFail(double? lastTemp) async {
    _finished = true;
    _timer?.cancel();
    await ModbusService.setHeater(false);
    await _logError(
      'HEAT_SENSOR_FAULT',
      'temp=${lastTemp?.toStringAsFixed(1) ?? "null"}',
    );
    await CloudService.report(
      CloudEventType.hardwareError,
      data: {'code': 'thermocouple_fault', 'temp_c': ?lastTemp},
    );
    await SessionService.interrupt('sensor');
    if (!mounted) return;
    context.read<AppNotifier>().goToError('sensor');
  }

  Future<void> _onCancel() async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    await ModbusService.setHeater(false);
    await _logError(
      'HEAT_USER_CANCEL',
      'temp=${_currentTemp.toStringAsFixed(1)}',
    );
    // Деньги уже внесены на payment.dart и не возвращаются монетоприёмником
    // — сессия должна остаться в отчёте, а не пропасть молча (Шаг 33,
    // задача 2, уточнено отдельно от исходного текста задания).
    await SessionService.interrupt('cancelled');
    if (!mounted) return;
    context.read<AppNotifier>().resetSession();
  }

  // Дописывает запись в JSON-массив под ключом "error_log" в
  // SharedPreferences, не перезаписывая уже накопленные записи.
  Future<void> _logError(String code, String detail) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('error_log');
      final List<dynamic> list = raw != null
          ? jsonDecode(raw) as List<dynamic>
          : <dynamic>[];
      list.add({
        'timestamp': DateTime.now().toIso8601String(),
        'code': code,
        'detail': detail,
      });
      await prefs.setString('error_log', jsonEncode(list));
    } catch (e) {
      debugPrint('PreparingScreen._logError error: $e');
    }
  }

  double get _progress => (_currentTemp / _targetTemp).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = i18n[lang]!;

    return Scaffold(
      body: FogBackground(
        // Тёплый акцент — идёт нагрев испарителя (Задача 1.4).
        accentColor: const Color(0xFFFFAA00),
        child: SafeArea(
          child: Row(
            children: [
              // Левая колонка: заголовок, температура, прогресс
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t['title']!,
                              style: const TextStyle(
                                color: Color(0xFFFFAA00),
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          LangSwitcher(
                            current: lang,
                            onChanged: notifier.setLanguage,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        t['subtitle']!,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 13,
                        ),
                      ),
                      const Spacer(),
                      Center(
                        child: Text(
                          '${_currentTemp.toStringAsFixed(0)}°C',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 72,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: 24,
                          backgroundColor: const Color(0xFF2E2E2E),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _progress > 0.9
                                ? Colors.redAccent
                                : const Color(0xFFFF3333),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          '${t['target']!} ${_targetTemp.toStringAsFixed(0)}°C',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: OutlinedButton(
                          onPressed: _onCancel,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF556677),
                            side: const BorderSide(color: Color(0xFF556677)),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(t['cancel']!),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              Container(width: 1, color: const Color(0xFF2E2E2E)),

              // Правая колонка: инструкции для клиента
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _HintRow(text: t['hint1']!),
                      const SizedBox(height: 16),
                      _HintRow(text: t['hint2']!),
                      const SizedBox(height: 16),
                      _HintRow(text: t['hint3']!),
                      const SizedBox(height: 16),
                      _HintRow(
                        text: t['hint4']!.replaceAll(
                          '{s}',
                          '${notifier.config.pumpAfterHeaterS}',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HintRow extends StatelessWidget {
  final String text;
  const _HintRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.arrow_right, color: Color(0xFF2EC4B6), size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
