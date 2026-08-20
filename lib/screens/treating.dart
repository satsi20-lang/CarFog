import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/modbus_service.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'compressor_title': 'ЗАПУСК КОМПРЕССОРА',
    'compressor_sub': 'Пожалуйста, подождите',
    'treating_title': 'ИДЁТ ОБРАБОТКА САЛОНА',
    'treating_sub': 'Распыление аромата — дождитесь окончания процедуры',
    'warning_title': 'ФИНАЛ СЕССИИ!',
    'warning_sub': 'Готовьтесь забрать шланг',
    'shutdown_title': 'ЗАВЕРШЕНИЕ ПРОЦЕДУРЫ',
    'shutdown_sub': 'Продувка системы, пожалуйста подождите',
    'flavor': 'Аромат',
    'seconds': 'с',
  },
  'en': {
    'compressor_title': 'STARTING COMPRESSOR',
    'compressor_sub': 'Please wait',
    'treating_title': 'TREATING VEHICLE INTERIOR',
    'treating_sub': 'Fragrance is being sprayed — please wait',
    'warning_title': 'SESSION ENDING!',
    'warning_sub': 'Get ready to remove the hose',
    'shutdown_title': 'FINISHING UP',
    'shutdown_sub': 'Purging the system, please wait',
    'flavor': 'Fragrance',
    'seconds': 's',
  },
  'et': {
    'compressor_title': 'KOMPRESSORI KÄIVITAMINE',
    'compressor_sub': 'Palun oota',
    'treating_title': 'SALONGI TÖÖTLEMINE KÄIB',
    'treating_sub': 'Lõhna pihustamine käib — palun oota',
    'warning_title': 'SEANSS LÕPEB!',
    'warning_sub': 'Valmistu vooliku eemaldamiseks',
    'shutdown_title': 'LÕPETAMINE',
    'shutdown_sub': 'Süsteemi puhastamine, palun oota',
    'flavor': 'Lõhn',
    'seconds': 's',
  },
};

// Внутренние подэтапы одного экрана
enum _Phase { compressor, treating, shutdown }

class TreatingScreen extends StatefulWidget {
  const TreatingScreen({super.key});

  @override
  State<TreatingScreen> createState() => _TreatingScreenState();
}

