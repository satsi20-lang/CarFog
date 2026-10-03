import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../services/cloud_service.dart';
import '../../services/pin_policy.dart';
import '../../services/security_service.dart';
import '../../widgets/lang_switcher.dart';

enum _Mode { pin, master, newPin }

class ServicePinScreen extends StatefulWidget {
  const ServicePinScreen({super.key});

  @override
  State<ServicePinScreen> createState() => _ServicePinScreenState();
}

class _ServicePinScreenState extends State<ServicePinScreen>
    with SingleTickerProviderStateMixin {
  _Mode _mode = _Mode.pin;
  String _entered = '';
  // Установка нового PIN: шаг 0 — ввод, шаг 1 — повтор. Включается
  // принудительно: после входа с начальным/слабым PIN и после успешного
  // ввода мастер-кода.
  int _newPinStep = 0;
  String _firstPin = '';
  bool _viaMaster = false;
  int _attemptsLeft = SecurityService.maxAttempts;
  Duration _lockLeft = Duration.zero;
  Timer? _ticker;

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  int get _maxLen => _mode == _Mode.master ? 8 : 4;
  bool get _isLocked => _lockLeft > Duration.zero;

  static const _labels = {
    'title_pin': {
      'et': 'Sisesta PIN',
      'en': 'Enter PIN',
      'ru': 'Введите PIN',
    },
    'title_master': {
      'et': 'Avariikood',
      'en': 'Emergency code',
      'ru': 'Аварийный код',
    },
    'attempts': {
      'et': 'Katseid jäänud',
      'en': 'Attempts left',
      'ru': 'Осталось попыток',
    },
    'locked_title': {
      'et': 'Juurdepääs blokeeritud',
      'en': 'Access locked',
      'ru': 'Доступ заблокирован',
    },
    'locked_sub': {
      'et': 'Proovi uuesti pärast',
      'en': 'Try again in',
      'ru': 'Повторите через',
    },
    'master_link': {
      'et': 'Avariijuurdepääs',
      'en': 'Emergency access',
      'ru': 'Аварийный доступ',
    },
    'master_hint': {
      'et': 'Sisesta 8-kohaline avariikood',
      'en': 'Enter the 8-digit emergency code',
      'ru': 'Введите 8-значный аварийный код',
    },
    'back': {'et': 'Tagasi', 'en': 'Back', 'ru': 'Назад'},
    'cancel': {'et': 'Tühista', 'en': 'Cancel', 'ru': 'Отмена'},
    'title_new_pin': {
      'et': 'Uus PIN',
      'en': 'New PIN',
      'ru': 'Новый PIN',
    },
    'title_confirm_pin': {
      'et': 'Korda PIN-i',
      'en': 'Repeat the PIN',
      'ru': 'Повторите PIN',
    },
    'new_pin_hint': {
      'et': 'Määra uus 4-kohaline PIN (mitte 1234 ega lihtne muster)',
      'en': 'Set a new 4-digit PIN (not 1234 or a simple pattern)',
      'ru': 'Задайте новый PIN из 4 цифр (не 1234 и не простой)',
    },
    'pin_weak': {
      'et': 'PIN on liiga lihtne (samad numbrid, järjestus, 1234 jms)',
      'en': 'PIN is too simple (same digits, sequence, 1234, etc.)',
      'ru': 'PIN слишком простой (одинаковые цифры, подряд, 1234 и т.п.)',
    },
    'pin_mismatch': {
      'et': 'PIN-id ei kattu, proovi uuesti',
      'en': 'PINs do not match, try again',
      'ru': 'PIN не совпали, попробуйте снова',
    },
    'pin_saved': {
      'et': 'Uus PIN salvestatud',
      'en': 'New PIN saved',
      'ru': 'Новый PIN сохранён',
    },
    'wrong_master': {
      'et': 'Vale avariikood',
      'en': 'Wrong emergency code',
      'ru': 'Неверный аварийный код',
    },
  };

  String _t(String key, String lang) => _labels[key]?[lang] ?? '';

  @override
  void initState() {
    super.initState();

    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10, end: -6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6, end: 0), weight: 1),
    ]).animate(_shakeController);

    _refresh();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _shakeController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final left = await SecurityService.remainingLock();
    final attempts = await SecurityService.attemptsLeft();
    if (!mounted) return;
    setState(() {
      _lockLeft = left;
      _attemptsLeft = attempts;
    });
  }

  void _onDigit(String d) {
    if (_mode != _Mode.newPin && _isLocked) return;
    if (_entered.length >= _maxLen) return;
    setState(() => _entered += d);
    if (_entered.length == _maxLen) _check();
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _fail() {
    _shakeController.forward(from: 0).then((_) {
      if (mounted) setState(() => _entered = '');
    });
  }

  Future<void> _check() async {
    final notifier = context.read<AppNotifier>();

    if (_mode == _Mode.newPin) {
      await _checkNewPin(notifier);
      return;
    }

    if (_mode == _Mode.master) {
      // Та же блокировка, что и у PIN (3 попытки, 20 минут).
      final r = await SecurityService.tryMaster(_entered);
      if (!mounted) return;
      switch (r) {
        case PinResult.ok:
          // Мастер-код открывает ТОЛЬКО принудительную смену PIN, а не
          // сброс к заводским, как раньше.
          _beginNewPin(viaMaster: true);
          break;
        case PinResult.wrong:
          _fail();
          _snack(_t('wrong_master', notifier.lang));
          await _refresh();
          break;
        case PinResult.locked:
          _fail();
          await _refresh();
          break;
      }
      return;
    }

    final result = await SecurityService.tryPin(
      _entered,
      notifier.config.servicePin,
    );
    if (!mounted) return;

    switch (result) {
      case PinResult.ok:
        // Начальный (1234) или слабый PIN: в меню — только после смены.
        if (PinPolicy.isWeak(notifier.config.servicePin)) {
          _beginNewPin(viaMaster: false);
        } else {
          notifier.transition(AppState.serviceMenu);
        }
        break;
      case PinResult.wrong:
        _fail();
        await _refresh();
        break;
      case PinResult.locked:
        _fail();
        await _refresh();
        break;
    }
  }

  void _beginNewPin({required bool viaMaster}) {
    setState(() {
      _mode = _Mode.newPin;
      _newPinStep = 0;
      _firstPin = '';
      _entered = '';
      _viaMaster = viaMaster;
    });
  }

  Future<void> _checkNewPin(AppNotifier notifier) async {
    final lang = notifier.lang;
    if (_newPinStep == 0) {
      if (PinPolicy.isWeak(_entered)) {
        _fail();
        _snack(_t('pin_weak', lang));
        return;
      }
      setState(() {
        _firstPin = _entered;
        _entered = '';
        _newPinStep = 1;
      });
      return;
    }
    if (_entered != _firstPin) {
      _fail();
      _snack(_t('pin_mismatch', lang));
      setState(() {
        _newPinStep = 0;
        _firstPin = '';
      });
      return;
    }
    await notifier.saveConfig(notifier.config.copyWith(servicePin: _entered));
    await SecurityService.resetAttempts();
    // В событие идёт только факт смены и способ входа, не сам PIN.
    await CloudService.report(
      CloudEventType.configChanged,
      data: {'what': 'service_pin', 'via_master_code': _viaMaster},
    );
    if (!mounted) return;
    _snack(_t('pin_saved', lang));
    notifier.transition(AppState.serviceMenu);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final blocked = _mode != _Mode.newPin && _isLocked;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Row(
          children: [
            // Левая колонка: статус/заголовок, переключение режима, отмена
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LangSwitcher(current: lang, onChanged: notifier.setLanguage),
                    const Spacer(),
                    Text(
                      blocked
                          ? _t('locked_title', lang)
                          : _mode == _Mode.pin
                              ? _t('title_pin', lang)
                              : _mode == _Mode.master
                              ? _t('title_master', lang)
                              : (_newPinStep == 0
                                    ? _t('title_new_pin', lang)
                                    : _t('title_confirm_pin', lang)),
                      style: TextStyle(
                        color: blocked ? const Color(0xFFE53935) : Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (blocked)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _t('locked_sub', lang),
                            style: const TextStyle(
                              color: Color(0xFF8899AA),
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _formatDuration(_lockLeft),
                            style: const TextStyle(
                              color: Color(0xFFE53935),
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      )
                    else if (_mode == _Mode.newPin)
                      Text(
                        _t('new_pin_hint', lang),
                        style: const TextStyle(
                          color: Color(0xFFFFAA00),
                          fontSize: 13,
                        ),
                      )
                    else if (_mode == _Mode.master)
                      Text(
                        _t('master_hint', lang),
                        style: const TextStyle(
                          color: Color(0xFF8899AA),
                          fontSize: 13,
                        ),
                      )
                    else
                      _AttemptsIndicator(
                        label: _t('attempts', lang),
                        left: _attemptsLeft,
                        total: SecurityService.maxAttempts,
                        alignStart: true,
                      ),
                    const Spacer(),
                    if (_mode == _Mode.pin)
                      TextButton(
                        onPressed: () => setState(() {
                          _mode = _Mode.master;
                          _entered = '';
                        }),
                        child: Text(
                          _t('master_link', lang),
                          style: const TextStyle(
                            color: Color(0xFF00C6B2),
                            fontSize: 14,
                          ),
                        ),
                      )
                    else if (_mode == _Mode.master)
                      TextButton(
                        onPressed: () => setState(() {
                          _mode = _Mode.pin;
                          _entered = '';
                        }),
                        child: Text(
                          _t('back', lang),
                          style: const TextStyle(
                            color: Color(0xFF00C6B2),
                            fontSize: 14,
                          ),
                        ),
                      ),
                    TextButton(
                      onPressed: () => notifier.transition(AppState.standby),
                      child: Text(
                        _t('cancel', lang),
                        style: const TextStyle(
                          color: Color(0xFF556677),
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            Container(width: 1, color: const Color(0xFF1A2233)),

            // Правая колонка: точки ввода + клавиатура
            Expanded(
              child: Center(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!blocked)
                        AnimatedBuilder(
                          animation: _shakeAnimation,
                          builder: (context, child) => Transform.translate(
                            offset: Offset(_shakeAnimation.value, 0),
                            child: child,
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: List.generate(_maxLen, (i) {
                              final filled = i < _entered.length;
                              return Container(
                                margin: EdgeInsets.symmetric(
                                  horizontal: _maxLen > 4 ? 5 : 10,
                                ),
                                width: 16,
                                height: 16,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: filled
                                      ? const Color(0xFF00C6B2)
                                      : Colors.transparent,
                                  border: Border.all(
                                    color: const Color(0xFF00C6B2),
                                    width: 2,
                                  ),
                                ),
                              );
                            }),
                          ),
                        ),

                      if (!blocked) const SizedBox(height: 24),

                      if (!blocked)
                        SizedBox(
                          width: 260,
                          child: GridView.count(
                            crossAxisCount: 3,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 10,
                            childAspectRatio: 1.5,
                            children: [
                              ...['1', '2', '3', '4', '5', '6', '7', '8', '9']
                                  .map(
                                (d) => _DigitButton(
                                  label: d,
                                  onTap: () => _onDigit(d),
                                ),
                              ),
                              const SizedBox.shrink(),
                              _DigitButton(
                                label: '0',
                                onTap: () => _onDigit('0'),
                              ),
                              _DigitButton(
                                label: '⌫',
                                onTap: _onBackspace,
                                color: const Color(0xFF334455),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ИНДИКАТОР ОСТАВШИХСЯ ПОПЫТОК
// ============================================================

class _AttemptsIndicator extends StatelessWidget {
  final String label;
  final int left;
  final int total;
  final bool alignStart;

  const _AttemptsIndicator({
    required this.label,
    required this.left,
    required this.total,
    this.alignStart = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color color = left >= 3
        ? const Color(0xFF00C6B2)
        : left == 2
            ? const Color(0xFFFFAA00)
            : const Color(0xFFE53935);

    return Column(
      crossAxisAlignment:
          alignStart ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        Text(
          '$label: $left',
          style: TextStyle(
            color: color,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment:
              alignStart ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: List.generate(total, (i) {
            final alive = i < left;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: 26,
              height: 4,
              decoration: BoxDecoration(
                color: alive ? color : const Color(0xFF334455),
                borderRadius: BorderRadius.circular(2),
              ),
            );
          }),
        ),
      ],
    );
  }
}

// ============================================================
// КНОПКА КЛАВИАТУРЫ
// ============================================================

class _DigitButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _DigitButton({
    required this.label,
    required this.onTap,
    this.color = const Color(0xFF1A2233),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2A3A4A)),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
