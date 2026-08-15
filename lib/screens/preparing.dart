import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_state.dart';
import '../services/modbus_service.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'title': 'Прогрев...',
    'subtitle': 'Идёт нагрев испарителя, пожалуйста подождите',
    'hint1': '1. Вставьте шланг в приоткрытое окно автомобиля',
    'hint2': '2. Включите внутреннюю рециркуляцию воздуха',
    'hint3': '3. Закройте все двери и ожидайте снаружи',
    'hint4': '4. После завершения обработки насос ещё {s} сек будет распылять — не трогайте шланг',
    'target': 'Цель',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'Preheating...',
    'subtitle': 'Heating the evaporator, please wait',
    'hint1': '1. Insert the hose through a slightly open window',
    'hint2': '2. Turn on cabin air recirculation',
    'hint3': '3. Close all doors and wait outside',
    'hint4': '4. After treatment ends, the pump keeps spraying for {s} more sec — do not touch the hose',
    'target': 'Target',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'Eelsoojendus...',
    'subtitle': 'Aurusti soojenemine käib, palun oota',
    'hint1': '1. Sisesta voolik veidi avatud autoaknasse',
    'hint2': '2. Lülita sisse salongi õhu ringlus',
    'hint3': '3. Sulge kõik uksed ja oota väljas',
    'hint4': '4. Pärast töötluse lõppu pihustab pump veel {s} sek — ära puuduta voolikut',
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

  double _currentTemp = 0.0;
  int _elapsedS = 0;
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
    if (temp != null) {
      setState(() => _currentTemp = temp);
    }

    if (temp != null && temp >= _abortTemp) {
      await _fail(errorCode: 'overheat', logCode: 'HEAT_OVERHEAT');
      return;
    }

    if (temp != null && temp >= _targetTemp) {
      _finished = true;
      _timer?.cancel();
      if (!mounted) return;
      context.read<AppNotifier>().transition(AppState.compressorStartup);
      return;
    }

    if (_elapsedS >= _maxDurationS) {
      await _fail(errorCode: 'timeout', logCode: 'HEAT_TIMEOUT');
    }
  }

  Future<void> _fail({required String errorCode, required String logCode}) async {
    _finished = true;
    _timer?.cancel();
    await ModbusService.setHeater(false);
    await _logError(logCode, 'temp=${_currentTemp.toStringAsFixed(1)}');
    if (!mounted) return;
    context.read<AppNotifier>().goToError(errorCode);
  }

  Future<void> _onCancel() async {
    if (_finished) return;
    _finished = true;
    _timer?.cancel();
    await ModbusService.setHeater(false);
    await _logError('HEAT_USER_CANCEL', 'temp=${_currentTemp.toStringAsFixed(1)}');
    if (!mounted) return;
    context.read<AppNotifier>().resetSession();
  }

  // Дописывает запись в JSON-массив под ключом "error_log" в
  // SharedPreferences, не перезаписывая уже накопленные записи.
  Future<void> _logError(String code, String detail) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('error_log');
      final List<dynamic> list =
          raw != null ? jsonDecode(raw) as List<dynamic> : <dynamic>[];
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
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Заголовок + переключатель языка
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
                  LangSwitcher(current: lang, onChanged: notifier.setLanguage),
                ],
              ),

              const SizedBox(height: 8),
              Text(
                t['subtitle']!,
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),

              const SizedBox(height: 40),

              // Текущая температура крупно
              Text(
                '${_currentTemp.toStringAsFixed(0)}°C',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 80,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 16),

              // Прогресс-бар: 0 → _targetTemp
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  value: _progress,
                  minHeight: 28,
                  backgroundColor: const Color(0xFF2E2E2E),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _progress > 0.9
                        ? Colors.redAccent
                        : const Color(0xFFFF3333),
                  ),
                ),
              ),

              const SizedBox(height: 8),
              Text(
                '${t['target']!} ${_targetTemp.toStringAsFixed(0)}°C',
                style: const TextStyle(color: Colors.white54, fontSize: 13),
              ),

              const SizedBox(height: 40),

              // Инструкции для клиента
              _HintRow(text: t['hint1']!),
              const SizedBox(height: 12),
              _HintRow(text: t['hint2']!),
              const SizedBox(height: 12),
              _HintRow(text: t['hint3']!),
              const SizedBox(height: 12),
              _HintRow(
                text: t['hint4']!.replaceAll(
                    '{s}', '${notifier.config.pumpAfterHeaterS}'),
              ),

              const Spacer(),

              OutlinedButton(
                onPressed: _onCancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF556677),
                  side: const BorderSide(color: Color(0xFF556677)),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 40, vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(t['cancel']!),
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
