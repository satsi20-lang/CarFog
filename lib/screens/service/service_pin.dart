import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../services/cloud_service.dart';
import '../../services/config_service.dart';
import '../../services/security_service.dart';
import '../../widgets/lang_switcher.dart';

enum _Mode { pin, master }

class ServicePinScreen extends StatefulWidget {
  const ServicePinScreen({super.key});

  @override
  State<ServicePinScreen> createState() => _ServicePinScreenState();
}

class _ServicePinScreenState extends State<ServicePinScreen>
    with SingleTickerProviderStateMixin {
  _Mode _mode = _Mode.pin;
  String _entered = '';
  int _attemptsLeft = SecurityService.maxAttempts;
  Duration _lockLeft = Duration.zero;
  Timer? _ticker;

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  int get _maxLen => _mode == _Mode.pin ? 4 : 8;
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
    'reset_title': {
      'et': 'Tehaseseadete taastamine?',
      'en': 'Restore factory settings?',
      'ru': 'Сброс к заводским настройкам?',
    },
    'reset_body': {
      'et': 'PIN muutub 1234-ks. Hinnad, kestused ja lõhnade nimed '
          'taastatakse tehaseseadetele. Sündmus saadetakse pilve.',
      'en': 'The PIN will become 1234. Prices, durations and fragrance '
          'names will be restored to factory defaults. The event will be '
          'sent to the cloud.',
      'ru': 'PIN станет 1234. Цены, длительности и названия ароматов '
          'вернутся к заводским. Событие будет отправлено в облако.',
    },
    'reset_ok': {'et': 'Taasta', 'en': 'Reset', 'ru': 'Сбросить'},
    'reset_done': {
      'et': 'Taastatud. Uus PIN: 1234',
      'en': 'Reset complete. New PIN: 1234',
      'ru': 'Сброшено. Новый PIN: 1234',
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
    if (_mode == _Mode.pin && _isLocked) return;
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

    if (_mode == _Mode.master) {
      if (SecurityService.isMasterCode(_entered)) {
        await CloudService.report(CloudEventType.masterCodeUsed);
        if (!mounted) return;
        _confirmFactoryReset();
      } else {
        _fail();
        _snack(_t('wrong_master', notifier.lang));
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
        notifier.transition(AppState.serviceMenu);
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

  void _confirmFactoryReset() {
    final lang = context.read<AppNotifier>().lang;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A2233),
        title: Text(
          _t('reset_title', lang),
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: Text(
          _t('reset_body', lang),
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              if (mounted) setState(() => _entered = '');
            },
            child: Text(
              _t('cancel', lang),
              style: const TextStyle(color: Color(0xFF556677)),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              _doFactoryReset();
            },
            child: Text(
              _t('reset_ok', lang),
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _doFactoryReset() async {
    final notifier = context.read<AppNotifier>();
    final lang = notifier.lang;

    // Сохраняем подключение к облаку — иначе аппарат
    // после сброса станет недоступен удалённо.
    final keep = notifier.config;

    await ConfigService.reset();
    await SecurityService.resetAttempts();

    final fresh = AppConfig(
      deviceId: keep.deviceId,
      cloudUrl: keep.cloudUrl,
      cloudAnonKey: keep.cloudAnonKey,
      cloudToken: keep.cloudToken,
      cloudEnabled: keep.cloudEnabled,
    );

    await notifier.saveConfig(fresh);

    await CloudService.report(
      CloudEventType.factoryReset,
      data: {'source': 'master_code'},
    );

    if (!mounted) return;

    _snack(_t('reset_done', lang));
    notifier.transition(AppState.standby);
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
    final blocked = _mode == _Mode.pin && _isLocked;

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
                              : _t('title_master', lang),
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
                    else
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
