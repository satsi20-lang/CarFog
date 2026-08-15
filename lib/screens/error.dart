import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/lang_switcher.dart';

class ErrorScreen extends StatefulWidget {
  const ErrorScreen({super.key});

  @override
  State<ErrorScreen> createState() => _ErrorScreenState();
}

class _ErrorScreenState extends State<ErrorScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;
  Timer? _countdownTimer;
  int _secondsLeft = 10;

  // Локализованные сообщения по коду ошибки
  static const _errorMessages = {
    'overheat': {
      'et': 'Ülekuumenemine',
      'en': 'Overheating',
      'ru': 'Перегрев',
    },
    'timeout': {
      'et': 'Soojenduse aeg ületatud',
      'en': 'Heating timeout',
      'ru': 'Таймаут нагрева',
    },
    'sensor': {
      'et': 'Anduri viga',
      'en': 'Sensor error',
      'ru': 'Ошибка датчика',
    },
    'generic': {
      'et': 'Süsteemiviga',
      'en': 'System error',
      'ru': 'Ошибка системы',
    },
  };

  static const _errorDetails = {
    'overheat': {
      'et': 'Temperatuur ületas 240°C. Seadmed on välja lülitatud.',
      'en': 'Temperature exceeded 240°C. All devices have been shut down.',
      'ru': 'Температура превысила 240°C. Все устройства отключены.',
    },
    'timeout': {
      'et': 'Seade ei saavutanud 225°C 600 sekundi jooksul.',
      'en': 'Device did not reach 225°C within 600 seconds.',
      'ru': 'Устройство не достигло 225°C за 600 секунд.',
    },
    'sensor': {
      'et': 'Temperatuuriandur ei anna signaali.',
      'en': 'Temperature sensor is not responding.',
      'ru': 'Датчик температуры не отвечает.',
    },
    'generic': {
      'et': 'Ilmnes tundmatu viga.',
      'en': 'An unexpected error occurred.',
      'ru': 'Возникла непредвиденная ошибка.',
    },
  };

  static const _labels = {
    'contact': {
      'et': 'Palun võtke ühendust teenindajaga.',
      'en': 'Please contact the service staff.',
      'ru': 'Обратитесь к обслуживающему персоналу.',
    },
    'returning': {
      'et': 'Naaseb algusesse',
      'en': 'Returning to start',
      'ru': 'Возврат к началу',
    },
    'sec': {'et': 's', 'en': 's', 'ru': 'с'},
  };

  String _t(String key, String lang, [String code = 'generic']) {
    if (key == 'title') return _errorMessages[code]?[lang] ?? _errorMessages['generic']![lang]!;
    if (key == 'detail') return _errorDetails[code]?[lang] ?? _errorDetails['generic']![lang]!;
    return _labels[key]?[lang] ?? '';
  }

  @override
  void initState() {
    super.initState();

    // Shake animation при появлении
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -12), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -12, end: 12), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 12, end: -8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8, end: 0), weight: 1),
    ]).animate(_shakeController);
    _shakeController.forward();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        timer.cancel();
        context.read<AppNotifier>().resetSession();
      }
    });
  }

  @override
  void dispose() {
    _shakeController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final code = notifier.errorCode ?? 'generic';

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Stack(
          children: [
            // Lang switcher
            Positioned(
              top: 16,
              right: 16,
              child: LangSwitcher(current: lang, onChanged: notifier.setLanguage),
            ),

            // Main content
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Shake + error icon
                    AnimatedBuilder(
                      animation: _shakeAnimation,
                      builder: (context, child) => Transform.translate(
                        offset: Offset(_shakeAnimation.value, 0),
                        child: child,
                      ),
                      child: Container(
                        width: 120,
                        height: 120,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFE53935).withValues(alpha: 0.12),
                          border: Border.all(
                            color: const Color(0xFFE53935),
                            width: 3,
                          ),
                        ),
                        child: const Icon(
                          Icons.error_outline_rounded,
                          color: Color(0xFFE53935),
                          size: 72,
                        ),
                      ),
                    ),

                    const SizedBox(height: 32),

                    // Error title
                    Text(
                      _t('title', lang, code),
                      style: const TextStyle(
                        color: Color(0xFFE53935),
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 16),

                    // Error detail
                    Text(
                      _t('detail', lang, code),
                      style: const TextStyle(
                        color: Color(0xFF8899AA),
                        fontSize: 15,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 12),

                    // Contact staff
                    Text(
                      _t('contact', lang),
                      style: const TextStyle(
                        color: Color(0xFF556677),
                        fontSize: 14,
                        height: 1.5,
                      ),
                      textAlign: TextAlign.center,
                    ),

                    const SizedBox(height: 48),

                    // Countdown
                    Column(
                      children: [
                        Text(
                          _t('returning', lang),
                          style: const TextStyle(
                            color: Color(0xFF556677),
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: const Color(0xFFE53935).withValues(alpha: 0.4),
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '$_secondsLeft${_t('sec', lang)}',
                              style: const TextStyle(
                                color: Color(0xFFE53935),
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
