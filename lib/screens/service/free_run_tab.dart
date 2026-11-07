import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import '../../services/free_run_service.dart';
import '../../widgets/portrait_ui.dart';

// Вкладка сервисного меню «Бесплатный запуск». Видна только когда функция
// включена из облака (FreeRunService.isEnabled). Это НЕ PIN обслуживания:
// отдельный код из 6 цифр. Верный код → экран выбора аромата → один запуск
// без оплаты → заставка. 30 секунд без касаний — назад на заставку.
class FreeRunTab extends StatefulWidget {
  const FreeRunTab({super.key});

  static const Map<String, Map<String, String>> labels = {
    'title': {'ru': 'Бесплатный запуск', 'en': 'Free run', 'et': 'Tasuta käivitus'},
    'hint': {
      'ru': 'Введите код из 6 цифр',
      'en': 'Enter the 6-digit code',
      'et': 'Sisesta 6-kohaline kood',
    },
    'wrong': {'ru': 'Неверный код. Осталось попыток', 'en': 'Wrong code. Attempts left', 'et': 'Vale kood. Katseid jäänud'},
    'locked': {'ru': 'Ввод заблокирован. Осталось', 'en': 'Entry locked. Time left', 'et': 'Sisestus lukus. Jäänud'},
    'delete': {'ru': 'Стереть', 'en': 'Delete', 'et': 'Kustuta'},
  };

  @override
  State<FreeRunTab> createState() => _FreeRunTabState();
}

class _FreeRunTabState extends State<FreeRunTab> {
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

  String _t(String key) {
    final lang = context.read<AppNotifier>().serviceLang;
    final m = FreeRunTab.labels[key]!;
    return m[lang] ?? m['en']!;
  }

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
        // Один запуск: взвод снимется при выборе аромата или уходе с экрана.
        FreeRunService.arm();
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
    final locked = _lockLeft > Duration.zero;
    const teal = Color(0xFF00C6B2);
    Widget key(String label, {VoidCallback? onTap, Key? k}) => SizedBox(
          width: 88,
          height: 64,
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
                    fontSize: label.length > 1 ? 16 : 28,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
    final enabled = !locked && !_busy;
    Widget digit(String d) => key(d, k: Key('free_run_key_$d'), onTap: enabled ? () => _press(d) : null);

    return Listener(
      // Любое касание экрана продлевает ожидание.
      onPointerDown: (_) => _armIdle(),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(PUi.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_t('title'),
                  style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(_t('hint'), style: const TextStyle(color: Color(0xFF8899AA), fontSize: 16)),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                key: const Key('free_run_dots'),
                children: [
                  for (var i = 0; i < FreeRunLimits.digits; i++)
                    Container(
                      width: 16,
                      height: 16,
                      margin: const EdgeInsets.symmetric(horizontal: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _entered.length ? teal : Colors.transparent,
                        border: Border.all(color: teal, width: 2),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 24,
                child: Text(
                  locked ? '${_t('locked')} ${_mmss(_lockLeft)}' : _message,
                  key: const Key('free_run_message'),
                  style: const TextStyle(color: Color(0xFFFFAA00), fontSize: 16),
                ),
              ),
              const SizedBox(height: 8),
              for (final row in const [
                ['1', '2', '3'],
                ['4', '5', '6'],
                ['7', '8', '9'],
              ])
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final d in row)
                        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: digit(d)),
                    ],
                  ),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(width: 96),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: digit('0')),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: key('⌫', k: const Key('free_run_key_del'), onTap: enabled ? _delete : null),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
