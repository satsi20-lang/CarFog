import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import 'package:flutter/services.dart';
import '../services/app_log_service.dart';
import '../services/card_payment_service.dart';
import '../services/card_terminal_service.dart';
import '../services/cloud_service.dart';
import '../services/i18n_service.dart';
import '../services/modbus_service.dart';
import '../services/session_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  int _priceCents = 200;
  int _balanceCents = 0;
  // Окно оплаты: 120 с монетами; с картой MDB — 60 с ожидания карты (ТЗ 6.5),
  // каждая монета продлевает его заново.
  static const int _coinTimeoutS = 120;
  static const int _cardTimeoutS = 60;
  int _timeoutS = _coinTimeoutS;
  int _secondsLeft = _coinTimeoutS;

  // ---- Оплата картой Nayax по MDB (1.11.0, ТЗ раздел 6) ----
  bool _cardMode = false;
  // Ждём карту (автомат в Kotlin ждёт 10 03).
  bool _cardArmed = false;
  // 10 03 пришло и vend отправлен — до итога: «Отмена» скрыта, таймер стоит,
  // монеты записываются как duplicate_payment (решения владельца 21.10.2026).
  bool _cardProcessing = false;
  // Сумма не совпала (13 03 уже отправлен) — карта на этом экране больше не
  // предлагается.
  bool _cardOff = false;
  // Pre-flight не прошёл: «Аппарат временно недоступен», ни монет, ни карты.
  bool _machineUnavailable = false;
  // Ключ сообщения клиенту (payment.card_*).
  String? _cardMsg;
  StreamSubscription<CardPaymentEvent>? _cardSub;
  Timer? _unavailableTimer;
  // Переход к прогреву уже запущен: монета и карта одновременно не должны
  // запустить его дважды (двойная сессия, двойной прогрев).
  bool _proceeding = false;
  // Способ, которым запущен переход к прогреву ('coins' | 'card' | 'mixed') —
  // для записи о повторной оплате.
  String? _firstMethod;

  Timer? _coinTimer;
  Timer? _countdownTimer;
  Timer? _terminalTimer;
  bool _terminalEnabled = false;
  // Защита от повторного входа — Timer.periodic не ждёт завершения
  // предыдущего асинхронного вызова, при загруженной шине тики могли бы
  // накладываться друг на друга (тот же приём, что и в LevelService._tick
  // и на вкладке "Датчики").
  bool _checkingCoin = false;
  bool _checkingTerminal = false;

  // "Отказ вместо недосчёта" (задача "контроль цикла по электросчётчику,
  // готовность оплаты", п.2-3). _coinFailureCount копится за всё окно
  // оплаты и уходит в запись о транзакции при успехе — даже если больше
  // ничего не делать, спор с клиентом решается по записи. _coinAcceptorDown
  // — приём монет закрыт (несколько неудач подряд), обрабатывается один
  // раз через _handleCoinAcceptorDown().
  int _coinFailureCount = 0;
  bool _coinAcceptorDown = false;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<AppNotifier>().config;
    // Третий рубеж защиты (первые два — AppNotifier.transition и роутер, см.
    // "вывод аппарата из обслуживания"): сюда попасть нельзя, но если всё
    // же — не заводить ни опрос монетоприёмника, ни терминал, ни
    // таймеры, и сразу уйти на экран "не работает".
    if (context.read<AppNotifier>().isPaymentBlocked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          context.read<AppNotifier>().transition(AppState.outOfService);
        }
      });
      return;
    }
    // Цена выбранного запаха (1.11.0); монеты считаются от неё же.
    _priceCents = cfg.priceForFlavor(
      context.read<AppNotifier>().selectedFlavor ?? 0,
    );
    // Карта по MDB: сначала pre-flight, и только потом монеты и карта.
    _cardMode = cfg.paymentTerminalType == PaymentTerminalType.mdb;
    if (_cardMode) {
      _timeoutS = _cardTimeoutS;
      _secondsLeft = _cardTimeoutS;
      _cardSub = CardPaymentService.events.listen(_onCardEvent);
      unawaited(_startCardMode());
      return;
    }
    _startPaymentLoops(cfg);
  }

  void _startPaymentLoops(AppConfig cfg) {
    ModbusService.startPaymentCoinCounting();
    _coinTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _checkCoin(),
    );
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(),
    );

    // Терминал слушаем параллельно с монетоприёмником, только если техник
    // включил его в настройках (Шаг "терминал", задача 4.1/4.6) — пока не
    // подключён физически, вход в принципе ничего не значит.
    _terminalEnabled = cfg.paymentTerminalEnabled;
    if (_terminalEnabled) {
      // 30 мс, не 100 — живой тест показал импульс терминала короче 100 мс
      // (после укорочения реле), опрос вровень с длиной импульса ловит его
      // не гарантированно (дело фазы). 30 мс даёт трёхкратный запас на
      // импульс ~100 мс. Один регистр раз в 30 мс — нагрузка на шину RS485
      // не растёт заметно (та же логика, что и обоснование единого
      // 16-битного чтения, см. docs/payment_terminal.md).
      _terminalTimer = Timer.periodic(
        const Duration(milliseconds: 30),
        (_) => _checkTerminal(cfg),
      );
    }
  }

  // ---- карта MDB ----

  Future<void> _startCardMode() async {
    final n = context.read<AppNotifier>();
    final flavorIndex = n.selectedFlavor ?? 0;
    // Pre-flight (ТЗ раздел 5): аппарат должен суметь выдать услугу.
    final pre = await CardPaymentService.preflightDetailed(n, flavorIndex);
    final reason = pre.reason;
    if (!mounted) return;
    if (reason != null) {
      AppLog.log(
        'CardPayment',
        'pre-flight не прошёл: $reason — оплата не начинается',
      );
      unawaited(
        CloudService.report(
          CloudEventType.hardwareError,
          // attempts, readings, last_usable_* (1.11.3) — что именно пришло.
          data: {'code': 'card_preflight', 'reason': reason, ...pre.details},
        ),
      );
      setState(() => _machineUnavailable = true);
      _unavailableTimer = Timer(const Duration(seconds: 8), () {
        if (mounted) context.read<AppNotifier>().resetSession();
      });
      return;
    }
    _startPaymentLoops(n.config);
    await _armCard();
  }

  Future<void> _armCard() async {
    if (!mounted || _proceeding || _cardOff || _cardArmed || _cardProcessing) {
      return;
    }
    final remaining = _priceCents - _balanceCents;
    if (remaining <= 0) return;
    final st = CardTerminalService.status.value;
    if (st.busyService || !st.cardAvailable) {
      setState(
        () => _cardMsg = st.busyService
            ? 'card_busy_service'
            : 'card_unavailable',
      );
      return;
    }
    final n = context.read<AppNotifier>();
    try {
      await CardPaymentService.arm(
        notifier: n,
        cents: remaining,
        flavorIndex: n.selectedFlavor ?? 0,
        coinsCents: _balanceCents,
      );
      if (!mounted) return;
      setState(() {
        _cardArmed = true;
        _cardMsg = 'card_waiting';
      });
    } on PlatformException catch (e) {
      AppLog.log('CardPayment', 'карта не включена: ${e.message}');
      if (mounted) setState(() => _cardMsg = 'card_unavailable');
    }
  }

  void _onCardEvent(CardPaymentEvent e) {
    if (!mounted || _proceeding) return;
    switch (e.type) {
      case 'vend_sent':
        setState(() {
          _cardProcessing = true;
          _cardMsg = 'card_processing';
        });
      case 'approved':
        _cardArmed = false;
        _proceedToTreatment(
          paymentMethod: _balanceCents > 0 ? 'mixed' : 'card',
          coinsCents: _balanceCents > 0 ? _balanceCents : null,
          cardRemainder: true,
        );
      case 'amount_mismatch':
      case 'approved_after_cancel':
        setState(() {
          _cardArmed = false;
          _cardProcessing = false;
          _cardOff = true;
          _cardMsg = 'card_error';
          _secondsLeft = _timeoutS;
        });
      case 'insufficient_funds':
      case 'declined':
      case 'vend_failed':
      case 'cancelled_by_terminal':
      case 'vend_timeout':
      case 'session_ended':
      case 'payment_aborted':
        setState(() {
          _cardArmed = false;
          _cardProcessing = false;
          _cardMsg = e.type == 'insufficient_funds'
              ? 'card_insufficient'
              : e.type == 'payment_aborted'
              ? 'card_unavailable'
              : 'card_declined';
          _secondsLeft = _timeoutS;
        });
        // Можно приложить другую карту: ждём её снова (сообщение остаётся,
        // пока не придёт новая карта).
        final msg = _cardMsg;
        Future.delayed(const Duration(seconds: 1), () async {
          await _armCard();
          if (mounted && _cardArmed) setState(() => _cardMsg = msg);
        });
    }
  }

  @override
  void dispose() {
    _cardSub?.cancel();
    _unavailableTimer?.cancel();
    // Ушли без карты (до 10 03) — снять ожидание, команд терминалу нет.
    if (_cardArmed && !_proceeding) {
      unawaited(CardPaymentService.disarm('screen_closed').catchError((_) {}));
    }
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    _terminalTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    super.dispose();
  }

  Future<void> _checkCoin() async {
    if (_checkingCoin || _coinAcceptorDown || ModbusService.paymentBlocked) {
      return;
    }
    _checkingCoin = true;
    try {
      final status = await ModbusService.getCoinAcceptorStatus();
      _coinFailureCount = status.failureCount;
      if (status.cents > 0 && _cardProcessing && !_proceeding) {
        // Монета после vend: оплату не меняем, только запись (решение
        // владельца 21.10.2026).
        _reportDuplicate(
          method: 'coins',
          cents: status.cents,
          reason: 'after_vend',
        );
      } else if (status.cents > 0 && _proceeding) {
        // Монета пришла уже ПОСЛЕ защёлки перехода к прогреву — раньше она
        // пропадала без записи.
        _reportDuplicate(
          method: 'coins',
          cents: status.cents,
          reason: 'after_latch',
        );
      } else if (status.cents > 0 && mounted) {
        setState(() {
          _balanceCents += status.cents;
          // Клиент вносит деньги — окно оплаты продлевается; раньше 120 с
          // шли от входа на экран, и внесённая часть суммы пропадала по
          // таймауту, пока клиент искал монеты.
          _secondsLeft = _timeoutS;
        });
      }
      if (status.down) {
        await _handleCoinAcceptorDown();
        return;
      }
      if (_cardProcessing) return;
      if (_balanceCents >= _priceCents) {
        // Монеты набрали цену — ожидание карты снимается (до 10 03).
        if (_cardArmed) {
          _cardArmed = false;
          unawaited(
            CardPaymentService.disarm('coins_reached_price').catchError((_) {}),
          );
        }
        _proceedToTreatment(paymentMethod: 'coins');
      } else if (_cardArmed && status.cents > 0) {
        // Монета до карты — vend пойдёт на новый остаток.
        unawaited(
          CardPaymentService.updateAmount(
            _priceCents - _balanceCents,
            _balanceCents,
          ).catchError(
            (Object e) => AppLog.log('CardPayment', 'остаток не обновлён: $e'),
          ),
        );
      }
    } finally {
      _checkingCoin = false;
    }
  }

  // "Отказ вместо недосчёта", п.3 (задача "контроль цикла по
  // электросчётчику, готовность оплаты") — вызывается один раз, когда
  // нативная сторона зафиксировала несколько неудачных чтений DI8 подряд
  // и сама закрыла приём монет (недосчитанный ряд импульсов уже отброшен
  // там же, баланс здесь не трогаем — уже подтверждённые монеты остаются
  // засчитанными). Если рядом работает терминал — клиент может закончить
  // оплату картой, монетоприёмник просто выключается из опроса. Если
  // терминала нет — платить больше нечем, это ошибка для персонала.
  Future<void> _handleCoinAcceptorDown() async {
    if (_coinAcceptorDown) return;
    _coinTimer?.cancel();
    if (mounted) {
      setState(() => _coinAcceptorDown = true);
    } else {
      _coinAcceptorDown = true;
    }
    unawaited(
      CloudService.report(
        CloudEventType.hardwareError,
        data: {
          'code': 'coin_acceptor_unavailable',
          'balance_cents': _balanceCents,
          'coin_failure_count': _coinFailureCount,
        },
      ),
    );
    if (!_terminalEnabled && mounted) {
      context.read<AppNotifier>().goToError('coin_acceptor_unavailable');
    }
  }

  // Терминал настроен эквайером на фиксированную сумму, равную цене
  // обработки — сигнал означает "оплачено полностью", независимо от того,
  // сколько уже внесено монетами (Шаг "терминал", задача 4.2). Если
  // что-то уже накопилось — это переплата, фиксируем отдельным способом
  // оплаты 'mixed', чтобы сумма монет не потерялась в отчётности
  // (задача 4.3).
  Future<void> _checkTerminal(AppConfig cfg) async {
    if (_checkingTerminal || ModbusService.paymentBlocked) return;
    _checkingTerminal = true;
    final TerminalPoll? poll;
    try {
      poll = await ModbusService.pollTerminal(
        channel: cfg.paymentTerminalChannel,
        mode: cfg.paymentTerminalMode,
        guardMs: cfg.paymentTerminalGuardMs,
      );
    } finally {
      _checkingTerminal = false;
    }
    if (poll != null && poll.confirmed && _proceeding) {
      // Второй платёж картой после защёлки (монета и карта почти
      // одновременно, либо повторное касание).
      _reportDuplicate(
        method: 'card',
        cents: _priceCents,
        reason: 'after_latch',
      );
    } else if (poll != null && poll.confirmed) {
      _proceedToTreatment(
        paymentMethod: _balanceCents > 0 ? 'mixed' : 'card',
        coinsCents: _balanceCents > 0 ? _balanceCents : null,
      );
    }
  }

  void _tickCountdown() {
    // Идёт оплата картой (vend отправлен) — таймер стоит до итога.
    if (_cardProcessing) return;
    setState(() => _secondsLeft--);
    // Терминал стал доступен, пока клиент на экране, — предложить карту.
    if (_cardMode &&
        !_cardArmed &&
        !_cardOff &&
        (_cardMsg == 'card_unavailable' || _cardMsg == 'card_busy_service')) {
      unawaited(_armCard());
    }
    if (_secondsLeft <= 0) {
      _cancel(reason: 'timeout');
    }
  }

  // cardRemainder — карта MDB списала остаток (цена минус монеты): это не
  // переплата, запись coins_then_card не нужна.
  void _proceedToTreatment({
    required String paymentMethod,
    int? coinsCents,
    bool cardRemainder = false,
  }) {
    if (ModbusService.paymentBlocked || _proceeding) return;
    _proceeding = true;
    _firstMethod = paymentMethod;
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    _terminalTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    if (!mounted) return;
    final notifier = context.read<AppNotifier>();
    final flavorIndex = notifier.selectedFlavor ?? 0;
    // Импульсный терминал всегда списывает полную цену (так настроен
    // эквайером) — монеты сверху это переплата (задача 4.3). Карта MDB
    // списывает остаток: вместе с монетами ровно цена.
    final paidCents = paymentMethod == 'coins'
        ? _balanceCents
        : cardRemainder
        ? _priceCents
        : _priceCents + (coinsCents ?? 0);
    // Начинаем сессию (Шаг 33, задача 1/2) именно здесь — сумма уже
    // набрана, деньги приняты монетоприёмником/терминалом безвозвратно.
    // Название аромата берём по-русски независимо от языка интерфейса
    // клиента: событие уходит оператору, не клиенту.
    unawaited(
      SessionService.start(
        flavorIndex: flavorIndex,
        flavorNameRu: notifier.config.flavorNames['ru']![flavorIndex],
        priceCents: _priceCents,
        paidCents: paidCents,
        paymentMethod: paymentMethod,
        coinsCents: coinsCents,
        coinFailureCount: _coinFailureCount == 0 ? null : _coinFailureCount,
        readStartEnergy: notifier.config.energyMeterInstalled,
      ),
    );
    // Монетами внесено, а завершила карта — клиент переплатил (карта идёт на
    // полную цену поверх монет): оператору нужна запись для возврата. Сессия
    // создаётся синхронно в start(), идентификатор уже доступен.
    if (cardRemainder) {
      CardPaymentService.attachSession(SessionService.currentSessionId);
    } else {
      // Новая сессия без карты — прежний итог карты на экране ошибки не нужен.
      CardPaymentService.customerNotice.value = null;
    }
    if (paymentMethod == 'mixed' && !cardRemainder) {
      _reportDuplicate(
        method: 'coins_then_card',
        cents: coinsCents ?? 0,
        reason: 'coins_and_card',
      );
    }
    // Монета, принятая монетоприёмником между последним опросом и остановкой
    // счёта, остаётся в нативном буфере и стёрлась бы при следующем окне
    // оплаты — забираем её здесь и фиксируем.
    unawaited(_drainLateCoin());
    notifier.transition(AppState.preparing);
  }

  void _reportDuplicate({
    required String method,
    required int cents,
    required String reason,
  }) {
    unawaited(
      CloudService.report(
        CloudEventType.duplicatePayment,
        data: {
          'reason': reason,
          'method': method,
          'cents': cents,
          'first_method': ?_firstMethod,
          'balance_cents': _balanceCents,
          'price_cents': _priceCents,
          'session_id': ?SessionService.currentSessionId,
        },
      ),
    );
  }

  Future<void> _drainLateCoin() async {
    // Дать фоновому потоку счёта дочитать последний тик после остановки.
    await Future.delayed(const Duration(milliseconds: 400));
    try {
      final status = await ModbusService.getCoinAcceptorStatus();
      if (status.cents > 0) {
        _reportDuplicate(
          method: 'coins',
          cents: status.cents,
          reason: 'late_coin',
        );
      }
    } catch (_) {}
  }

  void _cancel({String reason = 'cancelled'}) {
    if (_proceeding || _cardProcessing) return;
    if (_cardArmed) {
      _cardArmed = false;
      // Кнопка «Отмена» — сброс читателя 14 02; таймаут — без команд (enable
      // остаётся включён, ТЗ 9.2 и решение владельца 21.10.2026).
      unawaited(
        (reason == 'timeout'
                ? CardPaymentService.disarm('timeout')
                : CardPaymentService.cancel())
            .catchError((_) {}),
      );
    }
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    _terminalTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    SessionService.discard();
    // Внесённая часть суммы при отмене/таймауте не возвращается монетоприёмником
    // — раньше она пропадала без следа, теперь оператор видит её в журнале.
    if (_balanceCents > 0) {
      unawaited(
        CloudService.report(
          CloudEventType.paymentAbandoned,
          data: {
            'reason': reason,
            'balance_cents': _balanceCents,
            'price_cents': _priceCents,
            if (_coinFailureCount > 0) 'coin_failure_count': _coinFailureCount,
          },
        ),
      );
    }
    if (mounted) {
      context.read<AppNotifier>().resetSession();
    }
  }

  String _formatTime(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  String _euro(int cents) => (cents / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    String t(String key) => I18n.tr(lang, 'payment.$key');
    final flavorIndex = notifier.selectedFlavor ?? 0;
    final flavorName = notifier.config.flavorNameFor(lang, flavorIndex);
    final remainingCents = (_priceCents - _balanceCents).clamp(0, _priceCents);
    final progress = _priceCents == 0
        ? 0.0
        : (_balanceCents / _priceCents).clamp(0.0, 1.0);

    // Pre-flight не прошёл: ни монет, ни карты (ТЗ раздел 5).
    if (_machineUnavailable) {
      return Scaffold(
        backgroundColor: const Color(0xFF1A1A1A),
        body: FogBackground(
          child: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(PUi.gutter),
                child: Text(
                  t('machine_unavailable'),
                  key: const ValueKey('machine_unavailable'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: PUi.titleSp,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: FogBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(PUi.gutter),
            child: PortraitScroll(
              // Портрет: сверху заголовок и язык, затем аромат и крупная
              // цена, ниже прогресс и суммы, внизу таймер и отмена.
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('title'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: PUi.titleSp,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      LangSwitcher(
                        current: lang,
                        langs: notifier.displayLangs,
                        onChanged: notifier.setLanguage,
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Text(
                    t('flavor'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: PUi.minBodySp,
                    ),
                  ),
                  Text(
                    flavorName,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF2EC4B6),
                      fontSize: PUi.titleSp,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_euro(_priceCents)} €',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 112,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    t('price'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: PUi.minBodySp,
                    ),
                  ),
                  const Spacer(),
                  if (_cardMode && _cardMsg != null)
                    _CardPrompt(
                      key: const ValueKey('card_prompt'),
                      text: t(_cardMsg!),
                      processing: _cardProcessing,
                      warning: !_cardArmed && !_cardProcessing,
                    )
                  else
                    Text(
                      _coinAcceptorDown && _terminalEnabled
                          ? t('instruction_coin_down_with_card')
                          : _terminalEnabled
                          ? t('instruction_with_card')
                          : t('instruction'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: PUi.bodySp + 4,
                      ),
                    ),
                  const SizedBox(height: 28),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 36,
                      backgroundColor: const Color(0xFF2E2E2E),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF2EC4B6),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  _InfoRow(
                    label: t('paid'),
                    value: '${_euro(_balanceCents)} €',
                    valueColor: _balanceCents >= _priceCents
                        ? Colors.greenAccent
                        : const Color(0xFF2EC4B6),
                  ),
                  const SizedBox(height: 12),
                  _InfoRow(
                    label: t('remaining'),
                    value: '${_euro(remainingCents)} €',
                  ),
                  const Spacer(),
                  Text(
                    _formatTime(_secondsLeft),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // После 10 03 и vend отмены нет — деньги в обработке.
                  if (!_cardProcessing)
                    SizedBox(
                      height: PUi.buttonH,
                      child: OutlinedButton(
                        key: const ValueKey('payment_cancel'),
                        onPressed: _cancel,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(
                            color: Colors.white38,
                            width: 2,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          t('cancel'),
                          style: const TextStyle(fontSize: 28),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// «Приложите карту» с рисунком и сообщения оплаты картой (ТЗ 9.2–9.3).
class _CardPrompt extends StatelessWidget {
  final String text;
  final bool processing;
  final bool warning;

  const _CardPrompt({
    super.key,
    required this.text,
    required this.processing,
    required this.warning,
  });

  @override
  Widget build(BuildContext context) {
    final color = warning ? const Color(0xFFFFB020) : const Color(0xFF2EC4B6);
    return Column(
      children: [
        if (processing)
          const SizedBox(
            width: 72,
            height: 72,
            child: CircularProgressIndicator(
              strokeWidth: 6,
              color: Color(0xFF2EC4B6),
            ),
          )
        else
          Icon(Icons.contactless, size: 96, color: color),
        const SizedBox(height: 16),
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: warning ? color : Colors.white,
            fontSize: PUi.bodySp + 8,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: PUi.bodySp + 4,
            ),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: PUi.bodySp + 8,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
