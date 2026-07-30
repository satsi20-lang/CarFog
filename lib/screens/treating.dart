import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/lang_switcher.dart';

const Map<String, List<String>> flavorNames = {
  'ru': ['Лимон','Вишня','Хвоя','Лаванда','Океан','Кофе','Ваниль','Мята'],
  'en': ['Lemon','Cherry','Pine','Lavender','Ocean','Coffee','Vanilla','Mint'],
  'et': ['Sidrun','Kirss','Mänd','Lavendel','Ookean','Kohv','Vanilje','Münt'],
};

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

  late AnimationController _blinkController;
  late Animation<Color?> _bgColorAnim;

  static const int _warningThreshold = 10;

  int get _treatmentDuration =>
      context.read<AppNotifier>().config.treatmentDurationS;
  int get _compressorDelay =>
      context.read<AppNotifier>().config.compressorPurgeS;
  int get _shutdownDelay =>
      context.read<AppNotifier>().config.pumpAfterHeaterS;

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

    _startPhase(_Phase.compressor, _compressorDelay);
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
      }

      if (_secondsLeft <= 0) {
        _timer?.cancel();
        _nextPhase();
      }
    });
  }

  void _nextPhase() {
    switch (_phase) {
      case _Phase.compressor:
        // Компрессор прогрелся — запускаем насос и обработку
        _startPhase(_Phase.treating, _treatmentDuration);
        break;
      case _Phase.treating:
        // Обработка завершена — насос+ТЭН выкл, компрессор продувает
        _blinkController.stop();
        _blinkController.reset();
        _startPhase(_Phase.shutdown, _shutdownDelay);
        break;
      case _Phase.shutdown:
        // Продувка завершена — финал
        context.read<AppNotifier>().transition(AppState.finished);
        break;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _blinkController.dispose();
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
    final flavorName = flavorNames[lang]![flavorIndex];

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
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Заголовок + язык
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
                      LangSwitcher(current: lang, onChanged: notifier.setLanguage),
                    ],
                  ),

                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 13),
                  ),

                  const SizedBox(height: 8),

                  // Аромат
                  Text(
                    '${t['flavor']!}: $flavorName',
                    style: const TextStyle(
                      color: Color(0xFF2EC4B6),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Большой таймер
                  Text(
                    '$_secondsLeft ${t['seconds']!}',
                    style: TextStyle(
                      color: _isBlinking ? Colors.white : Colors.white,
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
                        _phase == _Phase.treating
                            ? const Color(0xFFFF3333)
                            : const Color(0xFF2EC4B6),
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Индикатор текущей фазы
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _PhaseIndicator(
                        active: _phase == _Phase.compressor,
                        done: _phase != _Phase.compressor,
                        label: '1',
                      ),
                      const SizedBox(width: 8),
                      Container(
                          height: 2, width: 40,
                          color: Colors.white24),
                      const SizedBox(width: 8),
                      _PhaseIndicator(
                        active: _phase == _Phase.treating,
                        done: _phase == _Phase.shutdown,
                        label: '2',
                      ),
                      const SizedBox(width: 8),
                      Container(
                          height: 2, width: 40,
                          color: Colors.white24),
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
