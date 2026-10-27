import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_state.dart';
import '../services/app_log_service.dart';
import '../services/card_payment_service.dart';
import '../services/card_terminal_service.dart';
import '../services/session_service.dart';

// Возврат на заставку при бездействии (1.11.6): на выборе языка и запаха
// config.idleReturnS секунд (60 по умолчанию) без касаний — переход на
// AppState.standby, как кнопка «Отмена».
//
//   * Касание в любом месте экрана (и в открытом поверх меню) сбрасывает
//     отсчёт — глобальный маршрут указателя, а не обёртка над деревом.
//   * Карта, приложенная без выбора запаха (подсказка CardHintBanner), —
//     тоже действие клиента: отсчёт заново.
//   * Таймер живёт, пока экран на месте: уход с экрана (dispose) его
//     отменяет; срабатывает, только если состояние всё ещё [state].
//   * Деньги: на этих экранах кредита не бывает — монеты считаются только на
//     экране оплаты, карта до выбора запаха закрывается 13 04 без списания.
//     Если всё же идёт сессия цикла или оплаты картой (moneyInProgress), на
//     заставку не уходим — отсчёт начинается заново, сессия не трогается.
class IdleReturn extends StatefulWidget {
  final AppState state;
  final Widget child;
  const IdleReturn({super.key, required this.state, required this.child});

  // Сессия цикла, одобренная карта или сессия терминала — уходить нельзя.
  static bool get moneyInProgress {
    final card = CardTerminalService.status.value;
    return SessionService.currentSessionId != null ||
        CardPaymentService.approvedPending ||
        card.inSession ||
        card.paymentState != 'IDLE' ||
        card.recoveryPending;
  }

  @override
  State<IdleReturn> createState() => _IdleReturnState();
}

class _IdleReturnState extends State<IdleReturn> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    CardTerminalService.tappedWithoutFlavorAt.addListener(_arm);
    _arm();
  }

  @override
  void dispose() {
    _timer?.cancel();
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    CardTerminalService.tappedWithoutFlavorAt.removeListener(_arm);
    super.dispose();
  }

  void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) _arm();
  }

  void _arm() {
    if (!mounted) return;
    _timer?.cancel();
    final s = context.read<AppNotifier>().config.idleReturnS;
    _timer = Timer(Duration(seconds: s), _fire);
  }

  void _fire() {
    if (!mounted) return;
    final notifier = context.read<AppNotifier>();
    if (notifier.state != widget.state) return;
    if (IdleReturn.moneyInProgress) {
      AppLog.log(
        'Idle',
        '${widget.state.name}: бездействие, но идёт оплата/сессия — остаёмся, отсчёт заново',
      );
      _arm();
      return;
    }
    AppLog.log(
      'Idle',
      '${widget.state.name}: ${notifier.config.idleReturnS} с без касаний — на заставку',
    );
    notifier.transition(AppState.standby);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
