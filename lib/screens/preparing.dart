import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'title': 'ПОДГОТОВКА АППАРАТА',
    'subtitle': 'Идёт нагрев испарителя, пожалуйста подождите',
    'hint1': '1. Вставьте шланг в приоткрытое окно автомобиля',
    'hint2': '2. Включите внутреннюю рециркуляцию воздуха',
    'hint3': '3. Закройте все двери и ожидайте снаружи',
    'hint4': '4. После завершения обработки насос ещё {s} сек будет распылять — не трогайте шланг',
    'temp': 'Температура испарителя',
    'target': 'Цель',
  },
  'en': {
    'title': 'PREPARING THE MACHINE',
    'subtitle': 'Heating the evaporator, please wait',
    'hint1': '1. Insert the hose through a slightly open window',
    'hint2': '2. Turn on cabin air recirculation',
    'hint3': '3. Close all doors and wait outside',
    'hint4': '4. After treatment ends, the pump keeps spraying for {s} more sec — do not touch the hose',
    'temp': 'Evaporator temperature',
    'target': 'Target',
  },
  'et': {
    'title': 'SEADME ETTEVALMISTAMINE',
    'subtitle': 'Aurusti soojenemine käib, palun oota',
    'hint1': '1. Sisesta voolik veidi avatud autoaknasse',
    'hint2': '2. Lülita sisse salongi õhu ringlus',
    'hint3': '3. Sulge kõik uksed ja oota väljas',
    'hint4': '4. Pärast töötluse lõppu pihustab pump veel {s} sek — ära puuduta voolikut',
    'temp': 'Aurusti temperatuur',
    'target': 'Sihtmärk',
  },
};

class PreparingScreen extends StatefulWidget {
  const PreparingScreen({super.key});

  @override
  State<PreparingScreen> createState() => _PreparingScreenState();
}

class _PreparingScreenState extends State<PreparingScreen> {
  // --- Симуляция нагрева (как в Python-версии) ---
  double _currentTemp = 20.0;
  double _startTemp = 20.0;
  static const double _targetTemp = 220.0;
  static const double _heatRate = 15.0; // °C/сек в режиме эмуляции
  static const double _abortTemp = 240.0;
  static const int _maxDurationS = 180;

  Timer? _timer;
  int _elapsedS = 0;
  DateTime? _startTime;

  @override
  void initState() {
    super.initState();
    _startTemp = _currentTemp;
    _startTime = DateTime.now();
    _startHeating();
  }

  void _startHeating() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;

      setState(() {
        // Симуляция нагрева — заменится реальным чтением термопары
        // через Modbus (Блок №2) на следующем этапе интеграции железа
        _currentTemp = (_currentTemp + _heatRate).clamp(0, _targetTemp + 5);
        _elapsedS++;
      });

      // Аварийный потолок
      if (_currentTemp >= _abortTemp) {
        _timer?.cancel();
        context.read<AppNotifier>().goToError('overheat');
        return;
      }

      // Таймаут (не достигли цели за 3 минуты)
      if (_elapsedS >= _maxDurationS) {
        _timer?.cancel();
        context.read<AppNotifier>().goToError('timeout');
        return;
      }

      // Достигли 100% — переходим к запуску компрессора
      if (_currentTemp >= _targetTemp) {
        _timer?.cancel();
        context.read<AppNotifier>().transition(AppState.compressorStartup);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  double get _progress {
    final span = _targetTemp - _startTemp;
    if (span <= 0) return 1.0;
    return ((_currentTemp - _startTemp) / span).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = i18n[lang]!;
    final percent = (_progress * 100).toStringAsFixed(0);

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

              // Большой процент
              Text(
                '$percent %',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 80,
                  fontWeight: FontWeight.bold,
                ),
              ),

              const SizedBox(height: 16),

              // Прогресс-бар
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

              const SizedBox(height: 16),

              // Температура
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${t['temp']!}: ${_currentTemp.toStringAsFixed(1)}°C',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  Text(
                    '${t['target']!}: ${_targetTemp.toStringAsFixed(0)}°C',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                ],
              ),

              const SizedBox(height: 48),

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