class _TreatingScreenState extends State<TreatingScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.compressor;
  int _secondsLeft = 5; // компрессор — 5 сек
  Timer? _timer;
  bool _isBlinking = false;

  // Физическое мигание красной LED (реле DO11) на последних секундах —
  // отдельно от _blinkController, который отвечает только за анимацию фона.
  Timer? _ledBlinkTimer;
  bool _ledOn = false;

  // Термостат испарителя: поддерживает температуру в коридоре 225–235°C
  // на всё время экрана (компрессор/обработка/продувка), пока явно не
  // отменён — см. _nextPhase() (treating→shutdown) и dispose().
  Timer? _heaterTimer;
  double _currentTemp = 0.0;

  late AnimationController _blinkController;
  late Animation<Color?> _bgColorAnim;

  static const int _warningThreshold = 10;

  int get _treatmentDuration =>
      context.read<AppNotifier>().config.treatmentDurationS;
  int get _compressorDelay =>
      context.read<AppNotifier>().config.compressorPurgeS;
  int get _shutdownDelay =>
      context.read<AppNotifier>().config.pumpAfterHeaterS;
  int get _flavorIndex => context.read<AppNotifier>().selectedFlavor ?? 0;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _bgColorAnim = ColorTween(
      begin: const Color(0xFF1A1A1A),
      end: const Color(0xFFFF0000),
    ).animate(_blinkController);

    // Компрессор включаем сразу — пока идёт 5-секундный отсчёт набора
    // давления на экране, реле уже физически включено.
    unawaited(ModbusService.setCompressor(true));

    _startPhase(_Phase.compressor, _compressorDelay);

    _heaterTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final temp = await ModbusService.readTemperature();
      if (temp == null || !mounted) return;
      setState(() => _currentTemp = temp);
      if (temp < 225.0) {
        await ModbusService.setHeater(true);
      } else if (temp > 235.0) {
        await ModbusService.setHeater(false);
      }
    });
  }

  void _startPhase(_Phase phase, int seconds) {
    _timer?.cancel();
    setState(() {
      _phase = phase;
      _secondsLeft = seconds;
      _isBlinking = false;
    });
    _blinkController.stop();
    _blinkController.reset();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft--);

      // Мигание в конце TREATING
      if (_phase == _Phase.treating &&
          _secondsLeft <= _warningThreshold &&
          !_isBlinking) {
        setState(() => _isBlinking = true);
        _blinkController.repeat(reverse: true);
        _startRedBlink();
      }

      if (_secondsLeft <= 0) {
        _timer?.cancel();
        _nextPhase();
      }
    });
  }

  // Физическое мигание красной LED каждые 500мс, пока идёт предупреждение
  // об окончании сессии. Независимо от UI-анимации фона.
  void _startRedBlink() {
    _ledBlinkTimer?.cancel();
    _ledOn = false;
    _ledBlinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _ledOn = !_ledOn;
      unawaited(ModbusService.setLedRed(_ledOn));
    });
  }

  void _stopRedBlink() {
    _ledBlinkTimer?.cancel();
    _ledBlinkTimer = null;
  }

  Future<void> _nextPhase() async {
    switch (_phase) {
      case _Phase.compressor:
        // Компрессор прогрелся — запускаем насос выбранного аромата и
        // зелёную LED, затем переходим к отсчёту обработки.
        await ModbusService.setPump(_flavorIndex, true);
        await ModbusService.setLedGreen(true);
        if (!mounted) return;
        _startPhase(_Phase.treating, _treatmentDuration);
        break;
      case _Phase.treating:
        // Обработка завершена — насос+ТЭН+LED выкл, компрессор продувает.
        // Термостат отменяем ДО setHeater(false) — иначе он через 3 сек
        // снова включит ТЭН поверх этого явного выключения.
        _heaterTimer?.cancel();
        _stopRedBlink();
        _blinkController.stop();
        _blinkController.reset();
        await ModbusService.setPump(_flavorIndex, false);
        await ModbusService.setHeater(false); // на случай если был включён
        await ModbusService.setLedGreen(false);
        await ModbusService.setLedRed(false);
        if (!mounted) return;
        _startPhase(_Phase.shutdown, _shutdownDelay);
        break;
      case _Phase.shutdown:
        // Продувка завершена — компрессор выкл, финал
        await ModbusService.setCompressor(false);
        if (!mounted) return;
        context.read<AppNotifier>().transition(AppState.finished);
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _heaterTimer?.cancel();
    _stopRedBlink();
    _blinkController.dispose();
    // Аварийная гарантия: что бы ни случилось с экраном (уход, ошибка,
    // hot reload) — все выходы гарантированно выключаются.
    unawaited(ModbusService.safeAllOff());
    super.dispose();
  }

  double get _progress {
    int total;
    switch (_phase) {
      case _Phase.compressor:
        total = _compressorDelay;
        break;
      case _Phase.treating:
        total = _treatmentDuration;
        break;
      case _Phase.shutdown:
        total = _shutdownDelay;
        break;
    }
    final elapsed = total - _secondsLeft;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = i18n[lang]!;
    final flavorIndex = notifier.selectedFlavor ?? 0;
    final flavorName = notifier.config.flavorNames[lang]![flavorIndex];

    String title;
    String subtitle;
    Color titleColor;

    switch (_phase) {
      case _Phase.compressor:
        title = t['compressor_title']!;
        subtitle = t['compressor_sub']!;
        titleColor = const Color(0xFFFFAA00);
        break;
      case _Phase.treating:
        title = _isBlinking
            ? t['warning_title']!
            : t['treating_title']!;
        subtitle = _isBlinking
            ? t['warning_sub']!
            : t['treating_sub']!;
        titleColor = _isBlinking ? Colors.redAccent : const Color(0xFFFF3333);
        break;
      case _Phase.shutdown:
        title = t['shutdown_title']!;
        subtitle = t['shutdown_sub']!;
        titleColor = const Color(0xFFFFAA00);
        break;
    }

    return AnimatedBuilder(
      animation: _bgColorAnim,
      builder: (context, child) {
        return Scaffold(
          backgroundColor: _isBlinking
              ? _bgColorAnim.value
              : const Color(0xFF1A1A1A),
          body: SafeArea(
            child: Row(
              children: [
                // Левая колонка: заголовок, аромат, индикатор фаз
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
                                title,
                                style: TextStyle(
                                  color: titleColor,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            LangSwitcher(
                                current: lang, onChanged: notifier.setLanguage),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          subtitle,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 13),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '${t['flavor']!}: $flavorName',
                          style: const TextStyle(
                            color: Color(0xFF2EC4B6),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        // Индикатор текущей фазы
                        Row(
                          children: [
                            _PhaseIndicator(
                              active: _phase == _Phase.compressor,
                              done: _phase != _Phase.compressor,
                              label: '1',
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Container(
                                    height: 2, color: Colors.white24)),
                            const SizedBox(width: 8),
                            _PhaseIndicator(
                              active: _phase == _Phase.treating,
                              done: _phase == _Phase.shutdown,
                              label: '2',
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Container(
                                    height: 2, color: Colors.white24)),
                            const SizedBox(width: 8),
                            _PhaseIndicator(
                              active: _phase == _Phase.shutdown,
                              done: false,
                              label: '3',
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

                Container(width: 1, color: const Color(0xFF2E2E2E)),

                // Правая колонка: большой таймер + прогресс-бар
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '$_secondsLeft ${t['seconds']!}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 72,
                            fontWeight: FontWeight.bold,
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
                              _phase == _Phase.treating
                                  ? const Color(0xFFFF3333)
                                  : const Color(0xFF2EC4B6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PhaseIndicator extends StatelessWidget {
  final bool active;
  final bool done;
  final String label;

  const _PhaseIndicator({
    required this.active,
    required this.done,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    Color color;
    if (done) {
      color = const Color(0xFF2EC4B6);
    } else if (active) color = const Color(0xFFFF3333);
    else color = Colors.white24;

    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          done ? '✓' : label,
          style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16),
        ),
      ),
    );
  }
}
