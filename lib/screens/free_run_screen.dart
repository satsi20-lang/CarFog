import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_state.dart';
import '../services/free_run_service.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

// Экран ввода 6-значного кода бесплатного запуска. Открывается кнопкой на
// экране PIN (только если функция включена). Это НЕ PIN обслуживания: код
// пускает только на выбор аромата и один запуск без оплаты, в сервисное меню
// не пускает никогда. 30 секунд без касаний — назад на заставку.
class FreeRunScreen extends StatefulWidget {
  const FreeRunScreen({super.key});

  static const Map<String, Map<String, String>> labels = {
    'title': {'ru': 'Бесплатный запуск', 'en': 'Free run', 'et': 'Tasuta käivitus'},
    'hint': {'ru': 'Введите код из 6 цифр', 'en': 'Enter the 6-digit code', 'et': 'Sisesta 6-kohaline kood'},
    'wrong': {'ru': 'Неверный код. Осталось попыток', 'en': 'Wrong code. Attempts left', 'et': 'Vale kood. Katseid jäänud'},
    'locked': {'ru': 'Ввод заблокирован. Осталось', 'en': 'Entry locked. Time left', 'et': 'Sisestus lukus. Jäänud'},
    'cancel': {'ru': 'Отмена', 'en': 'Cancel', 'et': 'Tühista'},
    'button': {'ru': 'Бесплатный запуск', 'en': 'Free run', 'et': 'Tasuta käivitus'},
    'button_locked': {
      'ru': 'Заблокировано, осталось',
      'en': 'Locked, time left',
      'et': 'Lukus, jäänud',
    },
    'min': {'ru': 'мин', 'en': 'min', 'et': 'min'},
  };

  static String tr(String key, String lang) {
    final m = labels[key]!;
    return m[lang] ?? m['en']!;
  }

  @override
  State<FreeRunScreen> createState() => _FreeRunScreenState();
}

class _FreeRunScreenState extends State<FreeRunScreen> {
  String _entered = '';
  String _message = '';
  bool _busy = false;
  Duration _lockLeft = Duration.zero;
  Timer? _idle;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _armIdle();
    _refreshLock();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refreshLock());
  }

  @override
  void dispose() {
    _idle?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(FreeRunLimits.idleTimeout, () {
      if (!mounted) return;
      context.read<AppNotifier>().transition(AppState.standby);
    });
  }

  Future<void> _refreshLock() async {
    final left = await FreeRunService.remainingLock();
    if (!mounted) return;
    if (left != _lockLeft) setState(() => _lockLeft = left);
  }

  String _t(String key) => FreeRunScreen.tr(key, context.read<AppNotifier>().lang);

  Future<void> _press(String digit) async {
    if (_busy || _lockLeft > Duration.zero) return;
    _armIdle();
    if (_entered.length >= FreeRunLimits.digits) return;
    setState(() {
      _entered += digit;
      _message = '';
    });
    if (_entered.length == FreeRunLimits.digits) await _submit();
  }

  void _delete() {
    if (_busy || _entered.isEmpty) return;
    _armIdle();
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  Future<void> _submit() async {
    final notifier = context.read<AppNotifier>();
    final code = _entered;
    setState(() => _busy = true);
    final r = await FreeRunService.tryCode(notifier.config, code);
    if (!mounted) return;
    switch (r) {
      case FreeRunResult.ok:
        // Один запуск: ожидание выбора аромата — 30 секунд без касаний.
        FreeRunService.arm(onTimeout: () => notifier.transition(AppState.standby));
        notifier.transition(AppState.selectFlavor);
        return;
      case FreeRunResult.wrong:
        final left = await FreeRunService.attemptsLeft();
        if (!mounted) return;
        setState(() {
          _entered = '';
          _busy = false;
          _message = '${_t('wrong')}: $left';
        });
      case FreeRunResult.locked:
      case FreeRunResult.disabled:
        await _refreshLock();
        if (!mounted) return;
        setState(() {
          _entered = '';
          _busy = false;
          _message = '';
        });
    }
  }

  String _mmss(Duration d) {
    final s = d.inSeconds + (d.inMilliseconds % 1000 > 0 ? 1 : 0);
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final locked = _lockLeft > Duration.zero;
    final enabled = !locked && !_busy;
    const teal = Color(0xFF00C6B2);
    final m = PUi.m;

    Widget key(String label, {VoidCallback? onTap, Key? k}) => SizedBox(
          width: 88,
          height: 60,
          child: Material(
            color: const Color(0xFF1A2233),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              key: k,
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    color: onTap == null ? const Color(0xFF445566) : Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
    Widget digit(String d) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: key(d, k: Key('free_run_key_$d'), onTap: enabled ? () => _press(d) : null),
        );

    final pad = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [for (final d in row) digit(d)]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 96),
              digit('0'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: key('⌫', k: const Key('free_run_key_del'), onTap: enabled ? _delete : null),
              ),
            ],
          ),
        ),
      ],
    );

    final header = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _t('title'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white, fontSize: m.titleSp, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          _t('hint'),
          textAlign: TextAlign.center,
          style: TextStyle(color: const Color(0xFF8899AA), fontSize: m.minBodySp),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisSize: MainAxisSize.min,
          key: const Key('free_run_dots'),
          children: [
            for (var i = 0; i < FreeRunLimits.digits; i++)
              Container(
                width: 22,
                height: 22,
                margin: const EdgeInsets.symmetric(horizontal: 7),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _entered.length ? teal : Colors.transparent,
                  border: Border.all(color: teal, width: 3),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 28,
          child: Text(
            locked ? '${_t('locked')} ${_mmss(_lockLeft)}' : _message,
            key: const Key('free_run_message'),
            textAlign: TextAlign.center,
            style: TextStyle(color: const Color(0xFFFFAA00), fontSize: m.minBodySp),
          ),
        ),
      ],
    );

    final cancel = TextButton(
      key: const Key('free_run_cancel'),
      onPressed: () => notifier.transition(AppState.standby),
      style: TextButton.styleFrom(minimumSize: Size(m.minTouch * 3, m.minTouch)),
      child: Text(_t('cancel'), style: TextStyle(color: const Color(0xFF8899AA), fontSize: m.minBodySp)),
    );
    final lang = LangSwitcher(
      current: notifier.lang,
      langs: notifier.displayLangs,
      onChanged: notifier.setLanguage,
    );

    return Listener(
      onPointerDown: (_) => _armIdle(),
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0E1A),
        body: SafeArea(
          child: PUi.landscape
              ? Padding(
                  padding: EdgeInsets.all(m.gutter),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          children: [
                            Align(alignment: Alignment.centerLeft, child: lang),
                            const Spacer(),
                            header,
                            const Spacer(),
                            cancel,
                          ],
                        ),
                      ),
                      Center(child: pad),
                    ],
                  ),
                )
              : SingleChildScrollView(
                  padding: EdgeInsets.all(m.gutter),
                  child: Column(
                    children: [
                      Align(alignment: Alignment.centerRight, child: lang),
                      const SizedBox(height: 48),
                      header,
                      const SizedBox(height: 32),
                      pad,
                      const SizedBox(height: 32),
                      cancel,
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
