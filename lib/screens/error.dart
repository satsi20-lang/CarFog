import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

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

  // Коды с отдельным текстом (error.<код>.title/detail в assets/i18n);
  // неизвестный код — generic.
  static const _knownCodes = {
    'overheat',
    'timeout',
    'sensor',
    'generic',
    // Без технических подробностей (ни слова про Modbus/RS485/шину):
    // клиенту нужно только понять, что платить не надо.
    'bus_unavailable',
    // "Отказ вместо недосчёта" — та же дисциплина.
    'coin_acceptor_unavailable',
    // Деньги приняты, ТЭН не дал мощности / отказ датчика температуры:
    // обработки не будет, деньги возвращает персонал.
    'heater_failure',
    'heater_sensor_fault',
  };

  String _t(String key, String lang, [String code = 'generic']) {
    if (key == 'title' || key == 'detail') {
      final c = _knownCodes.contains(code) ? code : 'generic';
      return I18n.tr(lang, 'error.$c.$key');
    }
    return I18n.tr(lang, 'error.$key', params: {'seconds': _secondsLeft});
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

    // "Шина недоступна" не возвращается сама по таймеру — неизвестно,
    // сколько продлится простой, а обратный отсчёт с истёкшим временем
    // выглядел бы так, будто аппарат вот-вот снова заработает. Возврат
    // происходит сам, когда AppNotifier.setBusHealthy(true) застанет
    // именно этот код ошибки (задача 4.5) — обычные ошибки (перегрев и
    // т.п.) по-прежнему возвращаются через 10 секунд.
    if (context.read<AppNotifier>().errorCode != 'bus_unavailable') {
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
      body: FogBackground(
        // Красный акцент — экран ошибки (Задача 1.4).
        accentColor: const Color(0xFFE53935),
        child: SafeArea(
          child: Stack(
            children: [
              // Lang switcher
              Positioned(
                top: 24,
                right: 24,
                child: LangSwitcher(
                  current: lang,
                  langs: notifier.displayLangs,
                  onChanged: notifier.setLanguage,
                ),
              ),

              // Невидимая зона долгого нажатия — вход в сервисное меню
              // (тот же жест, что и на заставке, standby.dart). Без
              // этого при 'bus_unavailable' техник не мог бы попасть в
              // "Диагностика" именно тогда, когда это нужнее всего —
              // экран ошибки не возвращается сам по таймеру, пока шина
              // не восстановится (см. initState), и без этого выхода
              // был бы заперт вместе с клиентом.
              Positioned(
                left: 0,
                top: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => context.read<AppNotifier>().transition(
                    AppState.servicePinEntry,
                  ),
                  child: const SizedBox(width: 80, height: 80),
                ),
              ),

              // Main content
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(PUi.gutter, 112, PUi.gutter, 24),
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
                          width: 240,
                          height: 240,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(
                              0xFFE53935,
                            ).withValues(alpha: 0.12),
                            border: Border.all(
                              color: const Color(0xFFE53935),
                              width: 4,
                            ),
                          ),
                          child: const Icon(
                            Icons.error_outline_rounded,
                            color: Color(0xFFE53935),
                            size: 144,
                          ),
                        ),
                      ),

                      const SizedBox(height: 48),

                      // Error title
                      Text(
                        _t('title', lang, code),
                        style: const TextStyle(
                          color: Color(0xFFE53935),
                          fontSize: 42,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 24),

                      // Error detail
                      Text(
                        _t('detail', lang, code),
                        style: const TextStyle(
                          color: Color(0xFF8899AA),
                          fontSize: PUi.bodySp + 2,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 20),

                      // Contact staff
                      Text(
                        _t('contact', lang),
                        style: const TextStyle(
                          color: Color(0xFF8899AA),
                          fontSize: PUi.minBodySp,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 64),

                      // Countdown — скрыт для 'bus_unavailable': возврат не
                      // по таймеру, а сам, когда шина восстановится (см.
                      // initState), обратный отсчёт с истёкшим временем
                      // здесь был бы враньём.
                      if (code != 'bus_unavailable')
                        Column(
                          children: [
                            Text(
                              _t('returning', lang),
                              style: const TextStyle(
                                color: Color(0xFF8899AA),
                                fontSize: PUi.minBodySp,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Container(
                              width: 96,
                              height: 96,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(
                                    0xFFE53935,
                                  ).withValues(alpha: 0.4),
                                  width: 2,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  _t('countdown', lang),
                                  style: const TextStyle(
                                    color: Color(0xFFE53935),
                                    fontSize: 32,
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
      ),
    );
  }
}
